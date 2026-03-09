#!/bin/bash
#SBATCH --job-name=rccl-allreduce-2node
#SBATCH --partition=slinky
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=8
#SBATCH --gres=gpu:8
#SBATCH --output=/shared/output/allreduce-2node-%j.out
#SBATCH --error=/shared/output/allreduce-2node-%j.err
#SBATCH --time=01:00:00

mkdir -p /shared/output

# RCCL environment
export LD_LIBRARY_PATH=/opt/rocm/lib:/opt/lib:${LD_LIBRARY_PATH}
export NCCL_DEBUG=INFO

# MPI control traffic over pod network
export OMPI_MCA_btl=self,tcp
export OMPI_MCA_btl_tcp_if_include=eth0

# RDMA fabric hints (uncomment if ANP doesn't auto-detect)
# export NCCL_IB_HCA=mlx5_0,mlx5_1,mlx5_2,mlx5_3,mlx5_4,mlx5_5,mlx5_6,mlx5_7
# export NCCL_NET_GDR_LEVEL=5

srun --mpi=pmix \
  /home/rccl/rccl-tests/build/all_reduce_perf \
  -b 1G -e 16G -f 2 -g 1 -c 1 -n 100
