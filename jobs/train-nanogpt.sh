#!/bin/bash
#SBATCH --job-name=nanogpt-1node
#SBATCH --partition=slinky
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --gres=gpu:8
#SBATCH --cpus-per-task=32
#SBATCH --mem=0
#SBATCH --time=00:30:00
#SBATCH --output=/shared/output/nanogpt-1node-%j.out
#SBATCH --error=/shared/output/nanogpt-1node-%j.err
# ============================================================================
# nanoGPT Shakespeare Training — Single Node (8× B300 GPUs)
#
# Trains a 25M-param GPT on Shakespeare's complete works.
# ~5 minutes wall time. Loss drops from ~10.9 to ~1.5.
# Checkpoint → /shared/checkpoints/nanogpt/best.pt
#
# Prerequisites:
#   1. CX-8 firmware fix applied (DaemonSet or scripts/cx8-fix.sh)
#   2. Data prepared once:
#        python /shared/training/nanogpt/prepare_data.py
#
# Usage:
#   sbatch jobs/train-nanogpt.sh
# Monitor:
#   squeue
#   tail -f /shared/output/nanogpt-1node-<JOBID>.out
# ============================================================================

set -euo pipefail
mkdir -p /shared/output

echo "============================================"
echo "  nanoGPT Training (1 node)"
echo "  Job ID: $SLURM_JOB_ID"
echo "  Node:   $(hostname)"
echo "  GPUs:   $(nvidia-smi -L | wc -l)"
echo "  Time:   $(date)"
echo "============================================"

DATA_DIR="/shared/data/shakespeare"
if [ ! -f "$DATA_DIR/train.bin" ]; then
    echo "Data not found. Running prepare_data.py..."
    python /shared/training/nanogpt/prepare_data.py --out_dir "$DATA_DIR"
fi

# NCCL — only set these two. See docs/b300-troubleshooting-guide.md §6.
export NCCL_SOCKET_IFNAME=eth0
export NCCL_DEBUG=WARN
export OMP_NUM_THREADS=4

# torch.compile + Triton incompatible with sm_103 — disable inductor
export TORCHINDUCTOR_DISABLE=1

NPROC=$(nvidia-smi -L | wc -l)
torchrun \
    --standalone \
    --nproc_per_node=$NPROC \
    /shared/training/nanogpt/train.py \
    --data_dir "$DATA_DIR" \
    --checkpoint_dir /shared/checkpoints/nanogpt \
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
echo "Training complete. Generate text with:"
echo "  PROMPT='ROMEO:' sbatch jobs/generate-nanogpt.sh"
