#!/usr/bin/env python3
"""
Minimal GPT training on Shakespeare — self-contained, DDP-ready.
Designed for B300 GPU training demo on Slinky/DOKS.

Single node:   torchrun --nproc_per_node=8 train.py
Multi-node:    torchrun --nnodes=2 --nproc_per_node=8 ... train.py
Via Slinky:    sbatch train-nanogpt.sh

Model: ~25M params (6 layers, 6 heads, embed=384)
Data:  Shakespeare (~1M tokens)
Time:  ~5 min on 8× B300, loss drops from ~4.2 to ~1.5

NOTE: Does NOT use torch.compile — avoids sm_103/Triton issues on B300.
"""
import os
import sys
import math
import json
import time
import argparse
import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
from torch.nn.parallel import DistributedDataParallel as DDP

# ────────────────────────────────────────────────────────
# Model
# ────────────────────────────────────────────────────────

class CausalSelfAttention(nn.Module):
    def __init__(self, n_embd, n_head, block_size, dropout=0.0):
        super().__init__()
        assert n_embd % n_head == 0
        self.n_head = n_head
        self.n_embd = n_embd
        self.c_attn = nn.Linear(n_embd, 3 * n_embd)
        self.c_proj = nn.Linear(n_embd, n_embd)
        self.attn_dropout = nn.Dropout(dropout)
        self.resid_dropout = nn.Dropout(dropout)

    def forward(self, x):
        B, T, C = x.size()
        q, k, v = self.c_attn(x).split(self.n_embd, dim=2)
        q = q.view(B, T, self.n_head, C // self.n_head).transpose(1, 2)
        k = k.view(B, T, self.n_head, C // self.n_head).transpose(1, 2)
        v = v.view(B, T, self.n_head, C // self.n_head).transpose(1, 2)
        # Flash attention (PyTorch 2.0+)
        y = F.scaled_dot_product_attention(q, k, v, is_causal=True, dropout_p=0.0)
        y = y.transpose(1, 2).contiguous().view(B, T, C)
        y = self.resid_dropout(self.c_proj(y))
        return y

class MLP(nn.Module):
    def __init__(self, n_embd, dropout=0.0):
        super().__init__()
        self.c_fc = nn.Linear(n_embd, 4 * n_embd)
        self.gelu = nn.GELU()
        self.c_proj = nn.Linear(4 * n_embd, n_embd)
        self.dropout = nn.Dropout(dropout)

    def forward(self, x):
        x = self.gelu(self.c_fc(x))
        x = self.dropout(self.c_proj(x))
        return x

class Block(nn.Module):
    def __init__(self, n_embd, n_head, block_size, dropout=0.0):
        super().__init__()
        self.ln_1 = nn.LayerNorm(n_embd)
        self.attn = CausalSelfAttention(n_embd, n_head, block_size, dropout)
        self.ln_2 = nn.LayerNorm(n_embd)
        self.mlp = MLP(n_embd, dropout)

    def forward(self, x):
        x = x + self.attn(self.ln_1(x))
        x = x + self.mlp(self.ln_2(x))
        return x

class GPT(nn.Module):
    def __init__(self, vocab_size, block_size, n_layer, n_head, n_embd, dropout=0.0):
        super().__init__()
        self.block_size = block_size
        self.tok_emb = nn.Embedding(vocab_size, n_embd)
        self.pos_emb = nn.Embedding(block_size, n_embd)
        self.drop = nn.Dropout(dropout)
        self.blocks = nn.ModuleList([
            Block(n_embd, n_head, block_size, dropout) for _ in range(n_layer)
        ])
        self.ln_f = nn.LayerNorm(n_embd)
        self.head = nn.Linear(n_embd, vocab_size, bias=False)
        # Weight tying
        self.tok_emb.weight = self.head.weight
        self.apply(self._init_weights)
        # Count params
        n_params = sum(p.numel() for p in self.parameters())
        print(f"Model: {n_params/1e6:.1f}M parameters")

    def _init_weights(self, module):
        if isinstance(module, nn.Linear):
            torch.nn.init.normal_(module.weight, mean=0.0, std=0.02)
            if module.bias is not None:
                torch.nn.init.zeros_(module.bias)
        elif isinstance(module, nn.Embedding):
            torch.nn.init.normal_(module.weight, mean=0.0, std=0.02)

    def forward(self, idx, targets=None):
        B, T = idx.size()
        assert T <= self.block_size
        pos = torch.arange(0, T, dtype=torch.long, device=idx.device)
        x = self.drop(self.tok_emb(idx) + self.pos_emb(pos))
        for block in self.blocks:
            x = block(x)
        x = self.ln_f(x)
        logits = self.head(x)
        loss = None
        if targets is not None:
            loss = F.cross_entropy(logits.view(-1, logits.size(-1)), targets.view(-1))
        return logits, loss

    @torch.no_grad()
    def generate(self, idx, max_new_tokens, temperature=0.8, top_k=200):
        for _ in range(max_new_tokens):
            idx_cond = idx[:, -self.block_size:]
            logits, _ = self(idx_cond)
            logits = logits[:, -1, :] / temperature
            if top_k is not None:
                v, _ = torch.topk(logits, min(top_k, logits.size(-1)))
                logits[logits < v[:, [-1]]] = -float("Inf")
            probs = F.softmax(logits, dim=-1)
            idx_next = torch.multinomial(probs, num_samples=1)
            idx = torch.cat((idx, idx_next), dim=1)
        return idx

# ────────────────────────────────────────────────────────
# Data loader
# ────────────────────────────────────────────────────────

class ShakespeareDataset:
    def __init__(self, data_dir, split, block_size, batch_size, device):
        data = np.memmap(os.path.join(data_dir, f"{split}.bin"), dtype=np.uint16, mode="r")
        self.data = data
        self.block_size = block_size
        self.batch_size = batch_size
        self.device = device

    def get_batch(self):
        ix = torch.randint(len(self.data) - self.block_size, (self.batch_size,))
        x = torch.stack([torch.from_numpy(self.data[i:i+self.block_size].astype(np.int64)) for i in ix])
        y = torch.stack([torch.from_numpy(self.data[i+1:i+1+self.block_size].astype(np.int64)) for i in ix])
        return x.to(self.device), y.to(self.device)

# ────────────────────────────────────────────────────────
# Training
# ────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser()
    # Data
    parser.add_argument("--data_dir", type=str, default="/shared/data/shakespeare")
    parser.add_argument("--checkpoint_dir", type=str, default="/shared/checkpoints/nanogpt")
    # Model (25M params)
    parser.add_argument("--n_layer", type=int, default=6)
    parser.add_argument("--n_head", type=int, default=6)
    parser.add_argument("--n_embd", type=int, default=384)
    parser.add_argument("--block_size", type=int, default=256)
    parser.add_argument("--dropout", type=float, default=0.1)
    # Training
    parser.add_argument("--batch_size", type=int, default=64)
    parser.add_argument("--max_steps", type=int, default=2000)
    parser.add_argument("--lr", type=float, default=3e-4)
    parser.add_argument("--weight_decay", type=float, default=0.1)
    parser.add_argument("--warmup_steps", type=int, default=100)
    parser.add_argument("--log_interval", type=int, default=10)
    parser.add_argument("--eval_interval", type=int, default=200)
    parser.add_argument("--save_interval", type=int, default=500)
    parser.add_argument("--dtype", type=str, default="bfloat16")
    parser.add_argument("--device", type=str, default="auto",
                        help="auto|cuda|cpu (auto = cuda if available, else cpu)")
    args = parser.parse_args()

    # ── Device + DDP setup ──
    if args.device == "auto":
        use_cuda = torch.cuda.is_available()
    elif args.device == "cpu":
        use_cuda = False
    else:
        use_cuda = True

    ddp = int(os.environ.get("RANK", -1)) != -1 and use_cuda
    if ddp:
        torch.distributed.init_process_group(backend="nccl")
        rank = int(os.environ["RANK"])
        local_rank = int(os.environ["LOCAL_RANK"])
        world_size = int(os.environ["WORLD_SIZE"])
        device = f"cuda:{local_rank}"
        torch.cuda.set_device(device)
        master = rank == 0
    else:
        rank = 0
        local_rank = 0
        world_size = 1
        device = "cuda" if use_cuda else "cpu"
        master = True

    device_name = torch.cuda.get_device_name() if use_cuda else "CPU"

    if master:
        os.makedirs(args.checkpoint_dir, exist_ok=True)
        print("=" * 60)
        print("  nanoGPT Training on Shakespeare")
        print(f"  Device: {device_name}")
        print(f"  GPUs: {world_size}")
        print(f"  DDP: {ddp}")
        print(f"  dtype: {args.dtype}")
        print("=" * 60)

    # ── Data ──
    train_data = ShakespeareDataset(args.data_dir, "train", args.block_size, args.batch_size, device)
    val_data = ShakespeareDataset(args.data_dir, "val", args.block_size, args.batch_size, device)

    # ── Model ──
    model = GPT(
        vocab_size=50257,
        block_size=args.block_size,
        n_layer=args.n_layer,
        n_head=args.n_head,
        n_embd=args.n_embd,
        dropout=args.dropout,
    ).to(device)

    if ddp:
        model = DDP(model, device_ids=[local_rank])

    raw_model = model.module if ddp else model

    # ── Optimizer ──
    param_dict = {pn: p for pn, p in raw_model.named_parameters() if p.requires_grad}
    decay_params = [p for n, p in param_dict.items() if p.dim() >= 2]
    nodecay_params = [p for n, p in param_dict.items() if p.dim() < 2]
    optim_groups = [
        {"params": decay_params, "weight_decay": args.weight_decay},
        {"params": nodecay_params, "weight_decay": 0.0},
    ]
    # fused AdamW requires CUDA; fall back to standard impl on CPU
    optimizer = torch.optim.AdamW(optim_groups, lr=args.lr, betas=(0.9, 0.95), fused=use_cuda)

    # ── LR schedule ──
    def get_lr(step):
        if step < args.warmup_steps:
            return args.lr * step / args.warmup_steps
        decay_ratio = (step - args.warmup_steps) / (args.max_steps - args.warmup_steps)
        coeff = 0.5 * (1.0 + math.cos(math.pi * decay_ratio))
        return args.lr * 0.1 + coeff * (args.lr - args.lr * 0.1)

    # ── AMP ──
    pt_dtype = {"float32": torch.float32, "bfloat16": torch.bfloat16, "float16": torch.float16}[args.dtype]
    if use_cuda:
        ctx = torch.amp.autocast(device_type="cuda", dtype=pt_dtype)
    else:
        import contextlib
        ctx = contextlib.nullcontext()

    # ── Eval ──
    @torch.no_grad()
    def estimate_loss(n_batches=20):
        model.eval()
        losses = {}
        for split_name, dataset in [("train", train_data), ("val", val_data)]:
            batch_losses = []
            for _ in range(n_batches):
                x, y = dataset.get_batch()
                with ctx:
                    _, loss = model(x, y)
                batch_losses.append(loss.item())
            losses[split_name] = np.mean(batch_losses)
        model.train()
        return losses

    # ── Training loop ──
    if master:
        print(f"\nStarting training for {args.max_steps} steps...")
        print(f"Tokens per step: {args.batch_size * args.block_size * world_size:,}")
        print()

    model.train()
    t0 = time.time()
    best_val_loss = float("inf")

    for step in range(args.max_steps):
        # LR schedule
        lr = get_lr(step)
        for param_group in optimizer.param_groups:
            param_group["lr"] = lr

        # Forward + backward
        x, y = train_data.get_batch()
        with ctx:
            _, loss = model(x, y)
        loss.backward()
        torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
        optimizer.step()
        optimizer.zero_grad(set_to_none=True)

        # Logging
        if master and step % args.log_interval == 0:
            dt = time.time() - t0
            tokens_per_sec = args.batch_size * args.block_size * world_size * (step + 1) / dt
            print(f"step {step:5d} | loss {loss.item():.4f} | lr {lr:.2e} | {tokens_per_sec:,.0f} tok/s")

        # Eval + save
        if step > 0 and step % args.eval_interval == 0:
            losses = estimate_loss()
            if master:
                print(f"  ── eval | train_loss {losses['train']:.4f} | val_loss {losses['val']:.4f}")
                if losses["val"] < best_val_loss:
                    best_val_loss = losses["val"]
                    ckpt_path = os.path.join(args.checkpoint_dir, "best.pt")
                    torch.save({
                        "model": raw_model.state_dict(),
                        "optimizer": optimizer.state_dict(),
                        "step": step,
                        "val_loss": best_val_loss,
                        "config": vars(args),
                    }, ckpt_path)
                    print(f"  ── saved best checkpoint (val_loss={best_val_loss:.4f}) → {ckpt_path}")

        # Periodic save
        if master and step > 0 and step % args.save_interval == 0:
            ckpt_path = os.path.join(args.checkpoint_dir, f"step_{step}.pt")
            torch.save({
                "model": raw_model.state_dict(),
                "step": step,
                "config": vars(args),
            }, ckpt_path)
            print(f"  ── checkpoint → {ckpt_path}")

    # ── Final ──
    total_time = time.time() - t0
    total_tokens = args.batch_size * args.block_size * world_size * args.max_steps
    if master:
        print()
        print("=" * 60)
        print("  Training complete!")
        print(f"  Steps: {args.max_steps}")
        print(f"  Time: {total_time:.1f}s ({total_time/60:.1f} min)")
        print(f"  Throughput: {total_tokens/total_time:,.0f} tokens/sec")
        print(f"  Best val_loss: {best_val_loss:.4f}")
        print(f"  Checkpoint: {args.checkpoint_dir}/best.pt")
        print("=" * 60)
        print()
        print("Next: generate text with:")
        print(f"  python generate.py --checkpoint {args.checkpoint_dir}/best.pt")

    if ddp:
        torch.distributed.destroy_process_group()

if __name__ == "__main__":
    main()
