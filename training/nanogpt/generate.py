#!/usr/bin/env python3
"""
Generate Shakespeare-style text from a trained nanoGPT checkpoint.

Usage:
    python generate.py --checkpoint /shared/checkpoints/nanogpt/best.pt
    python generate.py --checkpoint /shared/checkpoints/nanogpt/best.pt --prompt "ROMEO:"
    python generate.py --checkpoint /shared/checkpoints/nanogpt/best.pt --num_tokens 500
"""
import os
import sys
import argparse
import torch
import torch.nn as nn
import torch.nn.functional as F

# Import model class (same file structure)
script_dir = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, script_dir)
from train import GPT


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--checkpoint", type=str, required=True)
    parser.add_argument("--prompt", type=str, default="\n")
    parser.add_argument("--num_tokens", type=int, default=300)
    parser.add_argument("--temperature", type=float, default=0.8)
    parser.add_argument("--top_k", type=int, default=200)
    parser.add_argument("--device", type=str, default="cuda")
    parser.add_argument("--seed", type=int, default=42)
    args = parser.parse_args()

    torch.manual_seed(args.seed)
    device = args.device

    # Load checkpoint
    print(f"Loading checkpoint: {args.checkpoint}")
    ckpt = torch.load(args.checkpoint, map_location=device, weights_only=False)
    config = ckpt["config"]

    # Build model
    model = GPT(
        vocab_size=50257,
        block_size=config["block_size"],
        n_layer=config["n_layer"],
        n_head=config["n_head"],
        n_embd=config["n_embd"],
        dropout=0.0,  # no dropout at inference
    ).to(device)
    model.load_state_dict(ckpt["model"])
    model.eval()

    step = ckpt.get("step", "?")
    val_loss = ckpt.get("val_loss", "?")
    print(f"Loaded model from step {step}, val_loss={val_loss}")

    # Tokenize prompt
    try:
        import tiktoken
        enc = tiktoken.get_encoding("gpt2")
    except ImportError:
        os.system("pip install tiktoken -q")
        import tiktoken
        enc = tiktoken.get_encoding("gpt2")

    prompt_tokens = enc.encode_ordinary(args.prompt)
    x = torch.tensor(prompt_tokens, dtype=torch.long, device=device).unsqueeze(0)

    # Generate
    print(f"\nPrompt: \"{args.prompt}\"")
    print(f"Generating {args.num_tokens} tokens (temperature={args.temperature}, top_k={args.top_k})...")
    print("─" * 60)

    with torch.no_grad():
        with torch.amp.autocast(device_type="cuda", dtype=torch.bfloat16):
            y = model.generate(x, max_new_tokens=args.num_tokens,
                             temperature=args.temperature, top_k=args.top_k)

    output = enc.decode(y[0].tolist())
    print(output)
    print("─" * 60)
    print(f"\nGenerated {args.num_tokens} tokens on {torch.cuda.get_device_name()}")


if __name__ == "__main__":
    main()
