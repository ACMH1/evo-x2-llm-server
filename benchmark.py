#!/usr/bin/env python3
"""
Ollama model benchmark — measures load time, prefill speed, and generation speed.

Usage:
    python3 benchmark.py [--host http://localhost:11434] [--runs 3]
"""

import argparse
import json
import sys
import time
import urllib.request
import urllib.error

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

MODELS = [
    ("qwen2.5-coder:7b",   "Coding baseline (7B)"),
    ("qwen2.5-coder:32b",  "Coding baseline (32B)"),
    ("qwen3-coder:30b",    "Coding primary — MoE 30B/3B active"),
    ("qwen3.5:35b-a3b",    "Fast KG extraction — MoE 35B/3B active"),
    ("deepseek-r1:70b",    "Logic / architecting (70B)"),
    ("llama4:scout",       "Bulk doc reading — MoE 109B, 10M ctx"),
]

# Fixed benchmark prompt — ~120 tokens input, asks for ~150 tokens output
PROMPT = (
    "Write a Python function that implements a binary search tree with insert, "
    "search, and in-order traversal methods. Include type hints and a brief "
    "docstring for each method. Keep it concise."
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def api(host, path, payload=None, method="POST"):
    url = f"{host}{path}"
    data = json.dumps(payload).encode() if payload else None
    req = urllib.request.Request(url, data=data,
                                  headers={"Content-Type": "application/json"},
                                  method=method)
    with urllib.request.urlopen(req, timeout=600) as r:
        return json.load(r)


def unload_all(host):
    """Set keep_alive=0 on a dummy generate to flush loaded models."""
    try:
        # List loaded models
        resp = api(host, "/api/ps", method="GET")
        for m in resp.get("models", []):
            api(host, "/api/generate", {
                "model": m["name"], "prompt": " ", "keep_alive": 0
            })
    except Exception:
        pass
    time.sleep(2)


def run_benchmark(host, model, runs):
    results = []
    for i in range(runs):
        unload_all(host)
        payload = {
            "model": model,
            "prompt": PROMPT,
            "stream": False,
            "keep_alive": 0,    # unload immediately after each run
        }
        t_start = time.time()
        try:
            resp = api(host, "/api/generate", payload)
        except urllib.error.HTTPError as e:
            return None, f"HTTP {e.code}: {e.reason}"
        except Exception as e:
            return None, str(e)
        t_total = time.time() - t_start

        load_s        = resp.get("load_duration", 0) / 1e9
        prefill_tok   = resp.get("prompt_eval_count", 0)
        prefill_s     = resp.get("prompt_eval_duration", 1) / 1e9
        gen_tok       = resp.get("eval_count", 0)
        gen_s         = resp.get("eval_duration", 1) / 1e9

        results.append({
            "load_s":       load_s,
            "prefill_tok":  prefill_tok,
            "prefill_tps":  prefill_tok / prefill_s if prefill_s > 0 else 0,
            "gen_tok":      gen_tok,
            "gen_tps":      gen_tok / gen_s if gen_s > 0 else 0,
            "total_s":      t_total,
            "response":     resp.get("response", "")[:200],
        })
        print(f"    run {i+1}/{runs}: load={load_s:.1f}s  "
              f"prefill={prefill_tok}tok@{prefill_tok/prefill_s:.1f}tps  "
              f"gen={gen_tok}tok@{gen_tok/gen_s:.1f}tps",
              flush=True)

    # Average across runs
    avg = {k: sum(r[k] for r in results) / len(results)
           for k in ("load_s", "prefill_tps", "gen_tps", "gen_tok", "prefill_tok")}
    avg["response"] = results[-1]["response"]
    return avg, None


def fmt(val, unit="", decimals=1):
    return f"{val:.{decimals}f}{unit}"


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="http://localhost:11434")
    parser.add_argument("--runs", type=int, default=2,
                        help="Runs per model (averaged)")
    parser.add_argument("--models", nargs="*",
                        help="Subset of models to benchmark (default: all)")
    args = parser.parse_args()

    models = [(m, d) for m, d in MODELS
              if args.models is None or m in args.models]

    print(f"\nOllama Benchmark  |  host={args.host}  runs={args.runs}")
    print(f"Prompt: {PROMPT[:80]}...")
    print("=" * 90)

    all_results = []
    for model, desc in models:
        print(f"\n[{model}]  {desc}")

        # Check model exists
        try:
            tags = api(args.host, "/api/tags", method="GET")
            available = [m["name"] for m in tags.get("models", [])]
            if model not in available:
                print(f"  SKIP — not found on server (available: {available})")
                continue
        except Exception as e:
            print(f"  ERROR checking tags: {e}")
            continue

        avg, err = run_benchmark(args.host, model, args.runs)
        if err:
            print(f"  ERROR: {err}")
            continue

        all_results.append((model, desc, avg))
        print(f"  AVERAGE → load={fmt(avg['load_s'],'s')}  "
              f"prefill={fmt(avg['prefill_tps'],' tok/s')}  "
              f"gen={fmt(avg['gen_tps'],' tok/s')}")

    # Summary table
    if not all_results:
        print("\nNo results to display.")
        return

    print("\n")
    print("=" * 90)
    print(f"{'Model':<30} {'Description':<35} {'Load':>7} {'Prefill':>10} {'Gen':>10}")
    print(f"{'':30} {'':35} {'(s)':>7} {'(tok/s)':>10} {'(tok/s)':>10}")
    print("-" * 90)
    for model, desc, avg in all_results:
        print(f"{model:<30} {desc:<35} "
              f"{fmt(avg['load_s'],'s'):>7} "
              f"{fmt(avg['prefill_tps']):>9} "
              f"{fmt(avg['gen_tps']):>9}")
    print("=" * 90)
    print()


if __name__ == "__main__":
    main()
