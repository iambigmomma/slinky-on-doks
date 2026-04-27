# Custom slurmd image with CUDA, NCCL, nccl-tests, and RDMA userspace
# for GPU training validation on DOKS B300/H100 nodes.
#
# CUDA_MAJ/CUDA_MIN must match the driver on the target DOKS GPU nodes.
# 12.4 is used as the stable baseline; override at build time for newer drivers:
#   docker build --build-arg CUDA_MAJ=12 --build-arg CUDA_MIN=8 ...
FROM --platform=linux/amd64 ghcr.io/slinkyproject/slurmd:25.11.5-ubuntu24.04

USER root

ARG CUDA_MAJ=12
ARG CUDA_MIN=4
ARG CUDA_DISTRO=ubuntu2404

# RDMA userspace + networking diagnostics
RUN apt-get update && apt-get install -y --no-install-recommends \
        libibverbs-dev \
        rdma-core \
        ibverbs-utils \
        perftest \
        iproute2 \
        wget \
        gnupg2 \
        ca-certificates \
        git \
        build-essential \
        cmake \
        libopenmpi-dev \
        openmpi-bin \
    && rm -rf /var/lib/apt/lists/*

# CUDA keyring
RUN wget -qO /tmp/cuda-keyring.deb \
        https://developer.download.nvidia.com/compute/cuda/repos/${CUDA_DISTRO}/x86_64/cuda-keyring_1.1-1_all.deb && \
    dpkg -i /tmp/cuda-keyring.deb && \
    rm /tmp/cuda-keyring.deb

# CUDA runtime + dev headers (driver lives on the host node, not in image)
RUN apt-get update && apt-get install -y --no-install-recommends \
        cuda-cudart-dev-${CUDA_MAJ}-${CUDA_MIN} \
        cuda-libraries-dev-${CUDA_MAJ}-${CUDA_MIN} \
        cuda-nvtx-${CUDA_MAJ}-${CUDA_MIN} \
    && rm -rf /var/lib/apt/lists/*

# NCCL (apt picks the version compatible with installed CUDA)
RUN apt-get update && apt-get install -y --no-install-recommends \
        libnccl2 \
        libnccl-dev \
    && rm -rf /var/lib/apt/lists/*

# Build nccl-tests (all_reduce_perf, reduce_scatter_perf, all_gather_perf)
RUN git clone --depth 1 https://github.com/NVIDIA/nccl-tests.git /tmp/nccl-tests && \
    cd /tmp/nccl-tests && \
    make MPI=1 \
         MPI_HOME=/usr/lib/x86_64-linux-gnu/openmpi \
         CUDA_HOME=/usr/local/cuda \
         NCCL_HOME=/usr && \
    cp build/all_reduce_perf build/reduce_scatter_perf build/all_gather_perf /usr/local/bin/ && \
    rm -rf /tmp/nccl-tests

ENV LD_LIBRARY_PATH="/usr/local/cuda/lib64:/usr/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH}"
ENV PATH="/usr/local/cuda/bin:${PATH}"
