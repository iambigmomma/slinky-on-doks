# Troubleshooting — B300 on Slinky / DOKS

Quick reference. For full explanations and root-cause analysis, see [`docs/b300-troubleshooting-guide.md`](docs/b300-troubleshooting-guide.md).

## Symptom → Fix

| # | Symptom | Likely cause | Fix |
|---|---|---|---|
| 1 | NCCL multi-node bandwidth 1–5 GB/s, logs show `NET/Socket` | Only 8 of 16 fabric NADs configured | [§1 — 16 fabric NADs](#1-only-8-fabric-nads) |
| 2 | `ibv_modify_qp failed with 61` on GPUs 5–7 | Same — missing fabric8–15 | [§1 — 16 fabric NADs](#1-only-8-fabric-nads) |
| 3 | Training 5–7× slower than expected; `cudaStreamSync > 50%` CUDA API time | CX-8 firmware did not init on VM boot | [§2 — CX-8 fix](#2-cx-8-firmware-fix) |
| 4 | Forward pass slow, backward pass fine; `sm_103` missing from arch list | PyTorch / Triton ecosystem gap for B300 | [§3 — sm_103 gap (no fix today)](#3-sm_103-ecosystem-gap) |
| 5 | `torch.compile` crashes with PTX / Triton error | sm_103 + ptxas mismatch | Set `TORCHINDUCTOR_DISABLE=1` (already in our job scripts) |
| 6 | Worker pods stuck in `ImagePullBackOff` with 403 from ghcr.io | DC IPs blocked without auth | [§4 — GHCR PAT pull secret](#4-ghcr-403) |
| 7 | Helm chart pulls slurmd image but tag `25.11-ubuntu24.04` returns 404 | Chart default refers to nonexistent tag | [§4 — Override tag](#4-helm-chart-image-tag) |
| 8 | `terraform plan` always shows NFS `performance_tier` change | DO API casing mismatch with Terraform state | [§4 — NFS drift](#4-nfs-terraform-drift) |

---

## 1. Only 8 fabric NADs

B300 has **16** fabric NICs (2 per GPU × 8 GPUs). AMD MI325X has 8 (1 per GPU). Most public examples are written for 8. With only 8 NADs, half the IB topology is invisible to the pod, NCCL falls back to TCP, and errno 61 fires on GPUs whose NICs are unmapped.

Verify on the host:
```bash
ip link show | grep -c fabric          # expect 16
```

Verify in cluster:
```bash
kubectl get net-attach-def -n slurm | grep -c roce-net-fabric   # expect 16
```

If you see 8: apply [`manifests/fabric-nads.yaml`](manifests/fabric-nads.yaml) (already 16 in this repo) and confirm `helm/slinky/values-slurm.yaml.tpl` lists all 16 in both `metadata.annotations.k8s.v1.cni.cncf.io/networks` and `resources.requests/limits.rdma/fabric0..15`.

## 2. CX-8 firmware fix

DOKS runs VMs (KVM/QEMU). ConnectX-8 firmware sometimes does not finish initializing on boot, and the NVIDIA driver falls back to a 40× slower sync path.

Apply via DaemonSet (recommended):
```bash
kubectl apply -f manifests/nvidia-b300-init.yaml
```

The DaemonSet writes a sentinel at `/var/run/cx8-fix.done` so it does not re-run unnecessarily. A reboot clears the sentinel — fix re-applies automatically.

Or run the script manually on each host:
```bash
bash scripts/cx8-fix.sh
```

⚠ **Fix does NOT persist across reboots.** It must run after every VM reboot.

## 3. `sm_103` ecosystem gap

B300's compute capability is `sm_103`. PyTorch's pre-built wheels, NGC containers, and cuDNN do not include `sm_103` cubins. Kernels fall back to generic Blackwell paths via PTX JIT.

This affects **all cloud providers** selling B300 — not a DO issue.

Check:
```bash
python3 -c "import torch; print(torch.cuda.get_arch_list())"
```
If `sm_103` is absent and the device is B300, this is the expected gap.

**What to do**: accept current performance. After the CX-8 fix, B300 matches B200 on BF16 training (same FLOPS spec). B300's edge is 25% larger HBM (275 vs 192 GB) → larger batch sizes → higher real-world throughput.

Do NOT use `torch.compile` — Triton + ptxas have not caught up to `sm_103a`. Crash mode. Our job scripts set `TORCHINDUCTOR_DISABLE=1` defensively.

## 4. Container / image / Terraform fixes

### 4. GHCR 403

```bash
kubectl create secret docker-registry slurmd-pull-secret \
  --docker-server=ghcr.io \
  --docker-username=YOUR_GH_USER \
  --docker-password=YOUR_PAT \
  -n slurm
```
`helm/slinky/values-slurm.yaml.tpl` already references `slurmd-pull-secret`.

### 4. Helm chart image tag

Upstream chart references `25.11-ubuntu24.04` which doesn't exist on ghcr.io. Override:
```yaml
controller:
  slurmctld:
    image:
      tag: "25.11.5-ubuntu24.04"
# (same for accounting.slurmdbd, loginsets.slinky.login, restapi.slurmrestd)
```
Already done in `helm/slinky/values-slurm.yaml.tpl`.

### 4. NFS Terraform drift

`terraform plan` reports constant change on `digitalocean_managed_nfs.performance_tier`. The DO API returns a different casing than Terraform stored. Workaround:

```hcl
resource "digitalocean_managed_nfs" "shared" {
  # ...
  lifecycle {
    ignore_changes = [performance_tier]
  }
}
```

---

## NCCL Environment Variables Cheat Sheet

### Set only these two
| Var | Value | Why |
|---|---|---|
| `NCCL_SOCKET_IFNAME` | `eth0` | Bootstrap interface |
| `NCCL_DEBUG` | `WARN` or `INFO` | Logging |

### Do **NOT** set these
| Var | Why not |
|---|---|
| `NCCL_IB_TC` | Not needed with 16 fabrics properly configured |
| `NCCL_CROSS_NIC` | Default behavior is correct |
| `NCCL_IB_GID_INDEX` | GID table is correct with 16 NADs |
| `NCCL_IB_HCA` | Let NCCL auto-discover all 16 |
| `NCCL_IB_DISABLE=1` | Forces TCP fallback — never |
| `NCCL_NET_GDR_LEVEL` | GDR not available on current platform |
| `NCCL_ALGO=NVLS` | NVLS Broadcast breaks FSDP (`ncclInt8` unsupported) |

### Optional, debugging only
| Var | Value | When |
|---|---|---|
| `NCCL_IB_TIMEOUT` | `22` | QP timeout errors |
| `NCCL_IB_RETRY_CNT` | `7` | Intermittent failures |
| `NCCL_BUFFSIZE` | `33554432` | Buffer warnings |

---

## When you're still stuck

- Full guide: [`docs/b300-troubleshooting-guide.md`](docs/b300-troubleshooting-guide.md)
- Architecture explainer: [`docs/architecture.md`](docs/architecture.md)
- DigitalOcean DOKS multi-node GPU docs: <https://docs.digitalocean.com/products/kubernetes/how-to/configure-multinode-gpus/>
- Need B300 capacity, hands-on help, or a paid POC? Contact your DigitalOcean account team or `sales@digitalocean.com`.
