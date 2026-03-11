#!/usr/bin/env python3
"""
Ollama model quality evaluator.

Runs three task types against any set of Ollama models and produces a scored
report + raw JSON results file.

Tasks
-----
  kg_extraction    Extract a knowledge graph as JSON from a dense paragraph.
  code_generation  Write a correct Python function (assertions are executed).
  reasoning        Diagnose a timed latency-spike scenario with ranked causes.

Usage
-----
  # Evaluate all known models
  python3 eval.py

  # Evaluate specific models
  python3 eval.py --models qwen3-coder:30b llama4:scout

  # Evaluate only specific tasks
  python3 eval.py --tasks kg_extraction reasoning

  # Custom host / output directory
  python3 eval.py --host http://192.168.51.209:11434 --out /tmp/results

  # Add a model not in the built-in list
  python3 eval.py --models qwen3-coder:30b mistral:7b-instruct

Adding new tasks
----------------
  1. Add a dict to TASKS with keys: name, type ("kg" | "code" | "text"), prompt.
  2. For type "kg"   — eval_kg()   scores the JSON output automatically.
     For type "code" — eval_code() executes the code and checks return code.
     For type "text" — score_text() applies keyword heuristics; edit to suit.
  3. Done — the task will be included in the next run.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from datetime import date

# ---------------------------------------------------------------------------
# Known model registry (informational — any Ollama model name can be passed)
# ---------------------------------------------------------------------------

KNOWN_MODELS = [
    "qwen2.5-coder:7b",
    "qwen2.5-coder:32b",
    "qwen3-coder:30b",
    "qwen3.5:35b-a3b",
    "deepseek-r1:70b",
    "llama4:scout",
]

# ---------------------------------------------------------------------------
# Task definitions — edit prompts or add new entries freely
# ---------------------------------------------------------------------------

KG_TEXT = (
    "The Linux kernel, developed by Linus Torvalds in 1991, is the core of many "
    "operating systems. It uses a monolithic architecture where device drivers, file "
    "system management, and memory management all run in kernel space. The GNU project, "
    "started by Richard Stallman in 1983, provides the userspace tools that combine with "
    "the Linux kernel to form GNU/Linux distributions like Ubuntu and Fedora. Systemd, "
    "created by Lennart Poettering, replaced the traditional SysV init system and manages "
    "system services and the boot process on most modern Linux distributions."
)

TASKS = {
    "kg_extraction": {
        "name": "Knowledge Graph Extraction",
        "type": "kg",
        "prompt": (
            "Extract a knowledge graph from the text below. "
            "Output ONLY valid JSON with exactly two top-level keys:\n"
            '  "nodes": list of {{"id": str, "label": str, "type": str}}\n'
            '  "edges": list of {{"source": str, "target": str, "relation": str}}\n'
            "No markdown fences. No explanation. Just the JSON object.\n\n"
            f"Text: {KG_TEXT}"
        ),
    },
    "code_generation": {
        "name": "Code Generation & Correctness",
        "type": "code",
        "prompt": (
            "Write a Python function with this exact signature:\n\n"
            "    def find_prime_factors(n: int) -> list[int]\n\n"
            "It must return the prime factorisation of n as a sorted list with repetition.\n"
            "After the function, include these assertions (they must all pass):\n\n"
            "    assert find_prime_factors(1)   == []\n"
            "    assert find_prime_factors(12)  == [2, 2, 3]\n"
            "    assert find_prime_factors(100) == [2, 2, 5, 5]\n"
            "    assert find_prime_factors(97)  == [97]\n\n"
            "Output ONLY valid Python — no markdown fences, no explanation."
        ),
    },
    "reasoning": {
        "name": "Reasoning / System Diagnosis",
        "type": "text",
        "prompt": (
            "A company's microservices platform (20 services, REST APIs, shared PostgreSQL, "
            "Redis cache) experiences latency spikes exclusively between 02:00-04:00 UTC. "
            "CPU and memory stay normal. Network latency between services is elevated during spikes.\n\n"
            "Give exactly 3 root causes ranked by probability (most likely first). "
            "For each cause provide:\n"
            "  - One sentence explanation\n"
            "  - Two specific diagnostic commands or SQL queries to confirm it\n\n"
            "Be concise and specific."
        ),
    },
    # -----------------------------------------------------------------------
    # Add new tasks below this line. Example:
    #
    # "summarisation": {
    #     "name": "Document Summarisation",
    #     "type": "text",
    #     "prompt": "Summarise the following in 3 bullet points: ...",
    # },
    # -----------------------------------------------------------------------
}

# ---------------------------------------------------------------------------
# HTTP helper
# ---------------------------------------------------------------------------


def api(host: str, path: str, payload=None, method: str = "POST"):
    url = f"{host}{path}"
    data = json.dumps(payload).encode() if payload else None
    req = urllib.request.Request(
        url, data=data,
        headers={"Content-Type": "application/json"},
        method=method,
    )
    with urllib.request.urlopen(req, timeout=300) as r:
        return json.load(r)


def unload_all(host: str, timeout: int = 120):
    """Evict all loaded models and poll /api/ps until confirmed empty."""
    try:
        resp = api(host, "/api/ps", method="GET")
        for m in resp.get("models", []):
            api(host, "/api/generate", {
                "model": m["name"], "prompt": " ", "keep_alive": 0,
            })
    except Exception:
        pass
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            if not api(host, "/api/ps", method="GET").get("models"):
                return
        except Exception:
            pass
        time.sleep(2)


# ---------------------------------------------------------------------------
# Task evaluators
# ---------------------------------------------------------------------------


def eval_kg(response: str) -> dict:
    """Parse and score a KG JSON response (0-10)."""
    text = re.sub(r"```[a-z]*\n?", "", response).strip()
    match = re.search(r"\{[\s\S]*\}", text)
    if not match:
        return {"valid": False, "error": "no JSON object found",
                "nodes": 0, "edges": 0, "score": 0}
    try:
        data = json.loads(match.group())
    except json.JSONDecodeError as exc:
        return {"valid": False, "error": str(exc), "nodes": 0, "edges": 0, "score": 0}

    nodes = data.get("nodes", [])
    edges = data.get("edges", [])
    schema_nodes = all({"id", "label", "type"}.issubset(n.keys()) for n in nodes) if nodes else False
    schema_edges = all({"source", "target", "relation"}.issubset(e.keys()) for e in edges) if edges else False

    score = 0
    if nodes:      score += 2
    if edges:      score += 2
    if schema_nodes: score += 2
    if schema_edges: score += 2
    node_labels = " ".join(str(n.get("label", "")) for n in nodes).lower()
    for name in ("torvalds", "stallman", "poettering", "systemd", "gnu"):
        if name in node_labels:
            score += 0.4
    return {
        "valid": True,
        "nodes": len(nodes),
        "edges": len(edges),
        "schema_ok": schema_nodes and schema_edges,
        "score": min(10, round(score, 1)),
    }


def eval_code(response: str) -> dict:
    """Strip fences, execute Python, return pass/fail + output (0 or 10)."""
    code = re.sub(r"```python\n?", "", response)
    code = re.sub(r"```\n?", "", code).strip()
    with tempfile.NamedTemporaryFile(
        mode="w", suffix=".py", delete=False, encoding="utf-8"
    ) as f:
        f.write(code)
        tmp = f.name
    try:
        result = subprocess.run(
            ["python3", tmp], capture_output=True, text=True, timeout=15,
        )
        success = result.returncode == 0
        output = (result.stdout + result.stderr).strip()[:600]
        return {"runs": success, "output": output, "score": 10 if success else 0}
    except subprocess.TimeoutExpired:
        return {"runs": False, "output": "execution timeout (15s)", "score": 0}
    except Exception as exc:
        return {"runs": False, "output": str(exc), "score": 0}
    finally:
        os.unlink(tmp)


def score_text(response: str) -> dict:
    """
    Heuristic scoring for reasoning/text tasks (0-10).
    Edit the keyword lists and scoring logic for different prompts.
    """
    text = response.lower()
    score = 0
    # Has 3 numbered causes
    n_numbered = len(re.findall(r"(?:^|\n)\s*[123]\.", text))
    score += 3 if n_numbered >= 3 else (1 if n_numbered >= 2 else 0)
    # References time-based scheduled work
    for kw in ("cron", "scheduled", "batch", "nightly", "vacuum", "autovacuum"):
        if kw in text:
            score += 1
            break
    # References connection/pool limits
    for kw in ("connection pool", "max_connections", "connection limit", "tcp"):
        if kw in text:
            score += 1
            break
    # Contains diagnostic commands (backtick-quoted, 5+ chars)
    cmd_hits = len(re.findall(r"`[^`]{5,}`", response))
    score += min(3, cmd_hits)
    # Penalise very short responses
    if len(response.split()) < 80:
        score -= 2
    return {"score": max(0, min(10, score)), "word_count": len(response.split())}


# ---------------------------------------------------------------------------
# Core runner
# ---------------------------------------------------------------------------


def run_task(host: str, model: str, task: dict, num_ctx: int = 8192) -> dict:
    unload_all(host)
    payload = {
        "model": model,
        "prompt": task["prompt"],
        "stream": False,
        "keep_alive": 0,
        "options": {"num_ctx": num_ctx},
    }
    t0 = time.time()
    try:
        resp = api(host, "/api/generate", payload)
    except Exception as exc:
        return {"error": str(exc)}
    elapsed = time.time() - t0

    response = resp.get("response", "")
    gen_tok = resp.get("eval_count", 0)
    gen_s = resp.get("eval_duration", 1) / 1e9
    prefill_tok = resp.get("prompt_eval_count", 0)
    prefill_s = resp.get("prompt_eval_duration", 1) / 1e9

    record = {
        "response": response,
        "load_s": resp.get("load_duration", 0) / 1e9,
        "prefill_tps": prefill_tok / prefill_s if prefill_s > 0 else 0,
        "gen_tps": gen_tok / gen_s if gen_s > 0 else 0,
        "gen_tok": gen_tok,
        "total_s": round(elapsed, 1),
    }

    if task["type"] == "kg":
        record["eval"] = eval_kg(response)
    elif task["type"] == "code":
        record["eval"] = eval_code(response)
    else:
        record["eval"] = score_text(response)

    return record


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main():
    parser = argparse.ArgumentParser(
        description="Evaluate Ollama model quality across structured tasks.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("--host", default="http://localhost:11434",
                        help="Ollama base URL (default: http://localhost:11434)")
    parser.add_argument("--models", nargs="*", metavar="MODEL",
                        help="Models to evaluate (default: all known models)")
    parser.add_argument("--tasks", nargs="*", metavar="TASK",
                        choices=list(TASKS.keys()),
                        help=f"Tasks to run (default: all). Choices: {list(TASKS.keys())}")
    parser.add_argument("--out", default=None,
                        help="Output directory for results JSON (default: ./results/)")
    parser.add_argument("--num-ctx", type=int, default=8192,
                        help="Context window cap during evaluation (default: 8192)")
    parser.add_argument("--list-tasks", action="store_true",
                        help="Print available tasks and exit")
    parser.add_argument("--list-models", action="store_true",
                        help="Print known models and exit")
    args = parser.parse_args()

    if args.list_tasks:
        for tid, t in TASKS.items():
            print(f"  {tid:<25} ({t['type']})  {t['name']}")
        return

    if args.list_models:
        for m in KNOWN_MODELS:
            print(f"  {m}")
        return

    # Resolve output directory
    script_dir = os.path.dirname(os.path.abspath(__file__))
    out_dir = args.out or os.path.join(script_dir, "results")
    os.makedirs(out_dir, exist_ok=True)
    today = date.today().isoformat()
    out_path = os.path.join(out_dir, f"{today}.json")

    # Check which models are available on the server
    try:
        tags = api(args.host, "/api/tags", method="GET")
        available = {m["name"] for m in tags.get("models", [])}
    except Exception as exc:
        print(f"Cannot reach Ollama at {args.host}: {exc}", file=sys.stderr)
        sys.exit(1)

    requested = args.models if args.models else KNOWN_MODELS
    models = [m for m in requested if m in available]
    missing = [m for m in requested if m not in available]
    if missing:
        print(f"SKIP (not pulled on server): {', '.join(missing)}")
    if not models:
        print("No models to evaluate.")
        sys.exit(1)

    task_ids = args.tasks if args.tasks else list(TASKS.keys())
    tasks_to_run = {tid: TASKS[tid] for tid in task_ids}

    print(f"\nOllama Model Evaluator  |  host={args.host}  num_ctx={args.num_ctx}")
    print(f"Models : {', '.join(models)}")
    print(f"Tasks  : {', '.join(task_ids)}")
    print(f"Output : {out_path}")

    results = {}

    for model in models:
        results[model] = {}
        print(f"\n{'='*65}")
        print(f"  {model}")
        print(f"{'='*65}")

        for task_id, task in tasks_to_run.items():
            print(f"  [{task['name']}] ... ", end="", flush=True)
            rec = run_task(args.host, model, task, num_ctx=args.num_ctx)
            results[model][task_id] = rec

            if "error" in rec:
                print(f"ERROR: {rec['error']}")
                continue

            ev = rec.get("eval", {})
            score = ev.get("score", "?")
            print(
                f"done  total={rec['total_s']}s  "
                f"gen={rec['gen_tps']:.1f}tok/s  score={score}/10"
            )
            if task["type"] == "kg":
                print(f"           nodes={ev.get('nodes')}  edges={ev.get('edges')}  "
                      f"schema_ok={ev.get('schema_ok')}")
            elif task["type"] == "code":
                out = ev.get("output", "")[:80]
                print(f"           runs={ev.get('runs')}  {out}")
            else:
                print(f"           words={ev.get('word_count')}")

    # Persist results
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(results, f, indent=2, ensure_ascii=False)
    print(f"\nSaved: {out_path}")

    # Summary table
    print("\n\n" + "=" * 80)
    task_labels = [TASKS[tid]["name"][:10] for tid in task_ids]
    header_tasks = "  ".join(f"{lbl:>10}" for lbl in task_labels)
    print(f"{'Model':<28}  {header_tasks}  {'Avg':>6}")
    print("-" * 80)
    for model, task_results in results.items():
        scores = []
        row_scores = []
        for tid in task_ids:
            rec = task_results.get(tid, {})
            s = rec.get("eval", {}).get("score") if "error" not in rec else None
            scores.append(s)
            row_scores.append(f"{s if s is not None else 'ERR':>10}")
        valid = [s for s in scores if s is not None]
        avg = f"{sum(valid)/len(valid):.1f}" if valid else "ERR"
        print(f"{model:<28}  {'  '.join(row_scores)}  {avg:>6}")
    print("=" * 80)
    print()


if __name__ == "__main__":
    main()
