# Vault Retrieval Eval Harness — Spec

**Date:** 2026-05-24
**Purpose:** Make "did retrieval get better/worse?" a falsifiable, gated test.
Companion to `SEARCH-IMPACT-ANALYSIS.md` (the recommendations) and
`COPILOT-PROMPTS.md` (the delegated work). **This harness is PR 1 — everything
else gates on it.**

The core problem this solves: retrieval-quality changes (chunking, ranking,
boosting) cannot be verified by ordinary unit tests or green CI. A diff can look
right, CI can pass, and ranking can still be wrong or worse. The harness turns
ranking into numbers with a committed baseline and regression gating.

---

## 1. What it is

An **integration eval**: it indexes a small committed corpus into a *running*
vault stack, runs a fixed set of labelled queries through `query-smart.ps1`, and
scores the results against expectations and a committed baseline.

It is NOT a unit test — it requires the stack (`docker compose up`: API + Qdrant
+ embedding model). The runner MUST health-check first (`vault-health.ps1`) and
fail with a clear "stack down" message rather than a misleading score of 0.

---

## 2. Layout

```
eval/
  corpus/              # small, committed, deterministic fixture repo (its own git or a plain dir)
  queries.yaml         # labelled cases (the human-owned source of truth)
  run-eval.ps1         # the runner
  baseline.json        # committed current scores; regression gate compares against this
  README.md            # how to run + how to re-baseline
```

The **corpus** is deterministic and version-controlled so scores are
reproducible across machines and over time. Do **not** eval against a live
external repo (it drifts and isn't portable).

---

## 3. Corpus (minimum — encodes the observed failure modes)

The corpus must reproduce every failure mode in the analysis, so a fix is
measurable. Minimum files:

```
corpus/
  pkg/__init__.py            # 1–2 lines only          -> TRIVIAL-FILE NOISE probe
  pkg/fixtures.py            # defines make_session() with a clear docstring   -> DEFINITION target
  pkg/service.py             # defines class OrderService with method publish() -> SYMBOL/DEFINITION target
  tests/conftest.py          # defines a `db_session`-style fixture (savepoint pattern) -> CONFTEST under-ranking probe
  tests/test_service.py      # imports + uses OrderService and make_session() heavily -> CALL SITES that currently out-rank definitions
```

This is enough to test: trivial-file filtering, definition-above-call-site
ranking, conftest/fixture discovery, and (later) exact-symbol completeness.
Add more files as new failure modes are found.

---

## 4. `queries.yaml` schema

Each case is one query with its expectations. `must_pass: true` cases hard-gate
the runner (exit non-zero on failure); others contribute to aggregate metrics
only.

```yaml
- id: definition-fixture
  query: "session fixture setup savepoint"
  k: 5
  mode: semantic            # semantic | symbol
  expect_in_top_k:          # at least one of these must appear in top-k (drives Recall@k / MRR)
    - "tests/conftest.py"
    - "pkg/fixtures.py"
  forbid_in_top_k:          # glob(s) that must NOT appear in top-k (noise guard)
    - "**/__init__.py"
  must_pass: true
  tags: [definition, fixture, noise]

- id: definition-above-callsite
  query: "OrderService publish an order"
  k: 5
  mode: semantic
  expect_rank_above:        # file A must rank strictly above file B
    above: "pkg/service.py"
    below: "tests/test_service.py"
  must_pass: true
  tags: [definition, ranking]

- id: symbol-completeness
  query: "OrderService"
  k: 10
  mode: symbol              # exercises the new exact/lexical mode (PR 3)
  expect_all:               # ALL of these must be returned (completeness, not ranking)
    - "pkg/service.py"
    - "tests/test_service.py"
  must_pass: true
  tags: [symbol, completeness]

- id: semantic-anchor        # already works today; non-regression sentinel
  query: "publish order workflow service"
  k: 5
  mode: semantic
  expect_in_top_k:
    - "pkg/service.py"
  must_pass: true
  tags: [anchor]
```

Seed it with the two real cases from the analysis (translated to corpus paths):
the `conftest`/`db_session` discovery (currently fails — `__init__.py` out-ranks
the fixture) and a strong semantic case (currently passes — anchor).

---

## 5. Metrics

Computed per case and aggregated across cases (and per `tag`):

| Metric | Definition | Direction |
|---|---|---|
| **Recall@k** | 1 if any `expect_in_top_k` file appears in top-k, else 0 | higher better |
| **MRR** | 1 / (rank of first `expect_in_top_k` hit); 0 if none in top-k | higher better |
| **Noise@k** | fraction of top-k matching any `forbid_in_top_k` glob | lower better |
| **DefinitionRank** | pass/fail: `above` file index < `below` file index | pass |
| **SymbolCompleteness** | fraction of `expect_all` present in results (mode=symbol) | =1.0 to pass |

Overlapping/duplicate chunks **from the same file** count once for ranking
purposes (so the dedup fix in PR 2 doesn't game Recall).

---

## 6. Runner contract (`run-eval.ps1`)

Inputs: `-CorpusPath`, `-QueriesPath`, optional `-Baseline baseline.json`,
optional `-UpdateBaseline`, optional `-Tolerance 0.0`.

Steps:
1. `vault-health.ps1` — if stack down, exit code `4` with the standard guidance.
2. Index the corpus (`index-repo.ps1 <corpus> -Wait`) so the run is hermetic.
3. For each case: run `query-smart.ps1 "<query>" <corpus> -Limit <k> -DoNotIndex`
   (use the symbol mode flag for `mode: symbol`). Parse `results[]`.
4. Compute per-case pass/fail + metrics; aggregate overall and per tag.
5. Output **one JSON object** on stdout (consistent with the other scripts):
   `{ ok, code, cases:[{id, passed, metrics...}], aggregate:{recall_at_k, mrr,
   noise_at_k, ...}, regressions:[...] }` plus a human-readable table to stderr.
6. **Gating:** exit non-zero if any `must_pass` case fails, OR if any aggregate
   metric regresses beyond `-Tolerance` vs `baseline.json`. `-UpdateBaseline`
   rewrites `baseline.json` from the current run (human-reviewed commit).

Determinism: same corpus + same vault version ⇒ same scores. If the embedding
model is nondeterministic at the margin, compare with a small tolerance and round
scores in `baseline.json`.

---

## 7. Why this is the human-owned part

The **labels in `queries.yaml` define "correct."** An agent can build the runner
and corpus to this spec, but the expected files / forbidden globs / rank
assertions encode product judgment and should be authored or reviewed by a human
(you, or me with you). Treat `queries.yaml` and `baseline.json` as
human-approved; treat `run-eval.ps1` as agent-buildable.

---

## 8. Acceptance for PR 1

- `eval/` exists with corpus, `queries.yaml` (≥4 seed cases incl. the two from
  the analysis), `run-eval.ps1`, `baseline.json`, `README.md`.
- Runner health-checks, indexes the corpus, scores all cases, emits JSON + table,
  and gates on `must_pass` + baseline regression.
- Against **today's** vault: the `definition-fixture` and
  `definition-above-callsite` cases are expected to **fail** (that's the point —
  they document the current defects); the `semantic-anchor` case passes.
  `baseline.json` records these current scores honestly.
- README documents: prerequisites (stack up), how to run, how to re-baseline,
  and that failing definition cases are known-current-defects to be fixed by
  later PRs.
