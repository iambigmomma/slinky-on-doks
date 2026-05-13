# B300 GPU Training — Troubleshooting Guide

**DigitalOcean Kubernetes (DOKS) + Slinky**

Author: Jeff Fan, Solutions Architect, EMEA
Applies to: NVIDIA B300 SXM6 AC on DOKS

> This is the full reference. For a one-page symptom → fix table, see [`../TROUBLESHOOTING.md`](../TROUBLESHOOTING.md).

---

## Table of Contents

1. [§1 — NCCL Multi-Node Networking (16 Fabrics)](#1-nccl-multi-node-networking-16-fabrics)
2. [§2 — CX-8 PCIe Switch Firmware Bug](#2-cx-8-pcie-switch-firmware-bug)
3. [§3 — Software Stack: `sm_103` Kernel Gap](#3-software-stack--sm_103-kernel-gap)
4. [§4 — Container and Image Issues](#4-container-and-image-issues)
5. [§5 — Known Platform Limitations](#5-known-platform-limitations)
6. [§6 — NCCL Environment Variables Cheat Sheet](#6-nccl-environment-variables-cheat-sheet)
7. [References](#references)

---

## Quick Reference: Symptom → Fix

| Symptom | Likely cause | Fix |
|---|---|---|
| NCCL 1–5 GB/s, logs show `NET/Socket` | Only 8 of 16 fabric NADs | §1: Add fabric8–fabric15 |
| `errno 61` on GPUs 5–7 | Missing fabric interfaces | §1: same fix |
| `cudaStreamSync > 50%` CUDA API time | CX-8 firmware not initialized | §2: resourcedump |
| Training 40× slower than expected | Same as above | §2: same fix |
| Forward pass slow, backward pass OK | PyTorch missing `sm_103` | §3: ecosystem gap |
| `torch.compile` fails `sm_103a` | Bundled ptxas no B300 support | §3: disable inductor |
| Image pull 403 from ghcr.io | DC IPs blocked by GitHub | §4: PAT pull secret |
| Helm chart image not found | Wrong tag in chart | §4: override tag |
| `terraform plan` NFS constant drift | API case mismatch | §4: lifecycle ignore |

---

## Pre-Flight Checks

Run these on every B300 node **before** deploying any workload.

### BIOS

- Performance profile: MaxPerf
- C-states: disabled
- Energy efficiency: off

Confirm with your infrastructure contact.

### Driver and CUDA

```bash
nvidia-smi
```

Expected: Driver 590.x, CUDA 13.x, Device `NVIDIA B300 SXM6 AC`, Memory 275 GB HBM3e per GPU.

```bash
python3 -c "import torch; print(torch.cuda.get_arch_list())"
```

Note: `sm_103` will NOT be in the arch list. This is expected (see [§3](#3-software-stack--sm_103-kernel-gap)).

### NVLink Topology

```bash
nvidia-smi topo -m
```

Expected: `NV18` between all 8 GPUs (full mesh). If you see `PHB` or `SYS`, there is a topology issue.

### Fabric Interfaces

```bash
ip link show | grep -c fabric           # expect 16
ibv_devinfo | grep -E "hca_id|port:|state"   # all PORT_ACTIVE
```

---

## §1 — NCCL Multi-Node Networking (16 Fabrics)

### The problem

B300 has 16 fabric interfaces (**2 per GPU**), not 8. AMD MI325X has 8 (1 per GPU). The upstream `DO-Solutions/slinky-on-doks` repo, official DO docs, and all public examples only configure 8 NADs. With 8 NADs, half the InfiniBand topology is invisible to the pod.

### Symptoms

**A — NCCL falls back to TCP:**
```
NCCL INFO NET/Socket : Using [0]eth0:10.244.0.5<0>
```
instead of:
```
NCCL INFO NET/IB : Using [0]mlx5_0:1/RoCE [1]mlx5_1:1/RoCE ...
```
Cross-node bandwidth: 1–5 GB/s instead of 800+ GB/s.

**B — `errno 61` on some GPUs:**
```
call to ibv_modify_qp failed with 61 (No data available)
```
Fails deterministically on GPUs 5–7 (PCI bus `0x96`, `0x9e`). GPUs 0–4 work fine.

### Diagnosis

```bash
# Count fabric interfaces on host
ip link show | grep -c fabric           # 16 → host OK. 8 → host issue, escalate.

# Count NADs in cluster
kubectl get net-attach-def -n slurm | grep -c roce-net-fabric   # 8 → THIS IS THE PROBLEM
```

### Root cause

B300 has 2 ConnectX-8 NICs per GPU = 16 fabric interfaces. With only 8 NADs, host-device CNI only maps `fabric0`–`fabric7` into the pod. `fabric8`–`fabric15` remain in the host namespace. NCCL sees all 16 RDMA devices via `ibv_devinfo` but can only use the first 8. Traffic routed through unmapped HCAs fails with `errno 61`.

### Fix

**Step 1 — Create 16 NADs (fabric0–fabric15)**

```yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: roce-net-fabricN    # N = 0 through 15
  namespace: slurm
spec:
  config: '{"cniVersion":"0.3.1","type":"host-device","device":"fabricN"}'
```

Apply:
```bash
kubectl apply -f manifests/fabric-nads.yaml -n slurm
```

This repo's [`manifests/fabric-nads.yaml`](../manifests/fabric-nads.yaml) already has 16 NADs.

**Step 2 — Pod annotations list all 16**

```yaml
metadata:
  annotations:
    k8s.v1.cni.cncf.io/networks: >-
      roce-net-fabric0@fabric0, roce-net-fabric1@fabric1, ...
      roce-net-fabric14@fabric14, roce-net-fabric15@fabric15
```

**Step 3 — RDMA resources for all 16**

```yaml
resources:
  requests:
    rdma/fabric0: 1
    # ... through ...
    rdma/fabric15: 1
```

This repo's [`helm/slinky/values-slurm.yaml.tpl`](../helm/slinky/values-slurm.yaml.tpl) already has this.

**Step 4 — Security context**

```yaml
securityContext:
  privileged: true
  capabilities:
    add: [IPC_LOCK]
```

**Step 5 — NCCL env vars — only two needed:**

```bash
export NCCL_SOCKET_IFNAME=eth0
export NCCL_DEBUG=WARN
```

Do NOT set: `NCCL_IB_TC`, `NCCL_CROSS_NIC`, `NCCL_IB_GID_INDEX`, `NCCL_IB_HCA`, `NCCL_IB_DISABLE`. Do NOT install whereabouts IPAM.

### Validation

Run NCCL all-reduce test. Expected: **~800–850 GB/s** average bus bandwidth. If < 100 GB/s, check NAD count, pod annotations, RDMA resources.

References:
- <https://github.com/RithishRamesh-dev/doks-multi-node/tree/main/B300>
- <https://github.com/iambigmomma/slinky-on-doks> (working config)

---

## §2 — CX-8 PCIe Switch Firmware Bug

### The problem

In VM environments (DOKS uses KVM/QEMU), ConnectX-8 firmware may not fully initialize on boot. The NVIDIA driver falls back to a **40× slower** synchronization path.

### Symptoms

Training throughput dramatically lower than expected. In nsight profiler:

```
cudaStreamSynchronize:  73.7% of CUDA API time  ← should be < 10%
ncclDevKernel_AllGather: 65.6% of GPU kernel time
All compute kernels:    < 2.2%                  ← starved
```

**Rule of thumb**: if `cudaStreamSynchronize` > 50% of CUDA API time, you are hitting this bug.

### Fix (lightweight — recommended)

```bash
mst gpu add
for dev in /dev/mst/netir*_gpu*; do
    resourcedump dump -d "$dev" -s 0x5024 > /dev/null 2>&1
done
```

Takes seconds. Triggers CX-8 firmware re-initialization. See [`scripts/cx8-fix.sh`](../scripts/cx8-fix.sh).

### Fix (DaemonSet — for automated deployments)

A DaemonSet version is at [`manifests/nvidia-b300-init.yaml`](../manifests/nvidia-b300-init.yaml). Runs once per node boot, writes a sentinel file to avoid re-running.

```bash
kubectl apply -f manifests/nvidia-b300-init.yaml
```

### Important notes

- ⚠ **Fix does NOT persist across VM reboots.** Must re-run after every reboot.
- NVIDIA is working on a permanent fix for a future driver/firmware release.
- This affects both training AND inference. Training (FSDP) is heavily impacted due to sync at every layer boundary.

### Validation

- Before fix: > 5 ms per `cudaDeviceSynchronize`.
- After fix: < 0.5 ms. Training throughput improves 5–7×.
- Field result: 7.3× speedup on AllGather. Training matched B200.

---

## §3 — Software Stack — `sm_103` Kernel Gap

### The problem

B300's compute capability is `sm_103`. PyTorch, NGC containers, and cuDNN do NOT include `sm_103` in their builds. Kernels fall back to generic Blackwell paths via PTX JIT compilation.

### Scope

This is **ecosystem-wide**. Affects ALL cloud providers selling B300 for training. Not a DO issue.

- PyTorch [PR #152414](https://github.com/pytorch/pytorch/pull/152414): intentional exclusion
- NGC `26.04-py3`: `sm_103` absent from `TORCH_CUDA_ARCH_LIST`
- cuDNN audit: 6 / 4000 cubins have `sm_103` (0.15%)
- PyTorch [Issue #170476](https://github.com/pytorch/pytorch/issues/170476): CUTLASS GEMM crashes on SM103 (open)

### Diagnosis

```bash
python3 -c "import torch; print(torch.cuda.get_arch_list())"
```

If `sm_103` is absent and the device is B300, this is the expected gap.

### What to do

**Option 1 (recommended)**: accept current performance.

After the CX-8 fix, B300 matches B200 on BF16 (identical FLOPS spec). B300's advantage is 25% larger HBM (275 vs 192 GB) → bigger batch sizes → higher throughput.

**Option 2**: build PyTorch from source.

```bash
export TORCH_CUDA_ARCH_LIST="10.3;10.3a"
```

Improves aten kernels but NOT cuDNN (pre-built binaries). Partial improvement only.

**Option 3**: wait for upstream. No timeline from NVIDIA.

### What to tell customers

> "B300 training matches B200 on BF16 — expected from the hardware spec. B300's advantage is the 25% larger HBM for higher throughput. The software ecosystem is catching up — this affects all providers equally."

---

## §4 — Container and Image Issues

### GHCR image pull 403

Worker pods fail to pull from `ghcr.io` with 403.

```bash
kubectl create secret docker-registry slurmd-pull-secret \
  --docker-server=ghcr.io \
  --docker-username=YOUR_USER \
  --docker-password=YOUR_PAT \
  -n slurm
```

### Helm chart image tag mismatch

Slinky Helm chart references `25.11-ubuntu24.04` which doesn't exist. Override in values:

```yaml
image:
  tag: "25.11.5-ubuntu24.04"
```

This repo's [`helm/slinky/values-slurm.yaml.tpl`](../helm/slinky/values-slurm.yaml.tpl) already does this for `slurmctld`, `slurmdbd`, login, and `slurmrestd`.

### NFS Terraform drift

`terraform plan` always shows change on `performance_tier`:

```hcl
resource "digitalocean_managed_nfs" "shared" {
  # ...
  lifecycle {
    ignore_changes = [performance_tier]
  }
}
```

---

## §5 — Known Platform Limitations

| Issue | Impact | Status | Workaround |
|---|---|---|---|
| GDR not working | Minor — 841 GB/s without it | Escalated | None needed for now |
| PFC QoS | Risk at 20+ nodes | Under investigation | Discuss with infra pre-commit |
| CPU performance | Workload-specific | Under investigation | GPU-dominant workloads less affected |

---

## §6 — NCCL Environment Variables Cheat Sheet

### Always set

| Var | Value | Why |
|---|---|---|
| `NCCL_SOCKET_IFNAME` | `eth0` | Bootstrap interface |
| `NCCL_DEBUG` | `WARN` or `INFO` | Logging level |

### Do **NOT** set

| Var | Why not |
|---|---|
| `NCCL_IB_TC` | Not needed with 16 fabrics properly configured |
| `NCCL_CROSS_NIC` | Default behavior is correct |
| `NCCL_IB_GID_INDEX` | GID table populated correctly with 16 NADs |
| `NCCL_IB_HCA` | Let NCCL auto-discover all HCAs |
| `NCCL_IB_DISABLE=1` | Forces TCP fallback — never set |
| `NCCL_NET_GDR_LEVEL` | GDR not available on current platform |
| `NCCL_ALGO=NVLS` | NVLS Broadcast breaks FSDP (`ncclInt8` unsupported) |

### Optional — debugging only

| Var | Value | When |
|---|---|---|
| `NCCL_IB_TIMEOUT` | `22` | QP timeout errors |
| `NCCL_IB_RETRY_CNT` | `7` | Intermittent failures |
| `NCCL_BUFFSIZE` | `33554432` | Buffer warnings |

---

## References

### Repos

- Working B300 Slinky config: <https://github.com/iambigmomma/slinky-on-doks>
- NCCL reference: <https://github.com/RithishRamesh-dev/doks-multi-node/tree/main/B300>
- Upstream: <https://github.com/DO-Solutions/slinky-on-doks>

### PyTorch / NVIDIA

- PyTorch [PR #152414](https://github.com/pytorch/pytorch/pull/152414) — `sm_103` excluded from build matrix
- PyTorch [Issue #170476](https://github.com/pytorch/pytorch/issues/170476) — CUTLASS GEMM SM103 runtime error (open)

### DigitalOcean

- GPU Droplet docs: <https://docs.digitalocean.com/products/droplets/gpu/>
- DOKS multi-node guide: <https://docs.digitalocean.com/products/kubernetes/how-to/configure-multinode-gpus/>

---

## Need a hand?

If you've been through this guide and you're still stuck — or if you want to evaluate B300 for production training — contact your DigitalOcean account team or `sales@digitalocean.com`. We do paid POCs for serious workloads.
