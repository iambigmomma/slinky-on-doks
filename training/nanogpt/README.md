# nanoGPT Training Demo

Train a 25M-parameter GPT model on Shakespeare's complete works using Slinky (Slurm on DOKS) on NVIDIA B300 GPUs.

> This demo is part of the [B300 GPU Training Tutorial](../../README.md). It is based on [Andrej Karpathy's nanoGPT](https://github.com/karpathy/nanoGPT).

## What it does

1. Downloads ~1MB of Shakespeare text
2. Tokenizes with GPT-2 BPE (tiktoken)
3. Trains a 6-layer / 6-head / 384-embed GPT (~25M params)
4. Loss drops from ~10.9 to ~1.5 in ~5 min on 8×B300
5. Generates Shakespeare-style text from the trained model

## Files

| File | Purpose |
|---|---|
| `prepare_data.py` | Download + tokenize Shakespeare → `train.bin`, `val.bin` |
| `train.py` | Self-contained GPT model + DDP training loop |
| `generate.py` | Load checkpoint and generate text |

The corresponding sbatch wrappers are in [`jobs/`](../../jobs/):
- `jobs/train-nanogpt.sh` — single-node (8 GPUs)
- `jobs/train-nanogpt-multinode.sh` — 2-node (16 GPUs)
- `jobs/generate-nanogpt.sh` — text generation (1 GPU)

## Quick start (from a Slinky login pod)

```bash
# 1. Stage code + jobs into NFS so workers can see them
cp -r training/nanogpt /shared/training/
cp jobs/train-nanogpt*.sh jobs/generate-nanogpt.sh /shared/jobs/

# 2. Prepare data (one-time, ~10 sec)
python /shared/training/nanogpt/prepare_data.py

# 3. Train (single node, 8 GPUs, ~5 min)
sbatch /shared/jobs/train-nanogpt.sh

# 4. Watch progress
squeue
tail -f /shared/output/nanogpt-<JOBID>.out

# 5. Generate text
PROMPT="ROMEO: O, " sbatch /shared/jobs/generate-nanogpt.sh
```

## Local smoke test (no GPU required)

`train.py` accepts `--device cpu` so you can sanity-check the model code on a laptop before deploying:

```bash
python prepare_data.py --out_dir /tmp/shakespeare
python train.py \
    --data_dir /tmp/shakespeare \
    --checkpoint_dir /tmp/ckpt \
    --device cpu \
    --max_steps 5 \
    --batch_size 4 \
    --dtype float32
```

This catches Python / dependency / data-loading bugs before paying for GPU time.

## Design choices

- **No `torch.compile`** — B300's compute capability is `sm_103`. PyTorch + Triton don't have native `sm_103` kernels yet; `torch.compile` crashes. The job scripts set `TORCHINDUCTOR_DISABLE=1`. See [`docs/b300-troubleshooting-guide.md`](../../docs/b300-troubleshooting-guide.md#3-software-stack--sm_103-kernel-gap) §3.
- **Flash attention via `F.scaled_dot_product_attention`** — built into PyTorch, no extra deps.
- **BF16 autocast** — B300's native training precision (same FLOPS as B200 at BF16).
- **NFS checkpoints** — `/shared/checkpoints/nanogpt/` persists across nodes.
- **No external deps beyond `torch`, `tiktoken`, `numpy`** — all baked into the `slurmd-cuda` image.
