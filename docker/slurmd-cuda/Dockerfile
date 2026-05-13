# Custom slurmd image with CUDA, NCCL, nccl-tests, and RDMA userspace
# for GPU training validation on DOKS B300/H100 nodes.
#
# Multi-stage build:
#   Stage 1 (builder): compile nccl-tests using official nvidia/cuda devel image
#   Stage 2 (final):   slinky slurmd base + RDMA tools + compiled binaries
#
# CUDA_IMAGE controls the CUDA version used for compilation.
# The runtime CUDA driver comes from the host node — not baked into the image.
ARG CUDA_IMAGE=nvidia/cuda:12.6.3-devel-ubuntu24.04

# ── Stage 1: Build nccl-tests ────────────────────────────────────────────────
FROM --platform=linux/amd64 ${CUDA_IMAGE} AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
        git \
        build-essential \
        libopenmpi-dev \
        openmpi-bin \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 https://github.com/NVIDIA/nccl-tests.git /tmp/nccl-tests && \
    cd /tmp/nccl-tests && \
    make MPI=1 \
         MPI_HOME=/usr/lib/x86_64-linux-gnu/openmpi \
         CUDA_HOME=/usr/local/cuda \
         NCCL_HOME=/usr && \
    cp build/all_reduce_perf \
       build/reduce_scatter_perf \
       build/all_gather_perf \
       /usr/local/bin/ && \
    rm -rf /tmp/nccl-tests

# ── Stage 2: Slinky slurmd base ──────────────────────────────────────────────
FROM --platform=linux/amd64 ghcr.io/slinkyproject/slurmd:25.11.5-ubuntu24.04

USER root

# RDMA userspace + networking diagnostics + Python runtime for training
RUN apt-get update && apt-get install -y --no-install-recommends \
        libibverbs-dev \
        rdma-core \
        ibverbs-utils \
        perftest \
        iproute2 \
        libopenmpi-dev \
        openmpi-bin \
        python3 \
        python3-pip \
        python3-venv \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && ln -sf /usr/bin/python3 /usr/local/bin/python

# Copy NCCL runtime libraries from builder
COPY --from=builder /usr/lib/x86_64-linux-gnu/libnccl.so* \
                    /usr/lib/x86_64-linux-gnu/
# Copy CUDA runtime libraries needed at slurm job runtime
COPY --from=builder /usr/local/cuda/lib64/libcudart.so* \
                    /usr/local/cuda/lib64/

# Copy compiled benchmark binaries
COPY --from=builder /usr/local/bin/all_reduce_perf \
                    /usr/local/bin/reduce_scatter_perf \
                    /usr/local/bin/all_gather_perf \
                    /usr/local/bin/

# PyTorch + nanoGPT training deps (baked in so workers don't pip-install at job start).
# We pin torch to a cu126-compatible build. sm_103 (B300) is NOT in the build matrix —
# PTX JIT falls back to generic Blackwell at runtime. BF16 training works fine.
# See docs/b300-troubleshooting-guide.md §3 for the full sm_103 explanation.
RUN pip install --no-cache-dir --break-system-packages \
        --index-url https://download.pytorch.org/whl/cu126 \
        torch==2.5.1 \
    && pip install --no-cache-dir --break-system-packages \
        numpy \
        tiktoken

# torch.compile + Triton crash on sm_103. Disable inductor by default so users
# don't have to remember to set it per-job. Job scripts also set this defensively.
ENV TORCHINDUCTOR_DISABLE=1

ENV LD_LIBRARY_PATH="/usr/local/cuda/lib64:/usr/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH}"
