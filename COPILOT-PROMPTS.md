# Vault Improvements — Sequenced Copilot Prompts

**Date:** 2026-05-24
Companion to `SEARCH-IMPACT-ANALYSIS.md` (findings) and `EVAL-HARNESS-SPEC.md`
(the measurement foundation).

## How to use

Hand these to the GitHub Copilot coding agent **one PR at a time, in order**.
The ordering is deliberate:

1. **PR 1 — Eval harness** (foundation). Nothing downstream is verifiable without it.
2. **PR 2 — Mechanical fixes** (low risk, self-verifying).
3. **PR 3 — Symbol/exact mode** (new, bounded feature).
4. **PR 4 — Retrieval ranking** (the risky one — explicitly last and explicitly measured).

The **savings-metric** recommendation is **not** delegated — it's a product
decision (what baseline is "right"). Decide the formula first, then optionally
hand it off as a tiny follow-up (template at the bottom).

Before authoring `queries.yaml` / `baseline.json` in PR 1, a human reviews the
labels — those encode "correct" (see EVAL-HARNESS-SPEC §7).

---

## Standing requirements (paste into EVERY prompt)

> **Definition of done — do not declare complete until ALL hold:**
> 1. CI is green. Run `gh pr checks <PR>` and confirm every check passes; if any
>    fail, fix the root cause and re-check. Do not declare done on red or pending CI.
> 2. The eval harness (`eval/run-eval.ps1`) runs and you have pasted its
>    **before vs after** aggregate numbers into the PR description. (PR 1 builds
>    the harness; PRs 2–4 must run it.)
> 3. No regression: no `must_pass` eval case flips from pass→fail, and no
>    aggregate metric drops below `baseline.json` beyond tolerance.
> 4. Stay within the stated scope. Do not modify files outside it.
> 5. The vault stack must be up to run the eval (`docker compose up -d`;
>    `vault-health.ps1` should report `reachable:true`). If you cannot run the
>    stack in the CI sandbox, say so explicitly and run the eval locally,
>    pasting the output — do not silently skip it.

---

## PR 1 — Build the retrieval eval harness

> **Task:** Implement the retrieval eval harness exactly as specified in
> `EVAL-HARNESS-SPEC.md`. Read that file first; it is the contract.
>
> **Already provided — DO NOT modify (human-owned source of truth):**
> - `eval/corpus/` — the deterministic fixture repo (the five files that
>   reproduce the trivial-file, definition-vs-call-site, and conftest/fixture
>   failure modes) **already exists**. Use it as-is.
> - `eval/queries.yaml` — the labelled cases **already exist** and have been
>   reviewed by the maintainer. They define "correct." Do **not** rewrite,
>   relabel, or add/remove cases. If you believe a label is wrong, raise it in
>   the PR for human decision — do not change it yourself.
>
> **Deliverables (build only these):**
> - `run-eval.ps1` — the runner per spec §6: health-check → index `eval/corpus/` →
>   run each query via `query-smart.ps1` → compute metrics (spec §5) → emit one
>   JSON object on stdout + a human table on stderr → gate on `must_pass` +
>   baseline regression. Support `-UpdateBaseline` and `-Tolerance`.
> - `baseline.json` — generated from a run against the **current** vault, recorded
>   honestly. Expect `definition-fixture` and `definition-above-callsite` to FAIL
>   today — that is correct; they document the defects PR 2/PR 4 will fix.
> - `eval/README.md` — prerequisites, how to run, how to re-baseline, and a note
>   that the failing definition cases are known-current-defects.
>
> **Scope:** add `eval/run-eval.ps1`, `eval/baseline.json`, `eval/README.md`
> only. Do **not** modify `eval/corpus/` or `eval/queries.yaml` (provided), and do
> not change indexer, ranking, or `query-smart.ps1` behaviour in this PR — only
> *measure* it.
>
> **Acceptance:** spec §8. The runner must exit non-zero today (because the
> known-defect cases fail) OR mark them as `expected_fail` in the baseline —
> choose one and document it so CI is meaningful, not red-by-default.
>
> [+ Standing requirements block]

---

## PR 2 — Mechanical result-quality fixes

Addresses analysis recommendations: **MEDIUM — filter trivial/overlapping
chunks**, and **MEDIUM — surface staleness**.

