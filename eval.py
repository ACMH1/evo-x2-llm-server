#!/usr/bin/env python3
"""
Model quality evaluation across three task types:
  1. Knowledge graph extraction (structured output fidelity)
  2. Code generation (correctness via execution)
  3. Reasoning / diagnosis (analytical depth)

Outputs: /opt/eval_results.json  (full responses + metrics)
         /opt/eval_summary.txt   (human-readable table)
"""

import json
import os
import re
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

HOST = "http://localhost:11434"

MODELS = [
    "qwen2.5-coder:7b",
    "qwen2.5-coder:32b",
    "qwen3-coder:30b",
    "qwen3.5:35b-a3b",
    "deepseek-r1:70b",
    "llama4:scout",
]

# ---------------------------------------------------------------------------
# Task definitions
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
}

# ---------------------------------------------------------------------------
# HTTP helper
# ---------------------------------------------------------------------------

def api(host, path, payload=None, method="POST"):
    url = f"{host}{path}"
    data = json.dumps(payload).encode() if payload else None
    req = urllib.request.Request(
        url, data=data,
        headers={"Content-Type": "application/json"},
        method=method,
    )
    with urllib.request.urlopen(req, timeout=300) as r:
        return json.load(r)


def unload_all(host, timeout=120):
    """Evict all loaded models; poll /api/ps until confirmed empty."""
    try:
        resp = api(host, "/api/ps", method="GET")
        for m in resp.get("models", []):
            api(host, "/api/generate", {"model": m["name"], "prompt": " ", "keep_alive": 0})
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
# Task-specific evaluators
# ---------------------------------------------------------------------------

def eval_kg(response: str) -> dict:
    """Parse and score a KG JSON response."""
    text = re.sub(r"```[a-z]*\n?", "", response).strip()
    match = re.search(r"\{[\s\S]*\}", text)
    if not match:
        return {"valid": False, "error": "no JSON object found", "nodes": 0, "edges": 0,
                "score": 0}
    try:
        data = json.loads(match.group())
    except json.JSONDecodeError as exc:
        return {"valid": False, "error": str(exc), "nodes": 0, "edges": 0, "score": 0}

    nodes = data.get("nodes", [])
    edges = data.get("edges", [])
    has_required_keys_nodes = all(
        {"id", "label", "type"}.issubset(n.keys()) for n in nodes
    ) if nodes else False
    has_required_keys_edges = all(
        {"source", "target", "relation"}.issubset(e.keys()) for e in edges
    ) if edges else False

    # Score: 0-10
    score = 0
    if nodes:
        score += 2
    if edges:
        score += 2
    if has_required_keys_nodes:
        score += 2
    if has_required_keys_edges:
        score += 2
    # Bonus: captures key entities (Torvalds, Stallman, Poettering)
    node_labels = " ".join(str(n.get("label", "")) for n in nodes).lower()
    for name in ("torvalds", "stallman", "poettering", "systemd", "gnu"):
        if name in node_labels:
            score += 0.4
    score = min(10, round(score, 1))

    return {
        "valid": True,
        "nodes": len(nodes),
        "edges": len(edges),
        "schema_ok": has_required_keys_nodes and has_required_keys_edges,
        "score": score,
    }


def eval_code(response: str) -> dict:
    """Extract Python code and execute it; return pass/fail + output."""
    code = re.sub(r"```python\n?", "", response)
    code = re.sub(r"```\n?", "", code).strip()
    with tempfile.NamedTemporaryFile(
        mode="w", suffix=".py", delete=False, encoding="utf-8"
    ) as f:
        f.write(code)
        tmp = f.name
    try:
        result = subprocess.run(
            ["python3", tmp], capture_output=True, text=True, timeout=15
        )
        success = result.returncode == 0
        output = (result.stdout + result.stderr).strip()[:600]
        return {"runs": success, "output": output, "score": 10 if success else 0}
    except subprocess.TimeoutExpired:
        return {"runs": False, "output": "timeout", "score": 0}
    except Exception as exc:
        return {"runs": False, "output": str(exc), "score": 0}
    finally:
        os.unlink(tmp)


