# Architecture — B300 Slinky on DOKS

This doc explains *why* the repo is built the way it is. The [main README](../README.md) is the step-by-step tutorial. This doc is for engineers / architects evaluating the platform before committing to a POC.

## TL;DR

We run **Slurm inside Kubernetes pods** (Slinky) on **DigitalOcean Kubernetes (DOKS)** with **NVIDIA B300 GPU node pools**, connected by a **16-NIC RoCE fabric**. Storage is **managed NFS**. Accounting is **managed MySQL**. The whole stack stands up via `terraform apply` + `make up`.

The ML team interacts with Slurm normally — `sbatch`, `squeue`, `sinfo`. The platform team operates Kubernetes normally — `kubectl`, Helm, Prometheus. The two worlds don't fight each other.

## High-level diagram

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                          DOKS Cluster (single VPC)                           │
│                                                                              │
│  ┌─── mgmt pool (CPU, s-4vcpu-8gb-intel) ────────┐                            │
│  │  slurmctld    slurmrestd                      │                            │
│  │  slurmdbd     slurm-operator                  │                            │
│  │  login pod    cert-manager                    │                            │
│  │  prometheus / grafana                         │                            │
│  └───────────────────────────────────────────────┘                            │
│                                                                              │
│  ┌─── gpu pool (B300, gpu-b300x8-2304gb-fabric-contracted) ─────┐             │
│  │  worker-slinky-0    (8× B300, 16× CX-8 NICs, RoCE fabric)    │             │
│  │  worker-slinky-1    (same)                                   │             │
│  │      ⋮                                                       │             │
│  │  CX-8 init DaemonSet (chroot → mst gpu add + resourcedump)   │             │
│  └──────────────────────────────────────────────────────────────┘             │
│                                                                              │
│  Multus + 16× NetworkAttachmentDefinitions (roce-net-fabric0..15)            │
│                                                                              │
│  ┌─── External managed services (same VPC) ─────────────────────┐             │
│  │  DO Managed MySQL    →   slurmdbd accounting database         │             │
│  │  DO Managed NFS      →   /shared (training data, ckpts, logs) │             │
│  └───────────────────────────────────────────────────────────────┘             │
└──────────────────────────────────────────────────────────────────────────────┘
```

## Why these choices

### Why Slurm-in-Kubernetes (Slinky), not raw Slurm or pure Kubernetes Jobs?

| Pattern | What you get | What you give up |
|---|---|---|
| Pure Slurm on VMs | Familiar to ML teams. Mature scheduler. | Manual node lifecycle, no K8s ecosystem, no managed control plane. |
| Pure K8s Jobs / Volcano / Kueue | Cloud-native. Great for stateless. | ML teams don't speak it. No `sbatch`/`squeue`/`sacct`. Gang scheduling is harder. |
| **Slinky (Slurm-in-K8s)** | ML team uses Slurm CLI unchanged. Platform team uses K8s for everything else. DOKS handles control-plane upgrades, node pool autoscaling, taints. | Extra moving piece. Custom slurmd image needed for GPU stacks. |

Slinky gives the ML team a paved road they already know, while the cluster underneath is just DOKS — no special snowflake infrastructure.

### Why DOKS specifically?

- **Managed control plane** — no upgrading Kubernetes by hand. DOKS handles 1.35 → 1.36 transitions.
- **GPU node pools as first-class citizens** — `gpu-b300x8-2304gb-fabric-contracted` is a node-pool size, not a custom Droplet ritual.
- **Auto-tainted GPU pools** — non-GPU workloads (operator, monitoring, Slurm control plane) schedule on mgmt nodes naturally. No `nodeSelector` gymnastics.
- **Managed MySQL + NFS in the same VPC** — slurmdbd and `/shared` are SLA-backed, not "a Postgres pod we hope doesn't crash."
- **ric1 region** — current B300 availability.

### Why 16 fabric NICs, not 8?

B300 has **2 ConnectX-8 NICs per GPU × 8 GPUs = 16 NICs**.

This is the single most common deployment bug. Most public examples (including DO's own docs) were written for 8-NIC platforms (AMD MI325X has 1 NIC per GPU). If you configure only 8 NADs on B300:

- Host-device CNI maps `fabric0`–`fabric7` into the pod.
- `fabric8`–`fabric15` stay in the host network namespace.
- NCCL sees all 16 RDMA devices via `ibv_devinfo`, tries to use them, and fails with `errno 61` on the unmapped half.
- NCCL falls back to TCP. Cross-node bandwidth: **1–5 GB/s instead of 800+ GB/s**.

This repo's [`manifests/fabric-nads.yaml`](../manifests/fabric-nads.yaml) creates all 16 NADs. [`helm/slinky/values-slurm.yaml.tpl`](../helm/slinky/values-slurm.yaml.tpl) annotates all 16 onto worker pods and requests all 16 as `rdma/fabric0..15` resources.

For the full diagnosis and fix, see [`b300-troubleshooting-guide.md` §1](b300-troubleshooting-guide.md#1-nccl-multi-node-networking-16-fabrics).

### Why a custom slurmd-cuda image?

Upstream Slinky's slurmd image is a stock Slurm runtime. GPU training needs:

- **NCCL runtime libraries** (from `nvidia/cuda:12.6.3-devel-ubuntu24.04`)
- **`all_reduce_perf`, `reduce_scatter_perf`, `all_gather_perf`** — compiled nccl-tests binaries for benchmark jobs
- **RDMA userspace** — `libibverbs`, `rdma-core`, `perftest`
- **OpenMPI** — needed by NCCL tests and any MPI training jobs
- **PyTorch + tiktoken + numpy** — the training stack itself (so jobs don't pip-install per-run)

Build details: [`docker/slurmd-cuda/Dockerfile`](../docker/slurmd-cuda/Dockerfile). CI: [`.github/workflows/build-slurmd-cuda.yml`](../.github/workflows). The image stays under DOKS's 20 GB total / 5 GB layer limit.

The runtime CUDA driver comes from the **host** (DOKS GPU image), not the container. The container only carries CUDA *runtime libraries*. This is standard NVIDIA container practice.

### Why the CX-8 firmware fix?

DOKS runs VMs (KVM/QEMU). ConnectX-8 firmware sometimes does not finish initializing on VM boot. The NVIDIA driver falls back to a **40× slower** sync path. Symptom: `cudaStreamSynchronize > 50%` of CUDA API time, total training throughput collapses.

The fix is a `resourcedump` against each `/dev/mst/netir*_gpu*` device. Cheap, fast, but does **not persist across reboots**. We ship it as a DaemonSet ([`manifests/nvidia-b300-init.yaml`](../manifests/nvidia-b300-init.yaml)) that writes a sentinel file, and re-applies after every reboot. NVIDIA is working on a permanent firmware fix.

Full details: [`b300-troubleshooting-guide.md` §2](b300-troubleshooting-guide.md#2-cx-8-pcie-switch-firmware-bug).

### Why is `sm_103` missing from PyTorch?

B300's compute capability is `sm_103`. PyTorch / cuDNN / NGC ship built cubins for `sm_90a` (Hopper), `sm_100a` (B200), but not `sm_103a` (B300). Kernels fall back to PTX JIT compilation via generic Blackwell paths.

This is **ecosystem-wide** — every cloud provider selling B300 is affected. PyTorch [PR #152414](https://github.com/pytorch/pytorch/pull/152414) excluded sm_103 intentionally pending Triton readiness.

Net effect: B300 BF16 training matches B200 (same FLOPS spec). B300's advantage is **25% larger HBM (275 vs 192 GB)** — bigger batch sizes, fewer micro-batches, higher real-world throughput on memory-bound workloads.

Practical implication for users: **do not use `torch.compile`** (Triton + ptxas crash on `sm_103a`). The job scripts set `TORCHINDUCTOR_DISABLE=1`.

Full details: [`b300-troubleshooting-guide.md` §3](b300-troubleshooting-guide.md#3-software-stack--sm_103-kernel-gap).

## Data flow

1. **Training data** lives on `/shared` (DO Managed NFS, mounted at the same path on all worker pods and the login pod).
2. **`prepare_data.py`** runs once on the login pod, downloads Shakespeare, tokenizes with tiktoken, writes `train.bin` / `val.bin` to NFS.
3. **Workers read data** via `np.memmap` (lazy, no full-file load). Each worker shuffles independently.
4. **DDP gradient all-reduce** travels over the 16-NIC RoCE fabric using NCCL.
5. **Checkpoints** are written by rank 0 to NFS (`/shared/checkpoints/...`), visible to all workers and the login pod.
6. **Logs** go to `/shared/output/` for sbatch stdout/stderr; live tail with `tail -f`.

## Failure modes we handle

- **Helm chart references a nonexistent slurmd tag** → values template pins `25.11.5-ubuntu24.04`.
- **GHCR rejects pulls from DC IPs** → image pull secret (`slurmd-pull-secret`) with PAT.
- **DOKS GPU pool auto-taints** → no `nodeSelector` work needed for mgmt-plane pods.
- **NFS Terraform drift on `performance_tier`** → `lifecycle ignore_changes`.
- **CX-8 firmware doesn't init on reboot** → DaemonSet sentinel pattern re-applies fix.
- **NCCL fallback to TCP** → 16 NADs + 16 RDMA resource requests baked into helm values.

## What this stack is *not* good for (be honest)

- **Sub-second job startup.** Slurm + Kubernetes pod scheduling means jobs take ~10–30 sec to start. For interactive iteration, use a long-running interactive `salloc` session, not per-cell `sbatch`.
- **Many tiny jobs.** Slurm is designed for fewer, longer jobs. 10,000 × 1-second jobs is fine for batch but inefficient — use array jobs.
- **Bursting beyond your node pool.** DOKS supports node pool autoscaling, but B300 capacity is finite per region. Plan capacity ahead.
- **Bleeding-edge `sm_103`-native software stacks.** PyTorch nightly + custom CUTLASS kernels for B300 are not ready. If your workload depends on those, talk to DO and we'll set expectations.

## Want to evaluate this for your workload?

Contact your DigitalOcean account team or `sales@digitalocean.com`. We do paid POCs for serious training workloads — bring your model, we'll bring B300 capacity and an SA.
