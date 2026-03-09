# Slinky on DOKS — GPU Slurm Cluster

Automated deployment of [Slinky](https://github.com/SlinkyProject/slurm-operator) (Slurm on Kubernetes) on DigitalOcean DOKS with GPU worker nodes.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    DOKS Cluster (VPC)                        │
│                                                             │
│  ┌─────────────────────┐    ┌────────────────────────────┐  │
│  │    mgmt pool (CPU)  │    │     gpu pool (GPU)         │  │
│  │                     │    │  (auto-tainted by DOKS)    │  │
│  │  slurmctld          │    │                            │  │
│  │  slurmdbd           │    │  slurm-worker-slinky-0     │  │
│  │  slurmrestd         │    │  slurm-worker-slinky-1     │  │
│  │  login node         │    │  ...                       │  │
│  │  slurm-operator     │    │                            │  │
│  │  cert-manager       │    │                            │  │
│  │  prometheus/grafana  │    │                            │  │
│  └─────────┬───────────┘    └────────────────────────────┘  │
│            │                                                │
│  ┌─────────┴───────────┐    ┌────────────────────────────┐  │
│  │   Managed MySQL     │    │     Managed NFS            │  │
│  │   (accounting)      │    │     (/shared)              │  │
│  └─────────────────────┘    └────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

DOKS automatically applies taints to GPU node pools, so non-GPU workloads (operator, monitoring, Slurm control plane) naturally schedule on the mgmt nodes without explicit `nodeSelector` rules.

## Prerequisites

- DigitalOcean account with GPU Droplet access
- [doctl](https://docs.digitalocean.com/reference/doctl/) configured with your API token
- [Terraform](https://www.terraform.io/) >= 1.5
- [Helm](https://helm.sh/) >= 3.12
- [kubectl](https://kubernetes.io/docs/tasks/tools/)

## Quick Start

```bash
# 1. Configure
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# Edit terraform.tfvars — set region, GPU node size/count, gpu_vendor

# 2. Deploy everything
make up

# 3. Verify
make status
make slurm/shell   # interactive login node shell
```

## GPU Vendor Configuration

The default is AMD (`gpu_vendor = "amd"`). For NVIDIA GPUs, set in `terraform.tfvars`:

```hcl
gpu_vendor    = "nvidia"
gpu_node_size = "gpu-h100x1-80gb"  # or your NVIDIA droplet size
```

The Makefile automatically derives the correct taint key (`amd.com/gpu` or `nvidia.com/gpu`) and node selector label from the `gpu_vendor` variable.

## Make Targets

```
make help
```

| Target | Description |
|--------|-------------|
| `up` | Full deploy: infra, prereqs, NFS, operator, Slurm |
| `down` | Full teardown |
| `status` | Show status of all components |
| `infra/plan` | Preview Terraform changes |
| `infra/apply` | Provision DOKS, MySQL, NFS, VPC |
| `prereqs/install` | Install cert-manager and Prometheus |
| `nfs/configure` | Generate NFS PV/PVC from Terraform outputs |
| `slinky/install-operator` | Install Slinky operator with CRDs |
| `slinky/configure` | Generate Slurm values from template |
| `slinky/install-slurm` | Install Slurm cluster |
| `slurm/shell` | Interactive login node shell |
| `slurm/info` | Show sinfo, squeue, partitions |
| `docker/build-slurmd` | Build custom slurmd image with ROCm/RCCL |
| `docker/push-slurmd` | Push slurmd image to ghcr.io |
| `fabric/install` | Install Multus + fabric NADs |
| `fabric/status` | Check Multus and NAD status |
| `slurm/test-fabric` | Verify fabric NICs and RDMA devices on workers |
| `gpu/discover-gres` | Discover GPU device paths and print gres.conf line |
| `slurm/submit-rccl-1node` | Submit single-node RCCL all-reduce test |
| `slurm/submit-rccl-2node` | Submit multi-node RCCL all-reduce test |
| `obs/grafana` | Port-forward Grafana to localhost:3000 |

## RDMA Fabric Setup

GPU-to-GPU communication across nodes uses RoCE (RDMA over Converged Ethernet) over dedicated fabric NICs. This requires [Multus CNI](https://github.com/k8snetworkplumbingwg/multus-cni) to attach the host fabric interfaces into worker pods.

```bash
# Install Multus + NetworkAttachmentDefinitions
make fabric/install

# Verify
make fabric/status
```

Each DOKS MI325X node has 8 fabric NICs (`fabric0`–`fabric7`). The [NAD manifests](manifests/fabric-nads.yaml) use the `host-device` CNI plugin to move each NIC into the pod network namespace. The Helm values template wires these into worker pods via:

- **Multus annotations** — `k8s.v1.cni.cncf.io/networks` on the worker pod spec attaches all 8 fabric interfaces.
- **RDMA device resources** — `rdma/fabric0`–`rdma/fabric7` in the resource requests/limits ensure the device plugin exposes the corresponding RDMA devices.
- **GRes configuration** — GPU resources use file-based detection (`gres.conf`) mapping to `/dev/dri/renderD[128,136,...,184]` since Slurm's autodetect plugin is not available in the container. See [DigitalOcean multi-node GPU docs](https://docs.digitalocean.com/products/kubernetes/how-to/configure-multinode-gpus/) for fabric configuration details.

## RCCL Validation

RCCL (ROCm Communication Collectives Library) validation confirms GPU-to-GPU communication is working over the RDMA fabric.

### Prerequisites

- Fabric deployed (`make fabric/install`)
- Workers running the custom slurmd-rocm image (see [docker/slurmd-rocm/README.md](docker/slurmd-rocm/README.md))
- Compute nodes idle (`sinfo` shows `idle` state)

### Single-Node Test

Tests GPU-to-GPU bandwidth within one node (8 GPUs):

```bash
make slurm/submit-rccl-1node
```

Expected results: bandwidth table from `all_reduce_perf` with **~110 GB/s average bus bandwidth** across message sizes from 1B to 16GB.

### Multi-Node Test

Tests GPU-to-GPU bandwidth across 2 nodes (16 GPUs) using the RDMA fabric:

```bash
make slurm/submit-rccl-2node
```

Expected results: bandwidth table with **~350 GB/s average bus bandwidth** and `NCCL_DEBUG` output showing `NET/IB` RoCE transport selection.

### Reading Output

Job output is written to NFS at `/shared/output/`:

```
/shared/output/allreduce-1node-<jobid>.out
/shared/output/allreduce-2node-<jobid>.out
```

To read results from the login pod:

```bash
make slurm/shell
# then:
ls /shared/output/
cat /shared/output/allreduce-1node-*.out
```

### Fabric Verification

Confirm fabric NICs and RDMA devices are visible inside the worker pods:

```bash
make slurm/test-fabric
```

This checks for `fabric0`–`fabric7` interfaces and runs `ibv_devices` on a worker.

### Related Docs

- [docker/slurmd-rocm/README.md](docker/slurmd-rocm/README.md) — Custom container image build details
- [DEV/rccl-doks-validation-runbook.md](DEV/rccl-doks-validation-runbook.md) — Full operational runbook for RCCL validation

## Manual Guide

For step-by-step manual deployment instructions, see [DEV/installation-guidance.md](DEV/installation-guidance.md).
