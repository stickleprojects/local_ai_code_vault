# Vault Search — Impact Analysis & Improvement Recommendations

**Date:** 2026-05-24
**Author:** Claude Code session (observed from consumer repo `azure-devops-analyzer`)
**Vault state at time of test:** API `0.1.0`, embed model `nomic-embed-code` (dim 3584), Qdrant connected.
**Consumer repo:** `azure-devops-analyzer-4f67ee74`, indexed at `6349fc8` (fresh).

---

## 1. Context

This analysis came out of a real task: adding an end-to-end test for
`RadarPublicationWorkflow` in the `azure-devops-analyzer` repo. During that task
the vault was **not** used — the work was done with `Glob` / `Grep` / `Read`.
Afterward we asked: *would the vault have helped, and by how much?*

To answer empirically rather than guess, we replayed the two searches that map
to the actual discovery moments of the task and inspected both the returned
results and the tool's own `savings` block.

This is consumer-side feedback intended to drive changes to the vault code.

---

## 2. Methodology

Two `query-smart.ps1` queries were run with `-DoNotIndex -Limit 6`, chosen to
mirror the two real questions the task required answering:

- **Query A — "find the implementation to mirror":** locate the workflow class
  and its sibling tests to model the new test on.
- **Query B — "find the test-setup conventions":** locate how DB contract tests
  obtain a session and seed `repository_dependencies` / `packages`.

For each, we recorded the ranked results (path, line range, score) and the
`savings` object verbatim.

> Caveat baked into the tool's own output: `basis = "estimate (~4 chars/token,
> not Claude tokenizer); baseline = full source of files in results = UPPER
> BOUND; excludes vault tool overhead and prompt caching"`. The savings numbers
> below are therefore ceilings, not realized savings.

---

## 3. Empirical Results

### Query A — `RadarPublicationWorkflow run categorize packages detect ring movements store publication blips history`

| Rank | File | Lines | Score |
|---|---|---|---|
| 1 | `src/workflows/radar_publication.py` | 31–312 | 0.637 |
| 2 | `src/workflows/radar_publication.py` | 42–88 | 0.605 |
| 3 | `tests/contract/database/test_radar_workflow_e2e.py` | 110–264 | 0.602 |
| 4 | `tests/contract/database/test_radar_workflow_e2e.py` | 112–177 | 0.579 |
| 5 | `tests/contract/database/test_radar_schema.py` | 59–200 | 0.544 |
| 6 | `tests/unit/test_radar_categorizer.py` | 287–394 | 0.540 |

`savings`: `returned=8437, baseline_upper=11993, saved_upper=3556, pct_upper=30, files=4`

**Verdict:** strong. Top results are exactly the files a developer would open.
Semantic relevance high (~0.6).

### Query B — `database contract test db_session savepoint fixture seed repository dependencies packages conftest`

| Rank | File | Lines | Score |
|---|---|---|---|
| 1 | `tests/contract/database/__init__.py` | 1–2 | 0.514 |
| 2 | `tests/contract/database/test_full_pipeline_e2e.py` | 372–399 | 0.442 |
| 3 | `tests/contract/integration/test_dependency_enrichment_e2e.py` | 260–527 | 0.435 |
| 4 | `tests/contract/integration/test_dependency_enrichment_e2e.py` | 268–329 | 0.428 |
| 5 | `tests/contract/integration/test_dependency_enrichment_e2e.py` | 332–373 | 0.423 |
| 6 | `tests/contract/integration/test_dependency_enrichment_e2e.py` | 376–493 | 0.417 |

`savings`: `returned=4623, baseline_upper=19829, saved_upper=15206, pct_upper=77, files=3`

**Verdict:** weak, and it **missed the single most important file**. The query
explicitly named `conftest` and `db_session`, yet `tests/contract/conftest.py`
(which *defines* the `db_session` savepoint fixture) never appeared. The #1 hit
was a 2-line `__init__.py`. The high "77% saved" is inflated — one returned file
is ~530 lines that nobody would read whole.

---

## 4. Impact by Lookup Type

The task involved four kinds of lookup. The vault's value varied sharply:

| Lookup | Example in this task | Vault value |
|---|---|---|
| **Semantic discovery** | "find the workflow + its tests to mirror" | **High** — Query A nailed it |
| **Known-path read** | open the plan doc, the ORM models | **None** — path already known; `Glob`/`Read` is exact and instant |
| **Definition lookup** | "where is the `db_session` fixture defined" | **Negative** — Query B under-ranked the defining `conftest.py` below a 2-line `__init__.py` |
| **Symbol/completeness** | "is `RadarPublicationWorkflow` referenced/tested anywhere?" | **Negative** — this is a `grep` job; ranked/approximate results can't prove absence |

