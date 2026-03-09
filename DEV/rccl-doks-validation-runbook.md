# Running RCCL Collective Tests via Slurm/Slinky on DOKS

This runbook validates RCCL all_reduce performance on AMD MI350X hardware by submitting jobs through Slurm, with Slinky managing the underlying Kubernetes pod lifecycle on DigitalOcean Kubernetes Service (DOKS). The goal is to prove the full Slurm-on-K8s path works end-to-end for GPU collective communication workloads over the DOKS high-speed fabric.

## DOKS GPU Node Architecture

Understanding the DOKS networking topology is essential because it differs from a typical bare-metal setup in ways that affect how RCCL and MPI are configured.

Each multi-node MI350X worker node in DOKS has three classes of network interface:

- **`eth0`** -- Public internet connectivity.
- **`eth1`** -- Private VPC network for communication between nodes in the same VPC. This is what the bare-metal `mpirun` commands use (`--mca btl_tcp_if_include eth1`), but it is _not_ the high-speed fabric.
- **`fabric0` through `fabric7`** -- Eight dedicated high-speed NICs connected to the GPU fabric. These are RDMA-capable and map one-per-GPU. This is where inter-node GPU collective traffic should flow.

The bare-metal commands you have use TCP over `eth1` for MPI transport and the RCCL ANP plugin for GPU-to-GPU collectives. On DOKS, the fabric NICs are the correct path for RCCL collective traffic, and they support RDMA, which bypasses the CPU and OS kernel entirely. This is a significant performance advantage over TCP on `eth1`.

## Prerequisites

### What DOKS Provides Automatically

When you create a cluster with a multi-node MI350X node pool, DOKS handles:

- **AMDGPU driver and ROCm** -- Installed on the host. No action needed.
- **ROCm Device Plugin** -- Auto-deployed. Exposes `amd.com/gpu` resources to the scheduler. Can be toggled via the `amd_gpu_device_plugin` API flag, but should be left on.
- **Mellanox k8s-rdma-shared-dev-plugin** -- Auto-installed when you add a fabric-connected node pool. Exposes RDMA resources as `rdma/fabric0` through `rdma/fabric7` for use in pod resource requests.

Optionally, you can also enable the **AMD Device Metrics Exporter** by setting `amd_gpu_device_metrics_exporter_plugin` to `true` via the API when creating or updating the cluster. This feeds GPU telemetry into your monitoring stack.

