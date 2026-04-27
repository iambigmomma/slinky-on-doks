# Custom slurmd image with CUDA, NCCL, nccl-tests, and RDMA userspace
# for GPU training validation on DOKS B300/H100 nodes.
FROM ghcr.io/slinkyproject/slurmd:25.11.5-ubuntu24.04 AS base

USER root

# CUDA version — must match the driver on DOKS GPU nodes.
# B300 target: CUDA 12.8. Adjust ARG if node driver differs.
ARG CUDA_VERSION=12.8.0
ARG CUDA_DISTRO=ubuntu2404
ARG NCCL_VERSION=2.25.1-1

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
        cuda-cudart-dev-12-8 \
        cuda-libraries-dev-12-8 \
        cuda-nvtx-12-8 \
        libcufft-dev-12-8 \
        libcurand-dev-12-8 \
    && rm -rf /var/lib/apt/lists/*

# NCCL from CUDA repo
RUN apt-get update && apt-get install -y --no-install-recommends \
        libnccl2=${NCCL_VERSION}+cuda12.8 \
        libnccl-dev=${NCCL_VERSION}+cuda12.8 \
    && rm -rf /var/lib/apt/lists/*

# Build nccl-tests (provides all_reduce_perf, reduce_scatter_perf, etc.)
RUN git clone --depth 1 https://github.com/NVIDIA/nccl-tests.git /home/nccl/nccl-tests && \
    cd /home/nccl/nccl-tests && \
    make MPI=1 \
         MPI_HOME=/usr/lib/x86_64-linux-gnu/openmpi \
         CUDA_HOME=/usr/local/cuda \
         NCCL_HOME=/usr/lib/x86_64-linux-gnu && \
    cp build/* /usr/local/bin/ && \
    rm -rf /home/nccl/nccl-tests/.git

ENV LD_LIBRARY_PATH="/usr/local/cuda/lib64:/usr/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH}"
ENV PATH="/usr/local/cuda/bin:${PATH}"
