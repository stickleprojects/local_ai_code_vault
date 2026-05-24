# Vault Improvements — Sequenced Copilot Prompts

**Date:** 2026-05-24
Companion to `SEARCH-IMPACT-ANALYSIS.md` (findings) and `EVAL-HARNESS-SPEC.md`
(the measurement foundation).

## How to use

Hand these to the GitHub Copilot coding agent **one PR at a time, in order**.
The ordering is deliberate:

1. **PR 1 — Eval harness** (foundation). Nothing downstream is verifiable without it. — ✅ **MERGED (#27).**
2. **PR 2 — Mechanical fixes** (low risk, self-verifying). — ✅ **MERGED (#28).**
3. **PR 3 — Symbol/exact mode** (new, bounded feature). — 🔄 **IN REVIEW (draft #29).**
4. **PR 4 — Symbol-aware ranking** (language-general; the risky one — explicitly last and explicitly measured). — ⏳ **NEXT.**
5. **PR 5+ — Per-language definition enrichment** (deferred follow-ups; one language at a time, each separately measured). — ⏳ **DEFERRED.**

> **Status (2026-05-24):** PR 1 and PR 2 are merged to `main`; PR 3 is an open
> draft (#29), not yet merged. PR 4 is the next delegated unit (now folds in the
> `indexer/languages/` reorg as its first commit). Note: the C# eval case
> `definition-above-callsite-csharp` and the `csharp/` corpus pair were added
> *after* #27 generated `baseline.json`, so the baseline must be regenerated
> (PR 4's `-UpdateBaseline`, run against the stack) to include them.

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

## PR 1 — Build the retrieval eval harness — ✅ MERGED (#27)

> **Task:** Implement the retrieval eval harness exactly as specified in
> `EVAL-HARNESS-SPEC.md`. Read that file first; it is the contract.
>
> **Already provided — DO NOT modify (human-owned source of truth):**
> - `eval/corpus/` — the deterministic fixture repo (Python files plus a C#
>   definition/call-site pair) reproducing the trivial-file,
>   definition-vs-call-site (in **two** languages), and conftest/fixture failure
>   modes **already exists**. Use it as-is.
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

## PR 2 — Mechanical result-quality fixes — ✅ MERGED (#28)

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

## PR 3 — Symbol / exact-match search mode — 🔄 IN REVIEW (draft #29)

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

## PR 4 — Symbol-aware ranking (language-general) — HIGHEST value, HIGHEST risk, do last — ⏳ NEXT

Addresses the **language-general** half of analysis recommendation **HIGH — fix
definition under-ranking**. The per-language doc/fixture enrichment is split out
into PR 5+ (below) so this PR stays small and verifiable across **all four**
supported languages, not just Python.

> **Task:** Make the *defining* site of a symbol outrank chunks that merely use
> it, for **every supported language** (Python, C#, JavaScript, TypeScript) — not
> a Python-only special case. Do it in three steps, the first a behaviour-neutral
> refactor committed on its own:
>
> 1. **Refactor: extract per-language logic into `indexer/languages/` (NO
>    behaviour change — separate first commit).** Today all per-language logic is
>    centralised in `indexer/chunker.py` as parallel dicts keyed by language
>    (`_EXT_LANG`, `_FUNC_TYPES`, `_CONTAINER_TYPES`, the grammar map). That shape
>    fits declarative facts but not the per-language *behaviour* this PR (and PR
>    5+) adds. Move it to one module per language behind a `LanguageSpec`
>    (grammar + func/container node types; `symbol_name(node)` and later
>    `doc_comment(node)`), with a registry in `languages/__init__.py`. `chunker.py`
>    keeps `chunk_source()` / `language_for()` as its public API and becomes a
>    language-agnostic walker. Existing `tests/test_chunker.py` must pass
>    **unchanged** — that is the proof the move is behaviour-neutral. Respect the
>    layering rule (`src/` must not import from `indexer/`).
> 2. **Index the defining symbol name per chunk.** Give each `LanguageSpec` a
>    `symbol_name(node)` that returns the declaration's identifier (the chunker
>    already locates function/method/class/container nodes for all four
>    languages). Store it on the chunk payload (e.g. `symbol`); whole-file
>    fallback chunks store none.
> 3. **Boost definitions of query-matched symbols.** When a query token matches a
>    chunk's stored `symbol`, boost that chunk above chunks that only reference
>    the identifier in their body. Keep the boost a named, tunable constant.
>
> Do **not** special-case any one language's idioms (no pytest-fixture handling,
> no docstring/JSDoc/XML-doc parsing) — that is PR 5+. This PR is purely
> name-match → definition-boost, which generalizes.
>
> **This change is unverifiable without the eval.** You MUST:
> - Commit step 1 (the `languages/` refactor) first, with `tests/test_chunker.py`
>   passing **unchanged** and no eval-metric movement — proof it is behaviour-
>   neutral before any ranking change rides on top.
> - Re-index the corpus after the change (ranking depends on the index).
> - Run `eval/run-eval.ps1` and paste **before vs after** per-case ranks and
>   aggregate Recall@k / MRR / DefinitionRank.
> - Both `definition-above-callsite` (Python) **and**
>   `definition-above-callsite-csharp` must flip from fail → pass — the C# case is
>   the proof the boost is language-general, not Python-only. No other `must_pass`
>   case may regress; aggregate MRR must not drop below baseline. (The NL
>   `definition-fixture` / `fixture-discovery-natural` cases are **not** expected
>   to flip here — they need PR 5's doc enrichment.)
> - If you cannot demonstrate the eval improvement, the PR is not done — green CI
>   alone does NOT prove this change worked.
>
> **Scope:** `indexer/languages/` extraction (behaviour-neutral, first commit) +
> per-chunk symbol extraction + query-side boosting + re-baseline
> (`-UpdateBaseline` in a separate, human-reviewed commit). Respect the layering
> rule (`src/` must not import from `indexer/`). Coordinate the baseline bump with
> the maintainer. Do **not** touch per-language doc parsing or chunk granularity.
>
> [+ Standing requirements block]

---

## PR 5+ — Per-language definition enrichment (deferred follow-ups, one language at a time) — ⏳ DEFERRED

Addresses the *other* half of **HIGH — fix definition/fixture under-ranking**:
natural-language "how do I set up X" / "where is X defined" queries that name a
*concept*, not an exact symbol, so PR 4's name-match boost can't help them.
Fixing those means embedding definitions on more than their raw body — and the
"more" is language-specific, so it ships **per language**, each gated by its own
eval cases.

> **Task (one language per PR):** Enrich definition chunks so a concept query
> lands on the defining site. Augment/re-key the embedding of a definition chunk
> with its `name + signature + leading doc-comment` rather than raw body alone.
> The doc-comment extraction is per language:
> - **Python:** docstring (first string literal in the body) + pytest-fixture
>   recognition (`@pytest.fixture`-decorated defs as first-class definition
>   units). Target cases: `definition-fixture`, `fixture-discovery-natural`.
> - **C#:** `///` XML-doc comments preceding the declaration.
> - **JS/TS:** JSDoc `/** ... */` blocks preceding the declaration.
>
> Each language PR adds its own corpus fixtures + labelled eval cases (human
> reviewed) before flipping them to `must_pass`. Do not generalize one language's
> doc format to another.
>
> **Verify:** the language's NL definition cases flip fail → pass; no regression
> in `definition-above-callsite*` or any anchor. Run the eval; paste before/after.
>
> **Scope:** indexer chunk enrichment for the one language + its corpus/eval
> cases + re-baseline. Build on PR 4's `languages/` package and `symbol` payload —
> add `doc_comment(node)` to that language's `LanguageSpec`; don't change the boost.
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
