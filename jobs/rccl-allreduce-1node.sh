#!/bin/bash
#SBATCH --job-name=rccl-allreduce-1node
#SBATCH --partition=slinky
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=8
#SBATCH --gres=gpu:8
#SBATCH --output=/shared/output/allreduce-1node-%j.out
#SBATCH --error=/shared/output/allreduce-1node-%j.err
#SBATCH --time=00:30:00

mkdir -p /shared/output

# RCCL environment
export LD_LIBRARY_PATH=/opt/rocm/lib:/opt/lib:${LD_LIBRARY_PATH}
export NCCL_DEBUG=INFO

# MPI control traffic over pod network
export OMPI_MCA_btl=self,tcp
export OMPI_MCA_btl_tcp_if_include=eth0

srun --mpi=pmix \
  /home/rccl/rccl-tests/build/all_reduce_perf \
  -b 1 -e 16G -f 2 -g 1 -c 1 -n 100
