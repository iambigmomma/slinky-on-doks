# Slinky on DOKS — Multi-Node GPU Training

Automated deployment of [Slinky](https://github.com/SlinkyProject/slurm-operator) (Slurm on Kubernetes) on DigitalOcean DOKS, from infrastructure provisioning through running a multi-node RCCL all-reduce benchmark over an RDMA fabric. NCCL (NVIDIA) workloads follow the same pattern — swap the GPU vendor, container image, and device paths.

> **Prefer manual steps?** See the [Manual Install Guide](MANUAL-INSTALL-GUIDE.md) for step-by-step kubectl/helm commands with explanations.

> **Support disclaimer**: DigitalOcean does not provide direct support for Slinky or Slurm. These instructions are offered as guidance only. While the underlying DigitalOcean services (DOKS, Managed NFS, DBaaS) are fully supported, issues related to Slinky, Slurm, or their configuration are outside the scope of DigitalOcean support.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    DOKS Cluster (VPC)                       │
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
│  │  prometheus/grafana │    │                            │  │
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

### CLI Tools

- [doctl](https://docs.digitalocean.com/reference/doctl/) configured with your API token
- [Terraform](https://www.terraform.io/) >= 1.5
- [Helm](https://helm.sh/) >= 3.12
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [Docker](https://docs.docker.com/get-docker/) (for building the custom slurmd image)

### DigitalOcean Account

- GPU Droplet access enabled (request via support if needed)
- `doctl` authenticated (`doctl auth init`)

### Container Registry

Workers run a custom slurmd image with ROCm/RCCL libraries. This image must be pushed to a registry accessible by DOKS (e.g., `ghcr.io`).

> **DOKS image size limits**: Layers > 5GB or total image size > 20GB are not supported until Q2 2026. The `slurmd-rocm` image is designed to stay within these limits. See [docker/slurmd-rocm/README.md](docker/slurmd-rocm/README.md) for build details.

### Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `DIGITALOCEAN_TOKEN` | Yes | DigitalOcean API token (used by Terraform) |
| `SLURMD_IMAGE` | Yes | Full image reference, e.g. `ghcr.io/yourorg/slurmd-rocm:25.11` |
| `REGISTRY_USER` | Yes | Registry username for image pull secret |
| `REGISTRY_PASSWORD` | Yes | Registry password/token for image pull secret |

## Configuration

### Terraform Variables

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# Edit terraform.tfvars — set region, GPU node size/count, gpu_vendor
```

### GPU Vendor

The default is AMD (`gpu_vendor = "amd"`). For NVIDIA GPUs, set in `terraform.tfvars`:

```hcl
gpu_vendor    = "nvidia"
gpu_node_size = "gpu-h100x1-80gb"  # or your NVIDIA droplet size
```

The Makefile automatically derives the correct taint key (`amd.com/gpu` or `nvidia.com/gpu`) and node selector label from the `gpu_vendor` variable.

## Quick Start

```bash
# 1. Build and push custom slurmd image
make docker/build-slurmd
docker login ghcr.io   # or your registry
make docker/push-slurmd

# 2. Deploy everything (infra, kubeconfig, prereqs, NFS, fabric, operator, Slurm)
make up

# 3. Discover GPUs and update Slurm config
make gpu/discover-gres
make slinky/update-slurm

# 4. Verify
make status
make slurm/shell   # interactive login node shell
```

## Step-by-Step Guide

### 1. Container Image

Build and push the custom slurmd image with ROCm/RCCL libraries:

```bash
make docker/build-slurmd
docker login ghcr.io
make docker/push-slurmd
```

This image is required because the upstream Slinky slurmd image does not include ROCm or RCCL. See [docker/slurmd-rocm/README.md](docker/slurmd-rocm/README.md) for details.

### 2. Infrastructure

Provision DOKS cluster, managed MySQL, managed NFS, and VPC:

```bash
make infra/apply
```

### 3. Kubeconfig

Save the cluster kubeconfig so `kubectl` and `helm` can reach the new cluster. This extracts the kubeconfig from Terraform state (DOKS clusters created by Terraform are not visible to `doctl`):

```bash
make infra/kubeconfig
```

> **Note**: `make up` runs this automatically after `infra/apply`.

### 4. Prerequisites

Install cert-manager (required by Slinky operator) and Prometheus/Grafana:

```bash
make prereqs/install
```

### 5. Storage

Create NFS PV/PVC from Terraform outputs, used as shared storage (`/shared`) across login and worker pods:

```bash
make nfs/configure
```

### 6. RDMA Fabric

Install Multus CNI and fabric NetworkAttachmentDefinitions for RoCE (RDMA over Converged Ethernet):

```bash
make fabric/install
```

Each GPU node has 8 fabric NICs (`fabric0`–`fabric7`). Multus attaches these into worker pods for GPU-to-GPU communication across nodes.

### 7. Slurm Operator

Install the Slinky operator with CRDs:

```bash
make slinky/install-operator
```

### 8. Slurm Cluster

Creates the DB secret, image pull secret, generates Helm values, and deploys the Slurm cluster:

```bash
make slinky/install-slurm
```

### 9. GPU Discovery

Discover GPU device paths on the GPU nodes and update the Slurm configuration:

```bash
make gpu/discover-gres
make slinky/update-slurm
```

This must run after GPU nodes are ready. It deploys a probe pod to detect device paths (e.g., `/dev/dri/renderD[128,136,...]` for AMD) and saves the result to `gres.conf`, then `update-slurm` re-deploys with the updated config.

### 10. Validation

```bash
make slurm/info            # sinfo, squeue, partitions
make slurm/test-fabric     # verify fabric NICs and RDMA devices
make status                # full component status
```

## Running RCCL Tests

RCCL (ROCm Communication Collectives Library) validation confirms GPU-to-GPU communication is working over the RDMA fabric.

**Prerequisites**: fabric deployed (`make fabric/install`), workers running the custom slurmd-rocm image, compute nodes idle (`sinfo` shows `idle` state).

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

## Teardown

```bash
make down
```

This runs the full teardown in reverse order: Slurm cluster, fabric, prerequisites, infrastructure.

## Make Targets Reference

```
make help
```

| Target | Description |
|--------|-------------|
| **Lifecycle** | |
| `up` | Full deploy: infra, prereqs, NFS, fabric, operator, Slurm |
| `down` | Full teardown |
| `status` | Show status of all components |
| **Infrastructure** | |
| `infra/init` | Initialize Terraform providers and backend |
| `infra/plan` | Preview Terraform changes |
| `infra/apply` | Provision DOKS, MySQL, NFS, VPC |
| `infra/kubeconfig` | Save kubeconfig from Terraform to ~/.kube/config |
| `infra/destroy` | Destroy all infrastructure |
| `infra/output` | Print all Terraform outputs |
| **Prerequisites** | |
| `prereqs/install` | Install cert-manager and Prometheus |
| `prereqs/status` | Check pod status across prerequisite namespaces |
| `prereqs/uninstall` | Uninstall all prerequisites |
| **NFS** | |
| `nfs/configure` | Generate NFS PV/PVC from Terraform outputs |
| `nfs/test` | Deploy busybox pod to verify NFS read/write |
| `nfs/status` | Check PV/PVC binding status |
| **Docker** | |
| `docker/build-slurmd` | Build custom slurmd image with ROCm/RCCL |
| `docker/push-slurmd` | Push slurmd image to registry |
| **Fabric** | |
| `fabric/install` | Install Multus + fabric NADs |
| `fabric/install-multus` | Install Multus CNI plugin |
| `fabric/install-nads` | Create fabric NetworkAttachmentDefinitions |
| `fabric/status` | Check Multus and NAD status |
| `fabric/uninstall` | Remove fabric NADs and Multus |
| **GPU** | |
| `gpu/discover-gres` | Discover GPU device paths and save gres.conf |
| **Slinky / Slurm** | |
| `slinky/install-operator` | Install Slinky operator with CRDs |
| `slinky/configure` | Generate values-slurm.yaml from template |
| `slinky/install-slurm` | Install Slurm cluster (creates secrets, configures, deploys) |
| `slinky/update-slurm` | Helm upgrade Slurm with updated values |
| `slinky/create-db-secret` | Create Slurm DB password secret |
| `slinky/create-pull-secret` | Create image pull secret |
| `slinky/status` | Show pods across slinky + slurm namespaces |
| `slinky/uninstall` | Uninstall Slurm cluster, operator, CRDs |
| `slinky/logs` | Tail operator and controller logs |
| **Slurm Operations** | |
| `slurm/shell` | Interactive shell on the login pod |
| `slurm/info` | Show sinfo, squeue, partitions |
| `slurm/test-fabric` | Verify fabric NICs and RDMA devices on workers |
| `slurm/submit-rccl-1node` | Submit single-node RCCL all-reduce test |
| `slurm/submit-rccl-2node` | Submit multi-node RCCL all-reduce test |
| `slurm/submit-test` | Copy job scripts to NFS and submit test jobs |
| `slurm/run-validation` | Run the full validation suite |
| `slurm/test-restapi` | Test slurmrestd API endpoints |
| **Observability** | |
| `obs/dashboard` | Deploy Slurm Grafana dashboard |
| `obs/grafana` | Port-forward Grafana to localhost:3000 |
| `obs/prometheus` | Port-forward Prometheus to localhost:9090 |

## Related Documentation

- [docker/slurmd-rocm/README.md](docker/slurmd-rocm/README.md) — Custom container image build details