For full details on DOKS multi-node GPU configuration, see the [DigitalOcean multi-node GPU docs](https://docs.digitalocean.com/products/kubernetes/how-to/configure-multinode-gpus/).

### What You Must Configure

#### 1. Multus CNI Plugin

Multus moves the `fabric0-7` host NICs into the container network namespace. Without it, pods cannot see the fabric interfaces. Install it:

```bash
kubectl apply -f https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/master/deployments/multus-daemonset-thick.yml
```

This does not affect existing `eth0`/`eth1` traffic, which continues through Cilium.

#### 2. NetworkAttachmentDefinitions for Fabric NICs

Create a `NetworkAttachmentDefinition` for each of the eight fabric NICs. These tell Multus how to attach each NIC to a pod using the `host-device` CNI plugin:

```yaml
# fabric-nads.yaml
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: roce-net-fabric0
spec:
  config: '{
      "cniVersion": "0.3.1",
      "type": "host-device",
      "device": "fabric0"
    }'
---
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: roce-net-fabric1
spec:
  config: '{
      "cniVersion": "0.3.1",
      "type": "host-device",
      "device": "fabric1"
    }'
---
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: roce-net-fabric2
spec:
  config: '{
      "cniVersion": "0.3.1",
      "type": "host-device",
      "device": "fabric2"
    }'
---
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: roce-net-fabric3
spec:
  config: '{
      "cniVersion": "0.3.1",
      "type": "host-device",
      "device": "fabric3"
    }'
---
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: roce-net-fabric4
spec:
  config: '{
      "cniVersion": "0.3.1",
      "type": "host-device",
      "device": "fabric4"
    }'
---
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: roce-net-fabric5
spec:
  config: '{
      "cniVersion": "0.3.1",
      "type": "host-device",
      "device": "fabric5"
    }'
---
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: roce-net-fabric6
spec:
  config: '{
      "cniVersion": "0.3.1",
      "type": "host-device",
      "device": "fabric6"
    }'
---
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: roce-net-fabric7
spec:
  config: '{
      "cniVersion": "0.3.1",
      "type": "host-device",
      "device": "fabric7"
    }'
```

Apply in the namespace where Slinky will create compute pods:

```bash
kubectl apply -f fabric-nads.yaml --namespace=<slinky-compute-namespace>
```

**Important:** Each fabric NIC can only be attached to a single container at a time. Since each worker node runs one 8-GPU workload pod, this is not a contention issue in practice, but it means you cannot oversubscribe fabric NICs across multiple pods on the same node.

#### 3. Slinky Pod Template Configuration

This is the critical integration point. Slinky creates pods for Slurm job steps, and those pods need two things that don't come from standard Slurm resource requests:

**RDMA resource requests.** The pod spec must include `rdma/fabric0: 1` through `rdma/fabric7: 1` in resource limits so the RDMA shared device plugin exposes the RDMA verbs interfaces.

**Multus annotation.** The pod spec must include the Multus network annotation to attach all eight fabric NICs:

```yaml
metadata:
  annotations:
    k8s.v1.cni.cncf.io/networks: >-
      roce-net-fabric0@fabric0,
      roce-net-fabric1@fabric1,
      roce-net-fabric2@fabric2,
      roce-net-fabric3@fabric3,
      roce-net-fabric4@fabric4,
      roce-net-fabric5@fabric5,
      roce-net-fabric6@fabric6,
      roce-net-fabric7@fabric7
```

How you inject these into Slinky's pod templates depends on the Slinky version and configuration method. Options include the Slinky operator's `PodTemplate` CRD, a mutating admission webhook that matches on Slinky-created pods, or Slurm's `job_container` plugin configuration. This is a cluster-level setting -- once configured, every GPU job gets fabric access without per-job changes.

**Verification.** The combined resource block for a compute pod should look like:

```yaml
resources:
  requests:
    amd.com/gpu: 8
    rdma/fabric0: 1
    rdma/fabric1: 1
    rdma/fabric2: 1
    rdma/fabric3: 1
    rdma/fabric4: 1
    rdma/fabric5: 1
    rdma/fabric6: 1
    rdma/fabric7: 1
  limits:
    amd.com/gpu: 8
    rdma/fabric0: 1
    rdma/fabric1: 1
    rdma/fabric2: 1
    rdma/fabric3: 1
    rdma/fabric4: 1
    rdma/fabric5: 1
    rdma/fabric6: 1
    rdma/fabric7: 1
```

### Slurm Configuration

**GPU GRes.** Each compute node must advertise 8 GPUs. With Slinky, this flows through the operator's CRDs. Verify:

```bash
sinfo -N -o "%N %G"
# Expected:
# gpu-node-01 gpu:8
# gpu-node-02 gpu:8
```

**PMIx support.** Required for `srun` to coordinate ranks:

```bash
srun --mpi=list
# Should include: pmix_v4 (or pmix_v3)
```

**Partition.** Both GPU nodes in a partition:

```bash
sinfo -p gpu
```

### Container Image

The image needs ROCm, RCCL, rccl-tests, and the ANP plugin. Since DOKS provides the host-level AMDGPU driver and ROCm, the container primarily needs the userspace libraries and test binaries. The image specification depends on how Slinky is configured (operator CRD, `#SBATCH --container`, or a site-default).

## Translating Bare-Metal Commands to DOKS

The bare-metal commands use two transport layers: MPI's byte transfer layer (BTL) over TCP on `eth1` for MPI control traffic, and the RCCL ANP plugin for GPU collective data. On DOKS, the key difference is that the fabric NICs support RDMA, so RCCL should use RDMA rather than TCP for inter-node collective traffic.

The relevant environment variable changes:

| Bare-metal setting | DOKS equivalent | Why |
|---|---|---|
| `--mca btl_tcp_if_include eth1` | `OMPI_MCA_btl_tcp_if_include=eth1` (unchanged for MPI control) | MPI control messages still use the VPC private network. The fabric NICs are for RDMA data traffic, not MPI BTL. |
| `NCCL_NET_PLUGIN=/opt/lib/librccl-anp.so` | Same, but the ANP plugin should detect and use the RDMA fabric interfaces | The ANP plugin needs the fabric NICs visible in the container (via Multus) and RDMA verbs available (via the RDMA shared device plugin). |
| N/A | `NCCL_IB_HCA=mlx5_0,mlx5_1,...` (may be needed) | If the ANP plugin doesn't auto-detect the correct RDMA devices, this variable explicitly lists them. Check RCCL debug logs. |
| N/A | `NCCL_NET_GDR_LEVEL=5` (may be needed) | Enables GPU Direct RDMA if supported, allowing RCCL to transfer data directly between GPU memory and the RDMA NIC without staging through host memory. |

## Test 0: Interactive Fabric Verification

Before running any RCCL tests, verify that the fabric and RDMA are correctly configured inside a Slurm allocation:

```bash
salloc --nodes=1 --gres=gpu:8 --partition=gpu --time=00:15:00
```

Once inside:

```bash
# Verify GPUs
srun rocm-smi

# Verify fabric NICs are visible in the pod
srun ip link show | grep fabric
# Expected: fabric0, fabric1, ..., fabric7

# Verify RDMA devices
srun ibv_devices
# Should list mlx5_X devices corresponding to the fabric NICs

# Check RDMA connectivity (if ibv_rc_pingpong is available)
# On node 1: srun --nodelist=gpu-node-01 ibv_rc_pingpong -d mlx5_0
# On node 2: srun --nodelist=gpu-node-02 ibv_rc_pingpong -d mlx5_0 <node1-fabric0-ip>
```

If `ip link show` does not show the fabric interfaces, the Multus annotation is missing from the Slinky pod template. If `ibv_devices` returns nothing, the RDMA resource requests are missing.

## Test 1: Single-Node All-Reduce (8 GPUs)

Single-node traffic stays within the node (intra-node), so the fabric NICs are less critical here. RCCL will use shared memory and PCIe/xGMI for intra-node communication. This test validates GPU visibility and basic RCCL functionality through Slurm.

### Batch Script

```bash
#!/bin/bash
#SBATCH --job-name=rccl-allreduce-1node
#SBATCH --partition=gpu
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=8
#SBATCH --gres=gpu:8
#SBATCH --output=allreduce-1node-%j.out
#SBATCH --error=allreduce-1node-%j.err
#SBATCH --time=00:30:00

# RCCL environment
export NCCL_NET_PLUGIN=/opt/lib/librccl-anp.so
export LD_LIBRARY_PATH=/home/rccl/libs:/home/rccl/rccl/build/release/:${LD_LIBRARY_PATH}
export NCCL_DEBUG=INFO
export NCCL_DEBUG_FILE=allreduce-1node-%h-%p.log

# MPI control traffic over VPC private network
export OMPI_MCA_btl=self,tcp
export OMPI_MCA_btl_tcp_if_include=eth1

srun --mpi=pmix \
  /home/rccl/rccl-tests/build/all_reduce_perf \
  -b 1 -e 16G -f 2 -g 1 -c 1 -n 100
```

### Submit and Monitor

```bash
sbatch allreduce-1node.sh
squeue -u $USER
tail -f allreduce-1node-<jobid>.out
```

### What to Look For

The `all_reduce_perf` output table shows bandwidth across message sizes. For intra-node on MI350X, RCCL should use xGMI/IF links between GPUs. Check the RCCL debug logs to confirm it selected the expected transport (not falling back to host-memory copies).

## Test 2: Multi-Node All-Reduce (16 GPUs, 2 Nodes)

This is the critical test. Inter-node collective traffic must traverse the RDMA fabric via the ANP plugin. If the fabric is misconfigured, RCCL will either fail or fall back to TCP over `eth1`, which will show dramatically lower bandwidth.

### Batch Script

```bash
#!/bin/bash
#SBATCH --job-name=rccl-allreduce-2node
#SBATCH --partition=gpu
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=8
#SBATCH --gres=gpu:8
#SBATCH --output=allreduce-2node-%j.out
#SBATCH --error=allreduce-2node-%j.err
#SBATCH --time=01:00:00

# RCCL environment
export NCCL_NET_PLUGIN=/opt/lib/librccl-anp.so
export LD_LIBRARY_PATH=/home/rccl/libs:/home/rccl/rccl/build/release/:${LD_LIBRARY_PATH}
export NCCL_DEBUG=INFO
export NCCL_DEBUG_FILE=allreduce-2node-%h-%p.log

# MPI control traffic over VPC private network
export OMPI_MCA_btl=self,tcp
export OMPI_MCA_btl_tcp_if_include=eth1

# RDMA fabric hints (adjust if ANP doesn't auto-detect)
# export NCCL_IB_HCA=mlx5_0,mlx5_1,mlx5_2,mlx5_3,mlx5_4,mlx5_5,mlx5_6,mlx5_7
# export NCCL_NET_GDR_LEVEL=5

srun --mpi=pmix \
  /home/rccl/rccl-tests/build/all_reduce_perf \
  -b 1G -e 16G -f 2 -g 1 -c 1 -n 100
```

### Key Differences from Single-Node

- `--nodes=2` and `-b 1G` match the bare-metal multi-node command.
- Slurm handles node selection and rank placement. No `-H 10.128.0.4:8,10.128.0.6:8`.
- The RCCL ANP plugin should auto-discover the RDMA fabric devices. If it doesn't, uncomment `NCCL_IB_HCA` and `NCCL_NET_GDR_LEVEL`.

### Interpreting Results

Compare the bandwidth at 1G-16G message sizes against the bare-metal baseline. Three possible outcomes:

1. **Bandwidth matches bare-metal.** The full stack is working: Slinky -> pods -> Multus -> RDMA fabric -> RCCL ANP. This is the goal.
2. **Bandwidth is significantly lower than bare-metal (e.g., 10-50x worse).** RCCL is likely falling back to TCP over `eth1` instead of RDMA over the fabric. Check debug logs for "NET/Socket" transport selection instead of the ANP/IB transport. Fix: verify Multus annotations and RDMA resource requests in the pod spec.
3. **Job fails with RCCL errors.** The ANP plugin can't find any usable network interface. Check that `ibv_devices` shows the Mellanox HCAs inside the pod (Test 0), and that `LD_LIBRARY_PATH` includes the correct RDMA userspace libraries.

## Troubleshooting

**Fabric NICs not visible in pod.** Multus is either not installed or the `NetworkAttachmentDefinition` resources are in the wrong namespace. Run `kubectl get net-attach-def -n <namespace>` to verify. Also check that the Slinky pod template includes the Multus annotation.

**`ibv_devices` returns empty.** RDMA resources aren't requested in the pod spec. Verify `rdma/fabric0` through `rdma/fabric7` are in the resource limits. Check the Mellanox RDMA shared device plugin is running: `kubectl get ds -n kube-system | grep rdma`.

**RCCL falls back to socket transport.** The ANP plugin loaded but couldn't find RDMA devices. This usually means the RDMA verbs interfaces are present but the plugin can't match them to the correct GPU topology. Try setting `NCCL_IB_HCA` explicitly and check that the RDMA device-to-GPU affinity is correct (each `mlx5_X` device should be on the same NUMA node as its corresponding GPU).

**`srun` hangs at launch.** PMIx wire-up failure. Verify `srun --mpi=list` includes your PMIx version. Also confirm pods can reach each other on `eth1` (VPC private network) for MPI control traffic.

**`/dev/shm` too small.** RCCL uses shared memory for intra-node communication. If the Slinky pod template doesn't mount a large `emptyDir` at `/dev/shm`, RCCL may fail or degrade. The pod spec should include:

```yaml
volumes:
- name: shm
  emptyDir:
    medium: Memory
    sizeLimit: 64Gi
volumeMounts:
- name: shm
  mountPath: /dev/shm
```

## Bare-Metal to DOKS/Slurm Translation Reference

| Bare-metal (`mpirun`) | DOKS/Slurm (`sbatch`/`srun`) |
|---|---|
| `--np 8` | `#SBATCH --ntasks-per-node=8` |
| `--np 16 -H host1:8,host2:8` | `#SBATCH --nodes=2 --ntasks-per-node=8` |
| `--bind-to none` | Default srun behavior (or `--cpu-bind=none`) |
| `--mca btl self,tcp` | `export OMPI_MCA_btl=self,tcp` |
| `--mca btl_tcp_if_include eth1` | `export OMPI_MCA_btl_tcp_if_include=eth1` (VPC, for MPI control only) |
| `-x NCCL_NET_PLUGIN=...` | `export NCCL_NET_PLUGIN=...` (same plugin, discovers RDMA fabric) |
| Fabric via TCP on eth1 | Fabric via RDMA on `fabric0-7` (Multus + RDMA plugin) |
| Process launcher: `mpirun` | `srun --mpi=pmix` |
| Node selection: manual IPs | Slurm scheduler |
| GPU binding: implicit | `--gres=gpu:8` + automatic `ROCR_VISIBLE_DEVICES` |

## Cluster-Level Setup Checklist

Before any jobs can run, these must be in place (one-time setup):

- [ ] Multi-node MI350X node pool created (contract-based, via DO sales)
- [ ] ROCm device plugin running (auto-deployed by DOKS)
- [ ] Mellanox RDMA shared device plugin running (auto-deployed for fabric-connected pools)
- [ ] Multus CNI installed (`kubectl apply` the thick daemonset)
- [ ] `NetworkAttachmentDefinition` resources created for `fabric0-7` in the Slinky compute namespace
- [ ] Slinky pod template configured with Multus annotation, RDMA resource requests, and `/dev/shm` mount
- [ ] Slurm GPU GRes configured and visible in `sinfo`
- [ ] PMIx available in `srun --mpi=list`
- [ ] Container image with ROCm userspace, RCCL, ANP plugin, and rccl-tests available
- [ ] AMD Device Metrics Exporter enabled (optional, for observability)
