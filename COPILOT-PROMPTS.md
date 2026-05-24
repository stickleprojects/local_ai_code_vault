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

**Separate track — Eval-in-CI (PR 6–7).** Independent of the risk-ordered quality
sequence above; either can land any time after PR 1. They make the retrieval eval
runnable in CI *without* the GPU box, so a change like PR 4 gets a real eval gate
instead of a hand-waved "couldn't run it in the sandbox" note. See the sections
near the bottom.

> **Status (2026-05-24):** PR 1 and PR 2 are merged to `main`; PR 3 is an open
> draft (#29), not yet merged. PR 4 is the next delegated unit (now folds in the
> `indexer/languages/` reorg as its first commit). Note: the C# eval case
> `definition-above-callsite-csharp` and the `csharp/` corpus pair were added
> *after* #27 generated `baseline.json`, so the baseline must be regenerated
> (PR 4's `-UpdateBaseline`, run against the stack) to include them.
>
> **Eval-gate dependency (added 2026-05-24):** PR 4 cannot be verified by the
> Copilot agent on its own — the sandbox has no GPU / no huggingface.co. Land
> **PR 6** (the GPU-free `eval-replay` job) first; then PR 4's fail → pass flip is
> provable in CI. The current open PR 4 (#31) predates this and only carries
> unit-test proof, so it needs the maintainer to either land PR 6 and re-verify, or
> run the live eval by hand before merge.

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
> 2. The eval harness (`eval/run-eval.ps1`) is exercised and you have pasted its
>    **before vs after** aggregate numbers into the PR description. (PR 1 builds
>    the harness; PRs 2–4 must run it.) The agent runs it via the GPU-free
>    `eval-replay` CI job (PR 6); see item 5 for what to do until that job exists.
> 3. No regression: no `must_pass` eval case flips from pass→fail, and no
>    aggregate metric drops below `baseline.json` beyond tolerance.
> 4. Stay within the stated scope. Do not modify files outside it.
> 5. The eval must be exercised — but the agent sandbox has **no GPU and no
>    huggingface.co access**, so it cannot bring up the live stack
>    (`docker compose up -d` will fail at `model-fetch`/`embedder`). The
>    GPU-free path is the `eval-replay` CI job (PR 6): run it and read its
>    result. If that job does not yet exist on your branch, say so explicitly
>    and leave the live eval to the maintainer — **do not** claim a live eval
>    you did not run, and **do not** silently skip. Reporting "I cannot run the
>    live stack here" is the honest, expected outcome, not a failure to hide.

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

## PR 4 — Symbol-aware ranking (language-general) — HIGHEST value, HIGHEST risk, do last — ⏳ NEXT (depends on PR 6 for its eval gate)

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
> **This change is unverifiable without the eval — and the agent sandbox cannot
> run the live stack (no GPU / no huggingface.co).** This PR therefore **depends
> on PR 6** (the GPU-free `eval-replay` job), which is how the agent runs the eval.
> PR 4 changes no embedding *inputs* (commit 1 is behaviour-neutral so chunk texts
> are unchanged; `symbol` lives in the payload; the boost is applied after
> retrieval), so PR 6's recorded `vectors.json` stays valid here — replay
> re-indexes and re-ranks against the same vectors and proves the flip
> deterministically. You MUST:
> - Commit step 1 (the `languages/` refactor) first, with `tests/test_chunker.py`
>   passing **unchanged** and no eval-metric movement — proof it is behaviour-
>   neutral before any ranking change rides on top.
> - Re-index the corpus after the change (ranking depends on the index) — the
>   `eval-replay` job does this each run.
> - The `eval-replay` job must run the eval; paste its **before vs after** per-case
>   ranks and aggregate Recall@k / MRR / DefinitionRank into the PR.
> - Both `definition-above-callsite` (Python) **and**
>   `definition-above-callsite-csharp` must flip from fail → pass — the C# case is
>   the proof the boost is language-general, not Python-only. No other `must_pass`
>   case may regress; aggregate MRR must not drop below baseline. (The NL
>   `definition-fixture` / `fixture-discovery-natural` cases are **not** expected
>   to flip here — they need PR 5's doc enrichment.)
> - The unit tests (`test_definition_boost_*`) are necessary but **not** sufficient:
>   green unit CI alone does NOT prove this change worked. The fail → pass flip must
>   be shown by the `eval-replay` job — or, if PR 6 is not yet merged, by a
>   maintainer live run (do not fabricate or skip it).
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

# Eval-in-CI track (PR 6–7) — run the eval without the GPU box

The retrieval eval can't run in CI today because the stack needs a GPU and a ~4 GB
GGUF — but **only the `embedder` service** needs them. `qdrant` and `api` are CPU
services, and both `api` (`EMBEDDER_URL`) and the indexer (`--embedder-url`) reach
the embedder by the service name **`embedder:8080`**. So each feature below ships as
a Docker Compose override of **just the `embedder` service**, leaving the rest of the
stack and `eval/run-eval.ps1` untouched.

The two are complementary, not alternatives — build **both**:

- **PR 6 (replay)** — deterministic, seconds, no model at all. The *per-PR required
  gate*. Catches ranking-logic regressions (exactly what PR 4 changes).
- **PR 7 (CPU nightly)** — the *real* model on CPU, slow, scheduled. The drift
  detector that catches embedder/model/index changes PR 6's frozen vectors can't.

## Should the Copilot agent build these?

Yes — both are bounded and CI-verifiable, which is what the agent does well. Two
caveats are baked into the prompts:

- **The agent's sandbox has no GPU and can't reach huggingface.co; GitHub-hosted
  Actions runners have neither limit** (full internet, ~16 GB RAM). So the real
  eval runs happen *on Actions*, not in the agent's sandbox — the agent verifies via
  the PR's workflow run, not a local run. The standing "stack must be up locally"
  DoD clause is therefore relaxed for both PRs.
- **PR 6's real vector fixture (`eval/vectors.json`) must be recorded once on the
  maintainer's GPU box** — the agent cannot produce it. Record it first and commit
  it to the PR branch, *then* hand off, so the agent can watch the `eval-replay`
  job go green. (The agent still builds the recorder script, the stub, the override,
  the workflow, and stub tests.)

---

## PR 6 — Replayable eval: recorded-vector embedder stub (per-PR gate) — ⏳ TODO

> **Task:** Make `eval/run-eval.ps1` runnable in CI with **no GPU and no model
> download**, deterministically, by replaying *recorded* embeddings — so the eval
> can become a required per-PR check. Build the machinery; the maintainer records
> the real vectors (see "Human step").
>
> 1. **Stub embedder** (`eval/embedder-stub/` — small Python service + Dockerfile).
>    Implements the OpenAI-compatible `POST /v1/embeddings` with the *same* response
>    shape llama.cpp returns (`{"data":[{"embedding":[...]}, ...], "model":...}`),
>    one vector per input in the batch. It loads a fixture and looks each input up by
>    `sha256(input_string)`. On any miss it returns HTTP 503 naming the missing hash
>    and telling the caller to regenerate the fixture — **never** a fabricated vector.
>    Vectors are full `EMBED_DIM` (3584) so the existing dim assertions in
>    `HttpEmbedder` / `HttpQueryEmbedder` pass.
> 2. **Recorder** (`eval/record-vectors.ps1`) — run by a human on a machine with the
>    real GPU stack up. Capture the *exact* strings sent to `/v1/embeddings` during
>    one real `eval/run-eval.ps1` run (run the recorder as a logging pass-through
>    proxy in front of the real `embedder`, so keys match the live path exactly —
>    code chunks via `format_code`, queries via `format_query`). Write
>    `eval/vectors.json`: `{model, dim, generated_at, corpus_sha, vectors:{<sha256>:[...]}}`.
> 3. **Compose override** (`docker-compose.replay.yml`) — override **only** the
>    `embedder` service to build/run the stub on port 8080; drop the `model-fetch`
>    dependency and the GPU `deploy` block. `qdrant`, `api`, and the indexer are
>    unchanged (they already address `embedder:8080`).
> 4. **CI job** `eval-replay` (ubuntu-latest): `docker compose -f docker-compose.yml
>    -f docker-compose.replay.yml up -d --wait`, build the indexer image (the eval's
>    index call does not pass `-Build`), then `pwsh -NoProfile -File eval/run-eval.ps1`,
>    failing on non-zero exit. Deterministic; runs in seconds.
>
> **Tests:** unit/integration test for the stub (hit returns the recorded vector;
> miss returns 503), using a tiny *synthetic* fixture under `tests/` — kept separate
> from the real `eval/vectors.json`.
>
> **Human step (not the agent):** record `eval/vectors.json` on the GPU box and
> commit it. Until it exists, keep `eval-replay` a normal (non-required) job. Once it
> is committed and the job is observed green, the maintainer flips it to a required
> branch-protection check — it becomes the real per-PR eval gate.
>
> **Verify:** with `eval/vectors.json` present, `eval-replay` passes and reproduces
> the same per-case pass/fail as a live run (it must, by construction). Confirm that a
> deliberately wrong-keyed fixture makes the stub 503 and the job fail loudly — no
> silent pass.
>
> **Scope:** `eval/embedder-stub/`, `eval/record-vectors.ps1`,
> `docker-compose.replay.yml`, the CI job, stub tests, README note. Do **not** modify
> `eval/corpus/`, `eval/queries.yaml`, the indexer, or the ranking path.
>
> **DoD override:** verification is the `eval-replay` CI job (plus the maintainer's
> recorder run) — the standing "run the eval locally in the sandbox" item does not
> apply (no GPU/HF in the agent sandbox).
>
> [+ Standing requirements block, minus item 5's "stack must be up locally" clause]

---

## PR 7 — Nightly full-fidelity eval: CPU embedder on GitHub-hosted runners — ⏳ TODO

> **Task:** Add a **nightly, full-fidelity** eval that runs the *real*
> `nomic-embed-code` model on **CPU** on a GitHub-hosted runner — a drift detector
> against the real embedder, complementing PR 6's deterministic per-PR gate. Not a
> required PR check (it's slow).
>
> 1. **Compose override** (`docker-compose.cpu.yml`) — override **only** the
>    `embedder` service: image → `ghcr.io/ggml-org/llama.cpp:server` (CPU build),
>    remove the `deploy.resources` GPU reservation, keep `--embeddings --pooling last`
>    and the `model-fetch` dependency. Everything else unchanged.
> 2. **Workflow** (`.github/workflows/eval-nightly.yml`): triggers `schedule:`
>    (nightly cron) + `workflow_dispatch`. On ubuntu-latest: cache the GGUF with
>    `actions/cache` keyed on `MODEL_SHA256` (model ~4.3 GB; runner ~16 GB RAM fits a
>    Q4_K_M 7B on CPU), `docker compose -f docker-compose.yml -f docker-compose.cpu.yml
>    up -d --wait`, build the indexer image, run `pwsh eval/run-eval.ps1`, upload the
>    eval JSON as an artifact, and surface failures (job red; optional summary).
>
> **Environment note:** GitHub-hosted runners have full internet (so `model-fetch`
> reaches huggingface.co) and enough RAM — the limits that block the agent's own
> sandbox do not apply on Actions. Verify by triggering the workflow via
> `workflow_dispatch` on the PR branch and confirming it goes green; the first run is
> minutes (CPU model load), cached runs faster.
>
> **Scope:** `docker-compose.cpu.yml` + `.github/workflows/eval-nightly.yml` only. No
> app / ranking / harness changes.
>
> **DoD override:** verification is a green `workflow_dispatch` run of the nightly
> workflow, not a local sandbox run.
>
> [+ Standing requirements block, minus item 5's local-stack clause]

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