**Net for this task:** a modest assist on one axis (locating the workflow and
its sibling tests), roughly equivalent to the `Grep`+`Read` already performed —
and neutral-to-counterproductive on the other three. The hardest parts
(understanding the `categorize()` contract; spotting that
`radar_blip_history.publication_date` is a `DATE`, so two same-day runs collide)
came from reading code closely, which no search shortcuts.

The vault would pay off more on a **cold start in an unfamiliar area** than in
this case, where the file map was already in session context.

---

## 5. What Works Well (keep)

- Semantic ranking on conceptual queries (Query A) is genuinely good.
- Results are **chunked with line ranges** — ideal for targeted reads rather
  than whole-file dumps.
- Clean one-JSON-object contract, stable exit codes, fast responses.
- The `savings.basis` string is honest about being an upper bound — good
  transparency; the problem is how that number is *presented* downstream.

---

## 6. Recommendations (prioritised)

### HIGH — Fix definition/fixture under-ranking
Query B proves that **definition sites lose to call sites and to trivial files**.
A query naming `conftest` + `db_session` should surface the file that *defines*
that fixture.
- Chunk pytest fixtures (and top-level `def`/`class`) as **first-class units**
  keyed on `name + signature + docstring`, so "how do I set up X" hits the
  definition.
- Add **symbol-aware boosting**: when query tokens match an indexed symbol name
  (fixture/function/class), boost chunks that *define* that symbol over chunks
  that merely use it.
- Consider a separate lightweight **definitions/symbols index** (signatures +
  docstrings) queried alongside the semantic index.

### HIGH — Add a lexical/symbol (exact) mode; document vault as discovery-not-completeness
Semantic search cannot answer "does X exist / where are all references" — yet
that's a common agent question. Today the right answer there is `grep`.
- Offer a `-Symbol <identifier>` (or hybrid lexical+semantic) mode that returns
  **all** exact matches, grep-backed, so the vault can serve completeness too.
- In the skill/README, state plainly: *semantic search is for fuzzy discovery;
  for "does this symbol exist anywhere" use exact mode / grep.*

### MEDIUM — Filter trivial and overlapping chunks
- Drop or heavily down-weight **near-empty files** (e.g. 1–2 line `__init__.py`).
  A 2-line file ranking #1 (Query B) is pure noise and wastes the result budget.
- **Dedupe nested/overlapping chunks from the same file.** Query A spent two of
  six slots on `radar_publication.py` where range `42–88` ⊂ `31–312`. Merge or
  collapse so the limit buys distinct hits.

### MEDIUM — Make the savings metric defensible
The upper-bound-only figure overstates value (77% in Query B against files a
developer would never read whole).
- Report a **conservative estimate alongside the upper bound** — e.g. baseline =
  sum of *returned chunk neighbourhoods* a developer would realistically open
  (rank-weighted), not full source of every file.
- Subtract **vault tool/JSON overhead** from net savings; note that **prompt
  caching** further erodes realized savings on repeat reads.
- In the one-line summary, label it explicitly as a ceiling (the script already
  knows this via `basis`; surface it in the headline too).

### MEDIUM — Surface staleness in search output
During this whole session the index was stale relative to HEAD. Pre-existing
files were fine, but freshly created/edited files would have been **silently
absent** from results.
- Add `index_stale: bool` + `changed_files_not_indexed: [...]` to search JSON so
  the agent knows results may miss recent edits.
- When stale **and** the delta is small, default to a fast incremental before
  searching (keep `-DoNotIndex` as the opt-out).

### LOW — Encourage cold-start usage
Vault's strongest case is unfamiliar-area orientation. Consider a skill nudge to
run a discovery search at the start of work in a repo/area the agent hasn't
touched, where it beats blind `Glob`/`Grep`.

---

## 7. Reproduction

```powershell
& "<vault>\scripts\query-smart.ps1" "RadarPublicationWorkflow run categorize packages detect ring movements store publication blips history" "d:\code\tyl\azure-devops-analyzer" -Limit 6 -DoNotIndex
& "<vault>\scripts\query-smart.ps1" "database contract test db_session savepoint fixture seed repository dependencies packages conftest" "d:\code\tyl\azure-devops-analyzer" -Limit 6 -DoNotIndex
```

Inspect the `results[]` ranking and the `savings` object in each response.
