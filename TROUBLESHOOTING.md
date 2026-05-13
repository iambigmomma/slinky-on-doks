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
| 9 | `docker run <slurmd-image> python ...` hangs on `sssd / sshd` startup, your command never runs | Image entrypoint is `supervisord` for slurmd in-cluster, not a generic python shell | [§4 — Local testing](#4-local-testing-override-entrypoint) |
| 10 | Inside `make slurm/shell` running `python prepare_data.py` errors with `ModuleNotFoundError: tiktoken/torch/numpy` or `pip3: command not found` | Login pod uses upstream `slinkyproject/login` image — has no Python stack | [§5 — Login pod has no Python](#5-login-pod-has-no-python-stack) |
| 11 | `terraform apply` → `invalid version slug` | `k8s_version` in `variables.tf` / `terraform.tfvars` is older than what DOKS still serves | [§6 — terraform infra gotchas](#6-terraform-infra-gotchas) |
| 12 | `terraform apply` → `region has insufficient capacity for requested cluster for slug: c-4` | Default mgmt_node_size = `c-4` may have zero capacity in your chosen region | [§6 — terraform infra gotchas](#6-terraform-infra-gotchas) |
| 13 | `terraform apply` → `412 unable to create a cluster of that size in that region` (database) | DO out of capacity for that DB slug at that moment | [§6 — terraform infra gotchas](#6-terraform-infra-gotchas) |
| 14 | `terraform apply` → `NFS is not currently supported in this region` | Managed NFS exists only in atl1, ric1, ams3 today | [§6 — terraform infra gotchas](#6-terraform-infra-gotchas) |
| 15 | `terraform apply` → `range/size overlaps with another VPC` or `a VPC with the same name already exists` | A leftover (often default) VPC from previous work blocks the new VPC | [§6 — terraform infra gotchas](#6-terraform-infra-gotchas) |
| 16 | All slurm pods stuck `ImagePullBackOff` even though the pull secret exists | The `REGISTRY_PASSWORD` env var was empty / garbage when the secret was created (e.g. older `gh` versions without `gh auth token`) | [§6 — terraform infra gotchas](#6-terraform-infra-gotchas) |
| 17 | `kubectl cp` into the login pod fails with `tar: Cannot change ownership ... Operation not permitted` | NFS share root-squashes — tar's chown rejected. Files often arrive anyway but `kubectl cp` exits non-zero | [§6 — terraform infra gotchas](#6-terraform-infra-gotchas) |

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

### 4. Local testing — override entrypoint

The slurmd-cuda image's default entrypoint is `supervisord`, which boots `slurmd`, `sshd`, and `sssd` so the container can join a Slurm cluster. Running it with a plain `docker run … python script.py` will silently append your command to slurmd's argv and your script never executes.

For ad-hoc local testing (e.g. verifying `torch`/`tiktoken` import, or running the nanoGPT smoke test on CPU before submitting to Slurm), bypass supervisord with `--entrypoint`:

```bash
# Quick import check
docker run --rm --entrypoint python3 \
  ghcr.io/iambigmomma/slurmd-cuda:25.11-cuda12.6-torch2.8 \
  -c "import torch, tiktoken, numpy; print(torch.__version__)"

# Full CPU smoke test of the training code
docker run --rm -v "$(pwd):/repo" -w /repo --entrypoint bash \
  ghcr.io/iambigmomma/slurmd-cuda:25.11-cuda12.6-torch2.8 \
  -c 'python3 training/nanogpt/prepare_data.py --out_dir /tmp/sh && \
      python3 training/nanogpt/train.py --data_dir /tmp/sh \
        --checkpoint_dir /tmp/ckpt --device cpu --max_steps 5 \
        --batch_size 4 --dtype float32'
```

Inside the Slurm job (`jobs/train-nanogpt.sh`) you don't need to override anything — the slurmd worker is already initialised, and srun launches your command in the right context.

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

## 5. Login pod has no Python stack

The `slurm-login` pod ships with the upstream `ghcr.io/slinkyproject/login:25.11.5-ubuntu24.04` image, which is just a Slurm submit host: `srun`, `sbatch`, `squeue`, `scontrol`, SSH, SSSD. It does **not** include Python with `torch` / `tiktoken` / `numpy`, and it does **not** have `pip`.

That means commands like the following — if you've seen them in older docs — will fail inside `make slurm/shell`:

```bash
python /shared/training/nanogpt/prepare_data.py   # ModuleNotFoundError: tiktoken
pip3 install tiktoken                             # pip3: command not found
```

The training code that needs `torch` / `tiktoken` / `numpy` (`prepare_data.py`, `train.py`, `generate.py`) is intended to run on a **slurmd worker** — the slurmd-cuda image baked in this repo bundles all three.

How to ship code and data correctly:

```bash
# 1. Upload code from your laptop to /shared NFS (kubectl cp via the login pod)
make slurm/upload-nanogpt

# 2. Submit — the sbatch script auto-runs prepare_data.py on the worker if
#    /shared/data/shakespeare/train.bin is missing
sbatch /shared/jobs/train-nanogpt.sh
```

If you need to run arbitrary Python interactively against `/shared`, do it from a worker via `srun`:

```bash
srun --partition=slinky --pty bash -c "python /shared/training/nanogpt/prepare_data.py"
```

Do **not** override the login image to slurmd-cuda just to get Python — the upstream login image is intentionally minimal for sshd / SSSD reasons, and slurmd-cuda's supervisord entrypoint (see §4) is not designed for interactive login.

---

## 6. Terraform / infra gotchas

Caught while validating the full deploy flow end-to-end. Each was a real `terraform apply` failure or a silent post-deploy stuck state.

### 6.1 Stale `k8s_version`

DOKS deprecates Kubernetes patch versions every couple of months. The default in `variables.tf` will go stale. If apply returns:

> Error: Error creating Kubernetes cluster: ... invalid version slug

list current slugs and pin one:

```bash
curl -s -H "Authorization: Bearer $DO_API_TOKEN" \
  https://api.digitalocean.com/v2/kubernetes/options | jq -r '.options.versions[].slug'
# → 1.35.1-do.6, 1.34.5-do.6, 1.33.9-do.6
```

then set in `terraform.tfvars`:

```hcl
k8s_version = "1.35.1-do.6"
```

### 6.2 Region capacity for management nodes (`c-4`)

The Terraform default mgmt_node_size is `c-4` (CPU-optimised 4 vCPU / 8 GiB). Some regions have no `c-4` capacity at all and apply fails:

> region has insufficient capacity for requested cluster for slug: c-4

Use the standard equivalent (what DOKS actually serves in most regions):

```hcl
mgmt_node_size = "s-4vcpu-8gb-intel"
```

To list droplet slugs available in your region:

```bash
curl -s -H "Authorization: Bearer $DO_API_TOKEN" https://api.digitalocean.com/v2/regions \
  | jq -r '.regions[] | select(.slug=="ric1") | .sizes[]'
```

### 6.3 DB size 412 "unable to create … in that region"

`db-amd-1vcpu-2gb`, `db-s-1vcpu-2gb`, `db-s-2vcpu-4gb`, and even `gd-2vcpu-8gb` returned 412 in ric1 during one validation run. The slug is *listed* as supported but the supply pool is empty at that moment.

Mitigation: bump one tier up (`db-s-2vcpu-4gb` → `db-amd-2vcpu-4gb` → `db-amd-2vcpu-8gb`) and retry. Or wait and retry the same slug — capacity usually returns within hours.

### 6.4 NFS region support

DO managed NFS is currently shipping in **atl1, ric1, ams3** only. Other regions return:

> Error creating Share: ... NFS is not currently supported in this region

ric1 is the right choice for the B300 tutorial (B300 + NFS both live there). If you change region for any reason, confirm NFS support first:

```bash
# 400 with "minimum size" message = region supports NFS
# 400 with "not currently supported in this region" = nope
curl -s -X POST -H "Authorization: Bearer $DO_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"name\":\"probe\",\"region\":\"YOUR_REGION\",\"size_gib\":50,\"performance_tier\":\"high\",\"vpc_id\":\"probe\"}" \
  https://api.digitalocean.com/v2/nfs
```

### 6.5 Stale VPCs blocking new ones

DO blocks deletion of:
- Default VPCs (the one auto-created for each region; you can rename but not delete).
- VPCs that still have "active Subnets" (DOKS leftovers may linger after `terraform destroy`).

Symptoms on the next `terraform apply`:
- `range/size overlaps with another VPC network in your account` — your `vpc_cidr` collides with a leftover VPC's CIDR (DO compares across regions).
- `a VPC with the same name already exists in your account` — VPC names are globally unique in DO.

Mitigations:
- Pick a `vpc_cidr` clear of every default VPC you have (e.g. `10.130.32.0/20`).
- Rename leftover VPCs (PATCH `/v2/vpcs/{id}` with a new `name`) to free the `slinky-poc-vpc` namespace.
- Active-subnet VPCs eventually clean themselves up; wait or open a DO ticket.

### 6.6 `slurmd-pull-secret` containing a garbage password

`make slinky/create-pull-secret` reads `REGISTRY_PASSWORD` from the environment and creates a docker-registry secret without validating the value. If the env var is empty or contains an error string (e.g. older `gh` CLI versions returning `unknown command "token" for "gh auth"` because `gh auth token` was added in newer releases), every slurm pod ends up in `ImagePullBackOff`.

Diagnose:

```bash
kubectl get secret slurmd-pull-secret -n slurm -o jsonpath='{.data.\.dockerconfigjson}' \
  | base64 -d | jq '.auths."ghcr.io".auth' \
  | tr -d '"' | base64 -d
# Should print: <user>:<real-PAT>. If you see an error message or empty string, recreate.
```

Fix: get a valid PAT (read:packages scope is enough; for older `gh` versions, the token lives in `~/.config/gh/hosts.yml` under `oauth_token`), re-export `REGISTRY_PASSWORD`, and:

```bash
kubectl delete secret slurmd-pull-secret -n slurm
make slinky/create-pull-secret
kubectl delete pod -n slurm --all   # force re-pull
```

### 6.7 `kubectl cp` into the NFS-backed login pod errors on chown

DigitalOcean managed NFS exports with root-squash. When `kubectl cp` (which uses `tar` under the hood) tries to preserve the local uid/gid on the remote, NFS rejects the chown and tar exits 2. The files usually still land, but the make target / your script will report failure and any subsequent commands in the same `&&` chain are skipped.

Use `tar | kubectl exec … tar -xzf - --no-same-owner --no-same-permissions` instead of `kubectl cp` for any path that writes to `/shared`. The `slurm/upload-nanogpt` make target in this repo already does that — copy the pattern if you write your own upload helper.

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
