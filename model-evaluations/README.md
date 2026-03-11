# Model Evaluations

Quality evaluation framework for the EVO-X2 Ollama model portfolio.

## Quick start

```bash
# On the server (or locally if Ollama is reachable)
python3 eval.py

# From a LAN client
python3 eval.py --host http://192.168.51.209:11434

# Evaluate specific models only
python3 eval.py --models qwen3-coder:30b llama4:scout

# Run specific tasks only
python3 eval.py --tasks kg_extraction reasoning

# Evaluate a model not in the built-in list (e.g. after pulling a new one)
python3 eval.py --models mistral:7b-instruct phi4:14b
```

Results are saved to `results/YYYY-MM-DD.json`. Human-readable reports go in `reports/`.

## Folder layout

```
model-evaluations/
├── eval.py              # Evaluation script (all tasks + scoring logic)
├── README.md            # This file
├── results/             # Raw JSON output — one file per eval run
│   └── 2026-03-12.json
└── reports/             # Written analysis of each run
    └── 2026-03-12-baseline.md
```

## Tasks

| ID | Name | Type | What it tests |
|---|---|---|---|
| `kg_extraction` | Knowledge Graph Extraction | `kg` | Structured JSON output fidelity, entity coverage, schema compliance |
| `code_generation` | Code Generation & Correctness | `code` | Code correctness (assertions executed), instruction following |
| `reasoning` | Reasoning / System Diagnosis | `text` | Analytical depth, specificity, avoiding confusing symptoms for causes |
| `sentiment_analysis` | Sentiment Analysis | `sentiment` | Label accuracy vs ground truth across 5 news articles (positive/negative/neutral/mixed) |

List all tasks: `python3 eval.py --list-tasks`

## Adding a new task

Edit `eval.py` and append to the `TASKS` dict:

```python
TASKS = {
    # ... existing tasks ...

    "your_task_id": {
        "name": "Human-readable task name",
        "type": "text",          # "kg" | "code" | "text" | "sentiment"
        "prompt": "Your prompt here.",
    },
}
```

- `type: "kg"` — expects JSON with `nodes` + `edges`; auto-scored by `eval_kg()`
- `type: "code"` — expects runnable Python; auto-scored by executing it via `eval_code()`
- `type: "text"` — heuristic keyword scoring via `score_text()`; edit the keyword lists in that function to match your new task's expected content
- `type: "sentiment"` — accuracy scored against a `ground_truth` dict you provide; add `"ground_truth": {"A1": "positive", "A2": "negative", ...}` alongside the task and list the articles in the prompt

For a new sentiment-style task with different articles, copy the `SENTIMENT_ARTICLES` block in `eval.py`, define your own articles + labels, and point the task at that ground truth dict.

## Adding a new model

No config change needed — just pass the model name on the CLI:

```bash
python3 eval.py --models phi4:14b
```

To add it to the default list so it runs automatically, add it to `KNOWN_MODELS` in `eval.py`.

## Scoring

**KG (0-10):**
- 2 pts — nodes list present
- 2 pts — edges list present
- 2 pts — node schema valid (`id`, `label`, `type`)
- 2 pts — edge schema valid (`source`, `target`, `relation`)
- up to 2 pts — key entities captured (Torvalds, Stallman, Poettering, Systemd, GNU)

**Code (0 or 10):**
- 10 — code executes and all assertions pass
- 0 — syntax error, assertion failure, or execution timeout

**Text/Reasoning (0-10):**
- 3 pts — 3 numbered causes present
- 1 pt — time-related keywords (cron, batch, vacuum, autovacuum, scheduled, nightly)
- 1 pt — connection/pool keywords (max_connections, connection pool, tcp)
- up to 3 pts — diagnostic commands present (backtick-quoted, 5+ chars)
- −2 pts — response under 80 words

Edit `score_text()` in `eval.py` to tune scoring for different prompt types.

**Sentiment (0-10):**
- 2 pts per article with correct label (5 articles × 2 = 10 max)
- 1 pt partial credit for adjacent labels: `positive`↔`mixed`, `negative`↔`mixed`
- 0 pts for wrong label, invalid label, missing article, or unparseable JSON
- Articles (real 2025-2026 news, chosen for misleading surface signals):
  - A1 Morgan Stanley: record revenue + simultaneous layoffs → `mixed`
  - A2 3M: revenue beat headline masks 5.5pt margin collapse → `negative`
  - A3 Amazon: earnings beat undermined by capex guidance shock → `mixed`
  - A4 Tesla: "beat expectations" noise vs 46% profit decline + lost EV crown → `negative`
  - A5 Fed CPI: inflation near target but framed as insufficient by economists → `neutral`

## CLI reference

```
python3 eval.py [options]

  --host HOST        Ollama base URL (default: http://localhost:11434)
  --models M [M...]  Models to evaluate (default: all KNOWN_MODELS)
  --tasks T [T...]   Tasks to run (default: all)
  --out DIR          Output directory for results JSON (default: ./results/)
  --num-ctx N        Context window cap (default: 8192 — keeps KV cache small)
  --list-tasks       Print available tasks and exit
  --list-models      Print known models and exit
```

## Baseline results (2026-03-12)

See [`reports/2026-03-12-baseline.md`](reports/2026-03-12-baseline.md) for the full analysis.

| Model | KG | Code | Reasoning | Avg |
|---|:---:|:---:|:---:|:---:|
| Claude Sonnet 4.6 *(baseline)* | 10 | 10 | 10 | **10.0** |
| `qwen3.5:35b-a3b` | 10 | 10 | 8 | **9.3** |
| `qwen2.5-coder:7b` | 10 | 10 | 7 | **9.0** |
| `deepseek-r1:70b` | 10 | ERR | 8 | **9.0** |
| `llama4:scout` | 10 | 10 | 6 | **8.7** |
| `qwen3-coder:30b` | 10 | 10 | 5 | **8.3** |
| `qwen2.5-coder:32b` | 10 | 10 | 4 | **8.0** |
