# Multi-Node B300 GPU Training on DigitalOcean Kubernetes with Slinky

End-to-end tutorial: provision a 2-node NVIDIA B300 cluster on DigitalOcean Kubernetes (DOKS), validate **800+ GB/s** NCCL all-reduce bandwidth across 16 GPUs, then train a GPT language model on Shakespeare and generate text from it — **15 minutes from clone to first generated token, after infrastructure is up**.

**Author**: Jeff Fan, Solutions Architect, EMEA — DigitalOcean
**Branch**: `feat/nvidia-b300-poc` (this fork) | **Upstream**: [`DO-Solutions/slinky-on-doks`](https://github.com/DO-Solutions/slinky-on-doks)

> **Need B300 capacity, hands-on help, or a paid POC?** Contact your DigitalOcean account team or `sales@digitalocean.com`. See [Talk to DO](#talk-to-do) at the bottom.

---

## What you'll build

```
┌──────────────────────────────────────────────────────────────────────┐
│                       DOKS cluster (single VPC)                      │
│                                                                      │
│  mgmt pool (CPU)            gpu pool (2× B300, 16 GPUs total)        │
│  ──────────────────         ──────────────────────────────────       │
│  slurmctld                  slurm-worker-slinky-0                    │
│  slurmdbd                   slurm-worker-slinky-1                    │
│  slurm-operator             (each: 8× B300, 16× RoCE NICs)           │
│  login pod                                                           │
│                                                                      │
│  Managed MySQL  ──► slurmdbd accounting                              │
│  Managed NFS    ──► /shared (data + checkpoints + logs)              │
└──────────────────────────────────────────────────────────────────────┘
```

Slinky runs Slurm inside Kubernetes pods. Your ML team uses familiar `sbatch` / `squeue` / `sinfo`. The cluster underneath is managed DOKS — control-plane upgrades, GPU node pools, taints, all handled.

By the end you'll have:

1. A working 2-node B300 cluster with 16-NIC RoCE fabric
2. NCCL all-reduce benchmark confirming 800+ GB/s bus bandwidth
3. A 25M-parameter GPT trained on Shakespeare (~5 min wall time)
4. Generated Shakespeare-style text from the trained model
5. Multi-node tokens/sec comparison demonstrating ~1.7-1.8× scaling

---

## Why B300 on DigitalOcean

| | What you get |
|---|---|
| **Hardware** | NVIDIA B300 SXM6 AC — 8 GPUs per node, **275 GB HBM3e per GPU** (25% larger than B200), 16 ConnectX-8 NICs for RoCE fabric |
| **Region** | `ric1` (Richmond) — current B300 availability |
| **Managed everything** | DOKS control plane, MySQL (accounting), NFS (`/shared`) — SLA-backed, not "a pod we hope doesn't crash" |
| **Pricing model** | Flat per-hour. No egress charges. No GPU-hour surge pricing. Reserved contracts available. |
| **Familiar tooling** | Standard Kubernetes + Slurm. No proprietary scheduler, no vendor-locked control plane. |

If you want to evaluate this for your real training workload, **bring your model — we'll bring the B300s and an SA**. Skip to [Talk to DO](#talk-to-do).

---

## Prerequisites

### CLI tools

- [`doctl`](https://docs.digitalocean.com/reference/doctl/) authenticated (`doctl auth init`)
- [Terraform](https://www.terraform.io/) ≥ 1.5
- [Helm](https://helm.sh/) ≥ 3.12
- [`kubectl`](https://kubernetes.io/docs/tasks/tools/)
- [Docker](https://docs.docker.com/get-docker/) — only if you want to rebuild the slurmd image locally

### DigitalOcean account

- B300 capacity in `ric1` — request via your DO account team (contracted capacity)
- GPU Droplet access enabled (request via support if needed)

### Container registry

You'll need a `slurmd-cuda` image with NCCL + PyTorch + nanoGPT deps baked in. The Dockerfile is at [`docker/slurmd-cuda/Dockerfile`](docker/slurmd-cuda/Dockerfile). You can:

- **Use a pre-built image** at `ghcr.io/iambigmomma/slurmd-cuda:25.11-cuda12.6-torch2.8` (recommended for first run)
- **Build your own** — trigger [`.github/workflows/build-slurmd-cuda.yml`](.github/workflows) or `make docker/build-slurmd-cuda`

Either way, you'll need a GHCR personal access token for the image pull secret.

### Environment variables

| Variable | Required | Description |
|---|---|---|
| `DIGITALOCEAN_TOKEN` | Yes | DO API token (or `DO_API_TOKEN`) |
| `SLURMD_IMAGE` | Yes | e.g. `ghcr.io/iambigmomma/slurmd-cuda:25.11-cuda12.6-torch2.8` |
| `REGISTRY_USER` | Yes | GHCR username |
| `REGISTRY_PASSWORD` | Yes | GHCR PAT (read:packages scope is enough) |

---

## Tutorial

### Step 1 — Configure Terraform

```bash
cp terraform/terraform.tfvars.b300.example terraform/terraform.tfvars
# Edit if needed — defaults are 2× B300 nodes in ric1, ready to apply.
```

**Already have a DOKS cluster?** See [Bring Your Own Cluster](#bring-your-own-cluster) below — uncomment `existing_cluster_id` and `existing_vpc_id` so Terraform only creates MySQL + NFS.

### Step 2 — Provision infrastructure

```bash
make infra/init
make infra/apply
make infra/kubeconfig    # writes ~/.kube/config
```

Provisions: DOKS cluster (mgmt + GPU pools), Managed MySQL, Managed NFS, VPC. Takes ~10 minutes.

### Step 3 — Configure the 16-fabric network

B300 has **16 fabric NICs** (2 per GPU × 8 GPUs). This is the single most common B300 deployment bug — most public examples assume 8 NICs (AMD MI325X pattern). With 8 NADs, NCCL falls back to TCP and you get 1–5 GB/s instead of 800+ GB/s.

This repo already configures 16. Install:

```bash
make prereqs/install     # cert-manager + Prometheus
make nfs/configure       # /shared PV/PVC from Terraform outputs
make fabric/install      # Multus CNI + 16 NetworkAttachmentDefinitions
```

Verify:

```bash
kubectl get net-attach-def -n slurm | grep -c roce-net-fabric
# Expected: 16
```

For why 16 (not 8) and what fails when it's wrong, see [`docs/b300-troubleshooting-guide.md` §1](docs/b300-troubleshooting-guide.md#1-nccl-multi-node-networking-16-fabrics).

### Step 4 — Apply the CX-8 firmware fix

In VM environments (DOKS = KVM/QEMU), ConnectX-8 firmware sometimes doesn't fully initialize on boot. The NVIDIA driver falls back to a 40× slower sync path. Symptom: `cudaStreamSynchronize > 50%` of CUDA API time.

Apply the fix DaemonSet:

```bash
kubectl apply -f manifests/nvidia-b300-init.yaml
kubectl rollout status daemonset/nvidia-b300-cx8-init -n kube-system
```

The DaemonSet writes a sentinel at `/var/run/cx8-fix.done` on each GPU node so it only runs once per boot. A reboot wipes the sentinel — the fix re-applies automatically.

> ⚠ **The fix does NOT persist across reboots.** The DaemonSet handles this automatically. If you're applying manually with [`scripts/cx8-fix.sh`](scripts/cx8-fix.sh), you'll need to re-run after every node reboot.

Details: [`docs/b300-troubleshooting-guide.md` §2](docs/b300-troubleshooting-guide.md#2-cx-8-pcie-switch-firmware-bug).

### Step 5 — Deploy Slinky (Slurm-on-Kubernetes)

```bash
export SLURMD_IMAGE=ghcr.io/iambigmomma/slurmd-cuda:25.11-cuda12.6-torch2.8
export REGISTRY_USER=your-github-user
export REGISTRY_PASSWORD=your-ghcr-pat

make slinky/install-operator
make slinky/install-slurm
```

Verify all pods are running:

```bash
kubectl get pods -n slurm
```

[REPLACE WITH ACTUAL B300 OUTPUT — kubectl get pods -n slurm showing controller, accounting, login, 2 workers all Running]

### Step 6 — Validate NCCL bandwidth

#### Single-node (8 GPUs, intra-node)

```bash
make slurm/submit-nccl-1node
# or directly:
kubectl exec -it -n slurm deployment/login-slinky -- bash -lc \
  'cp /shared/jobs/nccl-allreduce-1node.sh /tmp/ && cd /shared && sbatch /tmp/nccl-allreduce-1node.sh'
```

Wait ~2 minutes. Read the output:

```bash
make slurm/shell
cat /shared/output/nccl-allreduce-1node-*.out
```

Expected: average bus bandwidth **~800 GB/s** intra-node.

[REPLACE WITH ACTUAL B300 OUTPUT — all_reduce_perf bandwidth table for 1-node]

#### Multi-node (16 GPUs, 2 nodes over RoCE)

```bash
make slurm/submit-nccl-2node
```

Expected: bandwidth table with **~800–850 GB/s** average bus bandwidth and `NCCL DEBUG=INFO` confirming `NET/IB` RoCE transport (not `NET/Socket`).

[REPLACE WITH ACTUAL B300 OUTPUT — 2-node all_reduce_perf table + NCCL INFO showing NET/IB RoCE]

If bandwidth is below 100 GB/s or you see `NET/Socket`, see [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md).

### Step 7 — Train your first model

Now that the cluster is validated, let's train something real — a 25M-parameter GPT on Shakespeare's complete works. Based on [Andrej Karpathy's nanoGPT](https://github.com/karpathy/nanoGPT).

**Stage the code on /shared NFS:**

```bash
make slurm/upload-nanogpt    # kubectl cp training/ + jobs/ into the login pod's /shared mount
```

> **Why a Make target instead of `cp` from inside the login pod?** The login pod uses the upstream `slinkyproject/login` image, which does **not** ship Python / torch / tiktoken / numpy and does **not** mount your local repo. Code lives on your workstation; the login pod sees it via NFS once it's been `kubectl cp`'d in.

> **Data prep** (download + tokenize Shakespeare) runs automatically inside `train-nanogpt.sh` the first time you submit — `prepare_data.py` needs `tiktoken`+`numpy`, which only exist in the slurmd-cuda worker image. Adds ~10 sec to the first job.

**Submit the single-node training job:**

```bash
sbatch /shared/jobs/train-nanogpt.sh
squeue                                          # job status
tail -f /shared/output/nanogpt-1node-*.out      # live progress
```

Expected: ~5 min wall time, loss drops from ~10.9 to ~1.5.

[REPLACE WITH ACTUAL B300 OUTPUT — training log showing step / loss / lr / tokens-per-sec, with eval checkpoints]

**Generate text from the trained model:**

```bash
PROMPT="ROMEO: O, " sbatch /shared/jobs/generate-nanogpt.sh
# Wait ~30 sec for it to schedule + run
cat /shared/output/nanogpt-generate-*.out
```

[REPLACE WITH ACTUAL B300 OUTPUT — generated Shakespeare-style text starting with "ROMEO: O, ..."]

### Step 8 — Multi-node scaling

Same model, same data — but now 2 nodes × 8 GPUs = 16 GPUs:

```bash
sbatch /shared/jobs/train-nanogpt-multinode.sh
tail -f /shared/output/nanogpt-2node-*.out
```

Compare `tokens/sec` from the last 100 steps of both runs. Expected scaling: **~1.7–1.8×** (not 2× because of inter-node all-reduce overhead). On B300 with 16 fabric NICs and the CX-8 fix in place, the multi-node penalty is small.

[REPLACE WITH ACTUAL B300 OUTPUT — side-by-side tokens/sec comparison]

If you don't see scaling (or scaling is < 1.3×), it's almost certainly one of:
- NCCL falling back to TCP (only 8 NADs configured) → [§1](docs/b300-troubleshooting-guide.md#1-nccl-multi-node-networking-16-fabrics)
- CX-8 firmware not initialized → [§2](docs/b300-troubleshooting-guide.md#2-cx-8-pcie-switch-firmware-bug)

---

## Troubleshooting

Quick reference: [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) — symptom → fix table.
Full guide: [`docs/b300-troubleshooting-guide.md`](docs/b300-troubleshooting-guide.md).

| Symptom | First place to look |
|---|---|
| NCCL bandwidth 1–5 GB/s | [§1 — 16 fabric NADs](docs/b300-troubleshooting-guide.md#1-nccl-multi-node-networking-16-fabrics) |
| Training mysteriously slow | [§2 — CX-8 firmware fix](docs/b300-troubleshooting-guide.md#2-cx-8-pcie-switch-firmware-bug) |
| `torch.compile` crashes | [§3 — `sm_103` ecosystem gap](docs/b300-troubleshooting-guide.md#3-software-stack--sm_103-kernel-gap) |
| `ImagePullBackOff` on workers | [§4 — GHCR PAT pull secret](docs/b300-troubleshooting-guide.md#4-container-and-image-issues) |
| `terraform plan` keeps showing NFS drift | [§4 — `lifecycle ignore_changes`](docs/b300-troubleshooting-guide.md#nfs-terraform-drift) |

---

## Bring Your Own Cluster

If you already have a DOKS cluster with a B300 pool, Terraform can provision **only** the Managed MySQL + Managed NFS and leave your cluster alone.

```bash
# Find your cluster + VPC IDs in one shot:
doctl kubernetes cluster get <your-cluster-name> -o json | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
if isinstance(d, list): d = d[0]
print('cluster_id:', d['id'])
print('vpc_id:    ', d['vpc_uuid'])
"
```

Set them in `terraform/terraform.tfvars`:
```hcl
existing_cluster_id = "abc-1234-..."
existing_vpc_id     = "def-5678-..."
```

Then:
```bash
make infra/init && make infra/apply    # creates MySQL + NFS only
make infra/kubeconfig                  # uses doctl to fetch kubeconfig
make up-from-existing                  # deploys Slinky on top
```

---

## Repository Layout

```
slinky-on-doks/
├── README.md                     ← you are here
├── TROUBLESHOOTING.md            ← quick symptom → fix reference
├── MANUAL-INSTALL-GUIDE.md       ← step-by-step kubectl/helm (no Makefile)
├── Makefile                      ← all the `make` targets
├── docker/slurmd-cuda/           ← custom slurmd image (CUDA + NCCL + PyTorch)
├── docker/slurmd-rocm/           ← AMD ROCm variant (out of scope for this tutorial)
├── docs/
│   ├── architecture.md           ← why this stack is built this way
│   └── b300-troubleshooting-guide.md   ← full troubleshooting reference
├── helm/slinky/                  ← Helm values template (16-fabric annotations)
├── jobs/                         ← sbatch scripts (NCCL benchmarks + nanoGPT)
├── manifests/
│   ├── fabric-nads.yaml          ← 16 NetworkAttachmentDefinitions
│   ├── nvidia-b300-init.yaml     ← CX-8 firmware fix DaemonSet
│   └── ...
├── scripts/
│   ├── cx8-fix.sh                ← manual CX-8 fix (alternative to DaemonSet)
│   └── ...
├── terraform/                    ← DOKS + MySQL + NFS provisioning
│   └── terraform.tfvars.b300.example   ← copy-ready B300 config
└── training/nanogpt/             ← training code (prepare, train, generate)
```

For the full list of Make targets, see `make help` or the [Makefile](Makefile).

---

## What's next

- Larger models (GPT-2 124M + FSDP) — the model class in `training/nanogpt/train.py` is straightforward to extend
- Hybrid storage (DO Spaces for cold datasets, NFS for hot working set)
- More than 2 nodes — needs PFC QoS configuration; talk to DO before scaling beyond ~16 B300s

---

## Talk to DO

This tutorial exists so you can evaluate B300 on DigitalOcean against your real workload, fast. If you got this far, you're past the "is the hardware real" question. The next step is:

**Bring your model. We'll bring B300 capacity and a Solutions Architect.**

- Existing DO customer? Talk to your account team — they can fast-track B300 capacity.
- New to DO? Email `sales@digitalocean.com` and mention "B300 POC, Slinky tutorial" so it routes correctly.
- For technical questions on this repo specifically, open a GitHub issue or reach out to the author (`Jeff Fan, Solutions Architect, EMEA`).

---

## Credits + support

- This training demo is based on [Andrej Karpathy's nanoGPT](https://github.com/karpathy/nanoGPT).
- Built on top of [Slinky](https://github.com/SlinkyProject/slurm-operator) (Slurm-on-Kubernetes operator).
- Upstream slinky-on-doks: [`DO-Solutions/slinky-on-doks`](https://github.com/DO-Solutions/slinky-on-doks).
- Reference 16-fabric config: [`RithishRamesh-dev/doks-multi-node`](https://github.com/RithishRamesh-dev/doks-multi-node/tree/main/B300).

> **Support disclaimer**: DigitalOcean does not provide direct support for Slinky or Slurm. These instructions are offered as guidance only. The underlying DigitalOcean services (DOKS, Managed NFS, Managed MySQL) are fully supported. Issues with Slinky, Slurm, or their configuration are outside the scope of DigitalOcean support — but we will help you scope them as part of a POC engagement.
