#!/bin/bash
#SBATCH --job-name=nanogpt-generate
#SBATCH --partition=slinky
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=4
#SBATCH --mem=16G
#SBATCH --time=00:05:00
#SBATCH --output=/shared/output/nanogpt-generate-%j.out
#SBATCH --error=/shared/output/nanogpt-generate-%j.err
# ============================================================================
# Generate Shakespeare-style text from a trained nanoGPT checkpoint.
# 1 GPU. ~10 seconds.
#
# Usage:
#   sbatch jobs/generate-nanogpt.sh
#   PROMPT='ROMEO: O, ' sbatch jobs/generate-nanogpt.sh
#   CHECKPOINT=/shared/checkpoints/nanogpt-2node/best.pt sbatch jobs/generate-nanogpt.sh
#
# Fun prompts:
#   PROMPT='HAMLET:'
#   PROMPT='To be, or not to be'
#   PROMPT='Enter KING HENRY'
# ============================================================================

set -euo pipefail
mkdir -p /shared/output

CHECKPOINT="${CHECKPOINT:-/shared/checkpoints/nanogpt/best.pt}"
PROMPT="${PROMPT:-\n}"
NUM_TOKENS="${NUM_TOKENS:-500}"
TEMPERATURE="${TEMPERATURE:-0.8}"

export TORCHINDUCTOR_DISABLE=1

echo "============================================"
echo "  nanoGPT Text Generation"
echo "  Checkpoint: $CHECKPOINT"
echo "  Prompt:     $PROMPT"
echo "  Tokens:     $NUM_TOKENS"
echo "============================================"
echo ""

python /shared/training/nanogpt/generate.py \
    --checkpoint "$CHECKPOINT" \
    --prompt "$PROMPT" \
    --num_tokens "$NUM_TOKENS" \
    --temperature "$TEMPERATURE"
