# Custom slurmd-rocm Container Image

Custom slurmd image that adds ROCm GPU userspace, RCCL collective communication libraries, and RDMA tools on top of the upstream [Slinky slurmd image](https://github.com/SlinkyProject/slurm-operator).

## Why This Image Exists

The upstream `ghcr.io/slinkyproject/slurmd:25.11-ubuntu24.04` image ships only the Slurm daemon — it has no GPU userspace libraries, RCCL, or RDMA tooling. Running GPU collective communication benchmarks (like `all_reduce_perf`) requires all of these.

## What It Contains

| Component | Package(s) | Purpose |
|-----------|-----------|---------|
| ROCm runtime | `hip-runtime-amd`, `rocminfo`, `rocm-smi-lib` | GPU userspace + diagnostics |
| HIP compiler | `hip-dev`, `hipify-clang`, `rocm-device-libs`, `rocm-cmake` | Building GPU code (rccl-tests) |
| RCCL | `rccl-dev` | GPU collective communication library |
| rccl-tests | Built from source with `MPI=1` | Benchmarks (`all_reduce_perf`, etc.) |
| RDMA userspace | `libibverbs-dev`, `rdma-core`, `ibverbs-utils` | InfiniBand/RoCE verbs |
| MPI | `libopenmpi-dev` | Multi-process launch for rccl-tests |

Key binaries available in the image:

- `/home/rccl/rccl-tests/build/all_reduce_perf` — RCCL all-reduce benchmark
- `/opt/rocm/bin/rocm-smi` — GPU status and monitoring
- `/opt/rocm/bin/rocminfo` — ROCm device info
- `ibv_devices` / `ibv_devinfo` — RDMA device enumeration

## ROCm Version

The image builds against **ROCm 7.0.2**, which must match the host ROCm version on DOKS GPU nodes. To verify the host version:

```bash
kubectl debug node/<gpu-node> -it --image=ubuntu -- cat /opt/rocm/.info/version
```

If the host ROCm version changes, update the `ROCM_VERSION` and `ROCM_APT_VERSION` build args in the [Dockerfile](Dockerfile).

## Build Prerequisites

- Docker (or compatible builder)
- A container registry you can push to (e.g., GHCR, Docker Hub, DO Container Registry)

## Build & Push

```bash
# Set your fully-qualified image reference
export SLURMD_IMAGE=ghcr.io/yourorg/slurmd-rocm:25.11

# Build the image
make docker/build-slurmd

# Login to your registry, then push
docker login ghcr.io  # or your registry
make docker/push-slurmd
```

## Dockerfile Decisions & Gotchas

- **AMDGPU apt repo required** — The ROCm repo alone is not enough; `libdrm-amdgpu` dependencies come from the separate `amdgpu` apt repository.
- **`rccl-dev` not just `rccl`** — The `-dev` package is needed to get the headers required for building rccl-tests.
- **HIP compiler toolchain** — `hip-dev`, `hipify-clang`, and `rocm-device-libs` are all required for the rccl-tests `make` to succeed.
- **`libopenmpi-dev`** — Required to build rccl-tests with `MPI=1` for multi-node support via `srun --mpi=pmix`.
- **ANP plugin placeholder** — The Dockerfile has a commented-out `COPY librccl-anp.so` line. The ANP RCCL network plugin is not yet publicly available; when it is, it should be copied into `/opt/lib/` and will be picked up automatically via `LD_LIBRARY_PATH`.
- **No GPU driver** — The image intentionally omits kernel-mode GPU drivers; these are provided by the host node and exposed into pods by the device plugin.