def score_reasoning(response: str) -> dict:
    """Heuristic scoring for reasoning response quality."""
    text = response.lower()
    score = 0
    # Has 3 distinct causes
    n_numbered = len(re.findall(r"(?:^|\n)\s*[123]\.", text))
    if n_numbered >= 3:
        score += 3
    elif n_numbered >= 2:
        score += 1
    # References time-based patterns
    for kw in ("cron", "scheduled", "batch", "nightly", "vacuum", "autovacuum"):
        if kw in text:
            score += 1
            break
    # References network/infra causes
    for kw in ("connection pool", "connection limit", "max_connections", "tcp", "timeout"):
        if kw in text:
            score += 1
            break
    # Includes specific diagnostic commands
    cmd_hits = len(re.findall(r"`[^`]{5,}`", response))
    score += min(3, cmd_hits)
    # Conciseness penalty for very short responses
    if len(response.split()) < 80:
        score -= 2
    return {"score": max(0, min(10, score)), "word_count": len(response.split())}


# ---------------------------------------------------------------------------
# Core runner
# ---------------------------------------------------------------------------

def run_task(model: str, task_id: str, task: dict) -> dict:
    unload_all(HOST)
    payload = {
        "model": model,
        "prompt": task["prompt"],
        "stream": False,
        "keep_alive": 0,
        "options": {"num_ctx": 8192},
    }
    t0 = time.time()
    try:
        resp = api(HOST, "/api/generate", payload)
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
        "total_s": elapsed,
    }

    if task["type"] == "kg":
        record["eval"] = eval_kg(response)
    elif task["type"] == "code":
        record["eval"] = eval_code(response)
    else:
        record["eval"] = score_reasoning(response)

    return record


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    # Check which models are available
    try:
        tags = api(HOST, "/api/tags", method="GET")
        available = {m["name"] for m in tags.get("models", [])}
    except Exception as exc:
        print(f"Cannot reach Ollama: {exc}")
        return

    models = [m for m in MODELS if m in available]
    missing = [m for m in MODELS if m not in available]
    if missing:
        print(f"SKIP (not pulled): {', '.join(missing)}")

    results = {}

    for model in models:
        results[model] = {}
        print(f"\n{'='*65}")
        print(f"  {model}")
        print(f"{'='*65}")

        for task_id, task in TASKS.items():
            print(f"  [{task['name']}] ... ", end="", flush=True)
            rec = run_task(model, task_id, task)
            results[model][task_id] = rec

            if "error" in rec:
                print(f"ERROR: {rec['error']}")
                continue

            ev = rec.get("eval", {})
            score = ev.get("score", "?")
            print(
                f"done  total={rec['total_s']:.0f}s  "
                f"gen={rec['gen_tps']:.1f}tok/s  score={score}/10"
            )
            if task["type"] == "kg":
                print(
                    f"           nodes={ev.get('nodes')}  edges={ev.get('edges')}  "
                    f"schema_ok={ev.get('schema_ok')}"
                )
            elif task["type"] == "code":
                print(f"           runs={ev.get('runs')}  output={ev.get('output','')[:80]}")
            else:
                print(f"           words={ev.get('word_count')}")

    # Save full results
    with open("/opt/eval_results.json", "w", encoding="utf-8") as f:
        json.dump(results, f, indent=2, ensure_ascii=False)
    print("\n\nSaved: /opt/eval_results.json")

    # Print summary table
    print("\n\n" + "=" * 80)
    print(f"{'Model':<28} {'KG':>6} {'Code':>6} {'Reason':>8} {'Avg':>6}")
    print(f"{'':28} {'score':>6} {'score':>6} {'score':>8} {'score':>6}")
    print("-" * 80)
    for model, tasks in results.items():
        scores = []
        row = [f"{model:<28}"]
        for task_id in ("kg_extraction", "code_generation", "reasoning"):
            rec = tasks.get(task_id, {})
            s = rec.get("eval", {}).get("score", None) if "error" not in rec else None
            scores.append(s)
            row.append(f"{s if s is not None else 'ERR':>6}")
        valid = [s for s in scores if s is not None]
        avg = f"{sum(valid)/len(valid):.1f}" if valid else "ERR"
        row.append(f"{avg:>6}")
        print(" ".join(row))
    print("=" * 80)
    print()


if __name__ == "__main__":
    main()