> **Task:** Three independent, low-risk fixes to result quality and search output.
>
> 1. **Trivial-file filter.** Exclude or heavily down-weight near-empty files
>    (e.g. ≤2 non-blank lines, such as marker `__init__.py`) from search results.
>    Make the threshold a named constant. The `definition-fixture` eval case must
>    stop returning `__init__.py` in its top-k (Noise@k → 0).
> 2. **Overlapping-chunk dedup.** When two returned chunks are from the same file
>    and one line range contains the other (or they overlap >50%), merge/collapse
>    to one so the `-Limit` budget buys distinct hits. (Observed: one file took 2
>    of 6 slots with nested ranges.)
> 3. **Staleness in search output.** Add `index_stale: bool` and
>    `changed_files_not_indexed: [...]` to the `query-smart.ps1` JSON so callers
>    know results may miss recent edits. Do not change default index behaviour.
>
> **Verify:** add/extend unit tests for each. Then run `eval/run-eval.ps1` and
> paste before/after — Noise@k must improve and no other metric may regress.
>
> **Scope:** result post-processing + `query-smart.ps1` output shape + tests.
> Do not touch the embedding/chunking pipeline (that's PR 4).
>
> [+ Standing requirements block]

---

## PR 3 — Symbol / exact-match search mode

Addresses analysis recommendation: **HIGH — add a lexical/symbol exact mode;
document vault as discovery-not-completeness**.

> **Task:** Add an exact-identifier search mode so the vault can answer
> completeness questions ("where is `Foo` defined/referenced?") that semantic
> ranking cannot.
>
> - Add a `-Symbol <identifier>` switch (or a `mode=symbol` path) to
>   `query-smart.ps1` that returns **all** files/chunks containing the exact
>   identifier — grep/lexical-backed, not ranked-approximate. Completeness over
>   ranking.
> - Output stays the same JSON contract; include a `mode` field in the response.
> - Update the skill/README to state plainly: *semantic search = fuzzy discovery;
>   for "does this symbol exist anywhere" use `-Symbol` / grep.*
>
> **Verify:** the `symbol-completeness` eval case must pass (all `expect_all`
> files returned). Add unit tests for exact-match behaviour (case sensitivity,
> partial-token non-matches). Run the eval; paste results; no regression.
>
> **Scope:** new mode in `query-smart.ps1` + docs + tests. No ranking changes to
> the semantic path.
>
> [+ Standing requirements block]

---

## PR 4 — Definition-aware ranking (HIGHEST value, HIGHEST risk — do last)

Addresses analysis recommendation: **HIGH — fix definition/fixture under-ranking**.

> **Task:** Improve ranking so that when a query seeks a definition/fixture, the
> *defining* site outranks call sites and trivial files. Two complementary
> changes:
>
> 1. **Definition-aware chunking.** Chunk top-level `def`/`class` and pytest
>    fixtures as first-class units keyed on `name + signature + docstring`, so
>    "how do I set up X" / "where is X defined" embeddings land on the definition.
> 2. **Symbol-aware boosting.** When query tokens match an indexed symbol name,
>    boost chunks that *define* that symbol over chunks that merely use it.
>
> **This change is unverifiable without the eval.** You MUST:
> - Re-index the corpus after the change (ranking depends on the index).
> - Run `eval/run-eval.ps1` and paste **before vs after** per-case ranks and
>   aggregate Recall@k / MRR / DefinitionRank.
> - The `definition-fixture` and `definition-above-callsite` cases must flip from
>   fail → pass. No other `must_pass` case may regress; aggregate MRR must not
>   drop below baseline.
> - If you cannot demonstrate the eval improvement, the PR is not done — green CI
>   alone does NOT prove this change worked.
>
> **Scope:** indexer chunking + ranking/boosting + re-baseline (`-UpdateBaseline`
> in a separate, human-reviewed commit). Coordinate the baseline bump with the
> maintainer.
>
> [+ Standing requirements block]

---

## Not delegated — Savings metric (decide formula first)

Analysis recommendation **MEDIUM — make the savings metric defensible** is a
product decision, not a coding task. The current figure is an upper bound
(baseline = full source of every returned file) that overstates value. Decide
*the formula* — e.g. baseline = rank-weighted returned-chunk neighbourhoods a
developer would realistically open, minus tool/JSON overhead, with a note on
prompt-caching erosion. Once decided, hand off:

> **Task (after formula is fixed):** In `query-smart.ps1` / `vault-savings.ps1`,
> replace the upper-bound-only savings with `<the agreed formula>`. Keep the
> existing `*_upper` fields for continuity; add the new conservative fields and
> label the headline line as a ceiling. Update `vault-savings.ps1` ledger
> accordingly. Add unit tests pinning the new arithmetic.
> [+ Standing requirements block]
