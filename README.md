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
| `obs/grafana` | Port-forward Grafana to localhost:3000 |

## Manual Guide

For step-by-step manual deployment instructions, see [DEV/installation-guidance.md](DEV/installation-guidance.md).
