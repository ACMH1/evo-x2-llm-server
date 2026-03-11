# Sentiment Analysis Evaluation — 2026-03-12

**Articles:** 5 real 2025-2026 financial news snippets with misleading surface signals
**Scoring:** 2pts correct, 1pt partial (adjacent label), 0pts wrong/invalid

## Results

| Model | Score | Correct | Partial | Tripped on |
|---|:---:|:---:|:---:|---|
| Claude Sonnet 4.6 *(baseline)* | 10/10 | 5/5 | 0 | — |
| `llama4:scout` | **10/10** | 5/5 | 0 | — |
| `qwen2.5-coder:7b` | 9.0/10 | 4/5 | 1 | A3 Amazon → said **positive** |
| `qwen2.5-coder:32b` | 9.0/10 | 4/5 | 1 | A2 3M → said **mixed** |
| `qwen3-coder:30b` | 9.0/10 | 4/5 | 1 | A3 Amazon → said **negative** |
| `qwen3.5:35b-a3b` | 9.0/10 | 4/5 | 1 | A2 3M → said **mixed** |
| `deepseek-r1:70b` | ERR | — | — | HTTP 500 (OOM after qwen3.5) |

## Per-Article Breakdown

### A1 — Morgan Stanley: record revenue + 3% layoffs → `mixed`
All five models correct. Every model correctly identified that record top-line results and simultaneous workforce cuts produce mixed sentiment. The "record revenue" headline was not enough to override the layoff signal.

### A2 — 3M: revenue beat + 5.5pt margin collapse → `negative`
**Split result.** qwen2.5-coder:32b and qwen3.5:35b-a3b called this **mixed** — they correctly noted both the revenue beat and margin collapse but hedged instead of committing. The correct read is **negative**: a beat achieved through unsustainable discounting in "soft" markets is structurally deteriorating. qwen2.5-coder:7b, qwen3-coder:30b, and llama4:scout got this right, weighting the margin collapse over the surface beat.

### A3 — Amazon: earnings beat + capex guidance shock → `mixed`
**Hardest article — models split in opposite directions.** qwen2.5-coder:7b anchored on the earnings beat and said **positive**, ignoring the 8% after-hours drop. qwen3-coder:30b overcorrected and said **negative**, over-weighting the capex shock. Only qwen2.5-coder:32b, qwen3.5:35b-a3b, and llama4:scout held both signals simultaneously and reached the correct **mixed** label.

### A4 — Tesla: 46% profit decline, "beat expectations" → `negative`
All five models correct. Every model correctly dismissed the "beat expectations" framing in favour of the magnitude of decline (46% YoY profit drop) and loss of global EV market leadership to BYD. The beat-vs-decline ambiguity did not fool any model.

### A5 — Fed CPI: 2.4% inflation, geopolitical caveat → `neutral`
All five models correct. Every model correctly identified that steady-near-target inflation is neutral, and that the economist's "any other day" caveat signals uncertainty rather than negativity. The hedged framing was well-handled across the board.

## Key Findings

**llama4:scout is the surprise winner** despite scoring worst in the reasoning task (6/10). Large-context models may be better at holding multiple competing signals in a single pass without anchoring on the first strong cue. Its per-article reasoning was accurate and concise across all five articles.

**A3 (Amazon) is the best discriminating article** — it produced opposite errors from different models (one said positive, one said negative) because the two signals (strong current earnings vs future capex shock) genuinely pull in opposite directions. This is exactly the kind of nuance that separates strong NLU from surface-level keyword matching.

**A2 (3M) reveals a hedging bias in larger dense models** — both qwen2.5-coder:32b and qwen3.5:35b-a3b chose "mixed" when the correct answer was "negative". These models appear to over-apply the "when in doubt, say mixed" heuristic. The 7B model and qwen3-coder:30b committed more decisively.

**deepseek-r1:70b OOM** — the 120s unload timeout is insufficient after qwen3.5:35b-a3b's long generation runs. The model's KV cache takes longer than 2 minutes to fully release from system RAM. Workaround: increase `unload_all()` timeout to 240s, or ensure deepseek runs earlier in the model order before heavy MoE models.

## Article Ground Truth Summary

| ID | Subject | Hard signal | Ground truth |
|---|---|---|---|
| A1 | Morgan Stanley | Record revenue masks layoffs | `mixed` |
| A2 | 3M | Revenue beat masks margin collapse | `negative` |
| A3 | Amazon | Earnings beat masked by capex shock | `mixed` |
| A4 | Tesla | "Beat expectations" vs 46% profit decline | `negative` |
| A5 | Fed CPI | Good data framed as insufficient by economists | `neutral` |
