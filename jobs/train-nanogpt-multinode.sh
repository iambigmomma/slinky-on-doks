#!/bin/bash
#SBATCH --job-name=nanogpt-2node
#SBATCH --partition=slinky
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=1
#SBATCH --gres=gpu:8
#SBATCH --cpus-per-task=32
#SBATCH --mem=0
#SBATCH --time=00:30:00
#SBATCH --output=/shared/output/nanogpt-2node-%j.out
#SBATCH --error=/shared/output/nanogpt-2node-%j.err
# ============================================================================
# nanoGPT Shakespeare Training — 2 Nodes (16× B300 GPUs)
#
# Same model as train-nanogpt.sh, across 2 nodes.
# Expected: ~1.7-1.8× throughput vs single node (inter-node comm overhead).
#
# Prerequisites:
#   1. Data prep already done (same as single-node)
#   2. CX-8 firmware fix applied on BOTH nodes
#   3. 16 fabric NADs configured (see docs/b300-troubleshooting-guide.md §1)
#
# Usage:
#   sbatch jobs/train-nanogpt-multinode.sh
# ============================================================================

set -euo pipefail
mkdir -p /shared/output

echo "============================================"
echo "  nanoGPT Training (2 nodes)"
echo "  Job ID:     $SLURM_JOB_ID"
echo "  Nodes:      $SLURM_JOB_NUM_NODES"
echo "  Node list:  $SLURM_JOB_NODELIST"
echo "  Time:       $(date)"
echo "============================================"

DATA_DIR="/shared/data/shakespeare"
if [ ! -f "$DATA_DIR/train.bin" ]; then
    echo "Data not found. Running prepare_data.py..."
    python /shared/training/nanogpt/prepare_data.py --out_dir "$DATA_DIR"
fi

# NCCL — only these two. See docs/b300-troubleshooting-guide.md §6.
export NCCL_SOCKET_IFNAME=eth0
export NCCL_DEBUG=WARN
export OMP_NUM_THREADS=4
export TORCHINDUCTOR_DISABLE=1

# Resolve master from first allocated node
MASTER_ADDR=$(scontrol show hostname "$SLURM_JOB_NODELIST" | head -n 1)
MASTER_PORT=29500
echo "Master: $MASTER_ADDR:$MASTER_PORT"

srun torchrun \
    --nnodes=$SLURM_JOB_NUM_NODES \
    --nproc_per_node=8 \
    --rdzv_id=$SLURM_JOB_ID \
    --rdzv_backend=c10d \
    --rdzv_endpoint="$MASTER_ADDR:$MASTER_PORT" \
    /shared/training/nanogpt/train.py \
    --data_dir "$DATA_DIR" \
    --checkpoint_dir /shared/checkpoints/nanogpt-2node \
    --max_steps 2000 \
    --batch_size 64 \
    --block_size 256 \
    --n_layer 6 \
    --n_head 6 \
    --n_embd 384 \
    --lr 3e-4 \
    --log_interval 10 \
    --eval_interval 200 \
    --save_interval 500 \
    --dtype bfloat16

echo ""
echo "Multi-node training complete. Compare tokens/sec with single-node."
