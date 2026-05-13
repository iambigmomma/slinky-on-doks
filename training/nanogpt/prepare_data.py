#!/usr/bin/env python3
"""
Download and tokenize the Shakespeare dataset for nanoGPT training demo.
Dataset: ~1MB of Shakespeare's complete works.
Tokenizer: GPT-2 (tiktoken), vocab_size=50257.

Usage:
    python prepare_data.py --out_dir /shared/data/shakespeare

Output:
    train.bin  (~1.0M tokens, 80%)
    val.bin    (~0.25M tokens, 20%)
    meta.json  (vocab_size, dataset info)
"""
import os
import json
import argparse
import urllib.request
import numpy as np

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out_dir", type=str, default="/shared/data/shakespeare")
    args = parser.parse_args()

    os.makedirs(args.out_dir, exist_ok=True)

    # Download Shakespeare
    url = "https://raw.githubusercontent.com/karpathy/char-rnn/master/data/tinyshakespeare/input.txt"
    input_file = os.path.join(args.out_dir, "input.txt")
    if not os.path.exists(input_file):
        print(f"Downloading Shakespeare from {url}...")
        urllib.request.urlretrieve(url, input_file)
    
    with open(input_file, "r") as f:
        data = f.read()
    print(f"Dataset: {len(data):,} characters")

    # Tokenize with tiktoken (GPT-2 encoding)
    try:
        import tiktoken
        enc = tiktoken.get_encoding("gpt2")
        print("Using tiktoken GPT-2 encoding")
    except ImportError:
        print("tiktoken not found, installing...")
        os.system("pip install tiktoken -q")
        import tiktoken
        enc = tiktoken.get_encoding("gpt2")

    tokens = enc.encode_ordinary(data)
    tokens = np.array(tokens, dtype=np.uint16)
    print(f"Tokenized: {len(tokens):,} tokens (vocab_size=50257)")

    # Split 80/20
    n = len(tokens)
    split = int(n * 0.8)
    train_tokens = tokens[:split]
    val_tokens = tokens[split:]

    # Save as binary
    train_tokens.tofile(os.path.join(args.out_dir, "train.bin"))
    val_tokens.tofile(os.path.join(args.out_dir, "val.bin"))

    # Save metadata
    meta = {
        "vocab_size": 50257,
        "total_tokens": int(n),
        "train_tokens": int(split),
        "val_tokens": int(n - split),
        "encoding": "gpt2",
        "source": "tinyshakespeare",
    }
    with open(os.path.join(args.out_dir, "meta.json"), "w") as f:
        json.dump(meta, f, indent=2)

    print(f"Saved to {args.out_dir}/")
    print(f"  train.bin: {split:,} tokens")
    print(f"  val.bin:   {n - split:,} tokens")
    print("Done!")

if __name__ == "__main__":
    main()
