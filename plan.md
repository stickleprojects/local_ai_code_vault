# Semantic Code Search for Claude — Project Plan

**Project Goal:** Build a Docker-based, multi-project semantic code search service that integrates with Claude (Cowork mode). Source code is mounted **only during indexing** via an ephemeral indexer container; the long-running services never see source.

**User:** kieron (kieronwray@gmail.com)
**Environment:** Windows 11, 16GB VRAM, Docker Desktop, local development
**Scope:** Single user, local desktop, multi-project, Claude-driven orchestration

---

## Architecture Decisions (locked)

- **AD-1 — Decomposed stack, not a monolith.** Separate long-running services: `qdrant`, `ollama`, `api`. None of them ever mounts source code.
- **AD-2 — Ephemeral indexer.** Indexing runs in a short-lived `indexer` container that bind-mounts exactly one repo, read-only, embeds + writes to Qdrant, then exits. This removes any fixed `/repos` mount and supports projects located anywhere on the host (resolves the old multi-project mount gap).
- **AD-3 — Orchestration = Option B (Claude on host).** Claude Code already runs on the host with shell + Docker access. The skill does **not** spawn containers via a Docker socket. Instead the skill calls **named, standalone script files** that wrap all logic. No Docker-out-of-Docker, no socket exposure.
- **AD-4 — Thin skill, fat scripts.** `SKILL.md` only defines commands and delegates. Every piece of logic lives in a separately-named script that can be run and debugged by hand (clear args, exit codes, logging). No business logic inlined in the skill.
- **AD-5 — Shared warm embedding service (RESOLVED via B-1).** One long-running **llama.cpp embeddings server** (`server-cuda`, `--embeddings --pooling last`) serving `nomic-embed-code` Q4_K_M, GPU, model kept warm, indexing jobs serialized to protect 16 GB VRAM. (Ollama removed.)
- **AD-6 — Freshness by commit SHA, not date.** The vault stores the indexed HEAD SHA per repo. Staleness = `stored_sha != git rev-parse HEAD`. Enables incremental reindex via `git diff --name-only`.
- **AD-8 — Supported languages (initial, locked): C#, Python, JavaScript, TypeScript.** The indexer image bundles exactly these tree-sitter grammars. Files in unsupported languages are skipped (not error) and counted as `skipped` in stats so it's visible what was ignored. Adding a language = add its grammar + chunking rules + rebuild the indexer image; no re-index of other languages needed.
- **AD-9 — Introspection is first-class, separate from search.** Beyond semantic `/api/query`, the system exposes read-only inspection of *what has been indexed* (per repo: indexed SHA + time, file count, chunk count, per-language breakdown, skipped files, and a listable file/chunk inventory). This is a distinct surface (`/api/repos/{repo_id}/stats`, `/api/repos/{repo_id}/files`) and its own skill command — not overloaded onto search. Future Web UI (5.3) is a thin client over this.
- **AD-7 — Embedding model = `nomic-embed-code` Q4_K_M, dim 3584 (RESOLVED via B-1).** Same model for index + query. Vector dimension **3584** permanently sets Qdrant collection size (cosine) — changing model later = drop + re-index everything. Verified working via llama.cpp `--pooling last`; the single dimension constant lives in `models.py`. See also **AD-10** (prompt-prefix asymmetry).

---

## ✅ BLOCKER B-1 — RESOLVED (2026-05-16)

**Outcome:** `nomic-embed-code` is kept (D1), served via a **raw llama.cpp embeddings server** with `--pooling last` (D2), **containerized with the `nvidia` runtime** (D3). Phase 1 is UNBLOCKED.

### Why Ollama failed, and the fix

The original Ollama all-zero result was **purely a missing pooling configuration**, not a model or hardware fault. `nomic-embed-code` (7B, Qwen2-based) requires **last-token pooling + L2 normalization** (per the HF model card); Ollama applied no/wrong pooling and emitted zero vectors. Forcing `--pooling last` in a raw llama.cpp server fixes it completely.

### Evidence (verified spike, llama.cpp server-cuda, local Q4_K_M GGUF)

| Check | Result | Verdict |
| --- | --- | --- |
| Vector dimension | **3584** | ← the single `models.py` constant |
| Non-zero / L2 magnitude | 3584/3584, mag = 1.0 | healthy (vs Ollama 0/3584) |
| Identical code | cos = 1.000 | deterministic, correct |
| Related code (2 factorial impls) | cos = 0.52 | strong |
| Unrelated code (factorial vs SQL) | cos = 0.08 | near-zero |
| NL query → matching code | cos = 0.51 | strong retrieval signal |
| NL query → non-matching code | cos = 0.015 | near-zero |

Match vs non-match separation ≈ 34×. Model loads on GPU in ~14 s; 4.38 GB Q4_K_M leaves large headroom on the 16 GB RTX 4080. E-O2/E-GT were **not run** — E-O4 alone is decisive (gives both a working lightweight runtime and unambiguous correctness); heavier experiments would only re-confirm a solved question.

### Locked decisions (resolve/replace AD-5 & AD-7)

- **D1 model:** `nomic-embed-code`, **GGUF Q4_K_M** (`nomic-ai/nomic-embed-code-GGUF`). Q4_K_M proven sufficient; Q6_K/Q8_0 remain optional fidelity upgrades (still fit 16 GB) — a tunable, not a blocker.
- **D2 runtime:** `ghcr.io/ggml-org/llama.cpp:server-cuda`, flags **`--embeddings --pooling last`**, OpenAI-compatible `/v1/embeddings`. (Replaces Ollama; Ollama dropped from the stack — the system only needs embeddings.)
- **D3 deployment:** compose service, `--gpus all` (nvidia runtime confirmed), model kept warm (AD-5 principle holds), indexing serialized.
- **Vector dimension constant = `3584`** → the single source of truth in `models.py`; Qdrant collections created with size 3584, cosine distance.

### ⚠️ AD-10 — Prompt-prefix asymmetry (CONTRACT, like repo_id)

`nomic-embed-code` is asymmetric: **queries** must be prefixed with `Represent this query for searching relevant code: `; **code chunks** get **no prefix**. Indexer embeds code raw; the query path adds the prefix. This must live as one shared constant/helper (used by both `indexer/embedder.py` and `src/query_handler.py`) — a mismatch silently degrades retrieval. Treated as a sacred contract alongside repo_id.

### GGUF provenance (Phase 1.4 must vendor this cleanly)

Proven file = Ollama blob `sha256-4354a73ee9ff5d811efe552a515dfd518667ff25fdfc4ee9e10af3f617f96eec` (4.38 GB). The real stack must **not** depend on Ollama's blob path: Phase 1.4 downloads the Q4_K_M GGUF from `nomic-ai/nomic-embed-code-GGUF` into a named volume, pinned by SHA256, with the exact server flags recorded. Ollama itself is no longer required and may be uninstalled if unused elsewhere.

---

## High-Level Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ Host (Windows) — Claude Code (Cowork)                       │
│  Skill: /vault-* commands → call named host scripts:        │
│   scripts/vault-health.ps1   scripts/repo-id.ps1            │
│   scripts/vault-status.ps1   scripts/index-repo.ps1         │
│   scripts/index-status.ps1   scripts/query.ps1              │
│   scripts/install-git-hooks.ps1                             │
└─────────────────────────────────────────────────────────────┘
         │ HTTP :8000                 │ docker run --rm (Option B)
         ▼                            ▼
┌──────────────────────┐   ┌──────────────────────────────────┐
│ docker compose stack │   │ indexer (ephemeral, per job)      │
│                      │   │  -v <HOST_REPO_PATH>:/repo:ro     │
│  ┌────────────────┐  │   │  tree-sitter chunk → embed →      │
│  │ api  :8000     │  │   │  write to qdrant → exit           │
│  │  /api/status   │  │   │  joins stack network              │
│  │  /api/repos    │  │   └──────────────────────────────────┘
│  │  /api/query/.. │  │                  │ writes
│  │  /api/repos/.. │  │                  ▼
│  └────────────────┘  │   ┌──────────────────────────────────┐
│  ┌────────────────┐  │   │ qdrant  (persistent /data volume) │
│  │ embedder (warm)│◄─┼───┤  one collection per repo_id       │
│  │ llama.cpp svr  │  │   │  vectors: dim 3584, cosine        │
│  │ nomic-embed-   │  │   └──────────────────────────────────┘
│  │ code Q4 (GPU)  │  │
│  └────────────────┘  │
└──────────────────────┘
   No source code is ever mounted into api / embedder / qdrant.
```

---

## repo_id Contract (single source of truth)

`repo_id` MUST be computed by exactly one script (`scripts/repo-id.ps1`) and reused everywhere (skill, indexer args, Qdrant collection name, git hook). This eliminates any mismatch between "is it registered" / "is it stale" / "where do results come from".

- **Rule:** `repo_id = slug(basename(repo_root)) + "-" + short_sha1(normalized_absolute_repo_root_path)[:8]`
- Works for local-only repos (no remote required), stable across sessions, unique across same-named projects in different locations.
- The indexer receives `repo_id` as an explicit argument — it never recomputes it independently.

---

## Normal User Flow (target experience)

1. User starts Claude in their project folder (repo root).
2. User ensures the vault stack is running (`docker compose up -d`, or always-on). Skill verifies via `scripts/vault-health.ps1`.
3. User asks Claude to check registration. Claude runs `scripts/repo-id.ps1` then `scripts/vault-status.ps1`; if not registered, offers to index via `scripts/index-repo.ps1`.
4. Claude compares stored indexed SHA (from `vault-status`) vs local `git rev-parse HEAD` (AD-6). If stale, Claude tells the user how many commits / which files changed and offers a (incremental) reindex.
5. Claude offers to install git hooks (`scripts/install-git-hooks.ps1`) for automatic reindex on commit/merge.
6. Background reindex completion: `index-repo.ps1` returns a job/container id; `scripts/index-status.ps1` reports state via `docker wait`/`docker inspect`. Claude can poll it as a tracked background task and report completion **within the open session**. (No detached OS notification when Claude is closed — documented limitation.)

---

## Phases & Tasks

### **PHASE 1: Core Services & Indexer**

_Deliverable: Running compose stack + ephemeral indexer that indexes any host repo._

#### Task 1.1: API Service & Repo Registry

- **What:** FastAPI service that:
  - Maintains a repo registry in Qdrant metadata (NOT by scanning a mount — no `/repos` mount exists anymore).
  - **Search:** `/api/status` (health), `/api/repos` (list registered repo_ids + indexed SHA + last indexed time), `/api/repos/{repo_id}` (per-repo status), `/api/query/{repo_id}` (semantic search).
  - **Introspection (AD-9, read-only):** `/api/repos/{repo_id}/stats` (file count, chunk count, per-language breakdown, skipped-file count, indexed SHA + time), `/api/repos/{repo_id}/files` (paginated inventory of indexed files with per-file chunk/language info).
  - Registration is implicit: a repo becomes "registered" when the indexer first writes its collection + metadata.
- **Owner:** Claude (pure, agentic — see prior analysis: foundational, execution-validated)
- **Dependencies:** None
- **Outputs:** `src/app.py`, `src/registry.py`, `src/inspection.py` (stats/inventory queries over Qdrant), `src/models.py` (Pydantic schemas reused by indexer + query), tests
- **Validation:** stack up, `/api/status` 200, `/api/repos` returns `[]` on fresh start then the repo after first index; `/api/repos/{repo_id}/stats` returns correct counts + per-language breakdown for the test repo

#### Task 1.2: Ephemeral Indexer (Tree-Sitter + Embeddings)

- **Pre-flight — ✅ CLEARED (B-1 resolved):** model+runtime proven (`nomic-embed-code` Q4_K_M via llama.cpp `--pooling last`, dim **3584**). `models.py` defines `EMBED_DIM = 3584` and the AD-10 prefix constants before any collection is created.
- **What:** Standalone container image run per job (`docker run --rm`):
  - Args: `--repo-id`, `--qdrant-url`, `--embedder-url`, optional `--changed-files` (incremental).
  - Mounts `/repo:ro`; walks repo, tree-sitter chunk by function/class for **C#, Python, JavaScript, TypeScript** (AD-8), embed via the shared embedder (llama.cpp), upsert to Qdrant collection `repo_id`, write/update repo metadata (indexed SHA, timestamp, per-language stats, skipped-file count).
  - Unsupported languages: skipped, not errored; counted in `skipped` so introspection (AD-9) shows what was ignored.
  - Windows path normalization handled host-side by `repo-id.ps1`; container sees a clean `/repo`.
- **Owner:** Claude
- **Dependencies:** 1.1 (schemas), 1.3 (embedder service available)
- **Outputs:** `indexer/Dockerfile`, `indexer/index.py`, `indexer/chunker.py` (per-language tree-sitter rules: C#, Python, JavaScript, TypeScript), `indexer/embedder.py` — language set extensible by adding grammar + rules
- **Validation:** `docker run` on a small test repo creates the Qdrant collection with chunk metadata + stored HEAD SHA; rerun with `--changed-files` updates only those

#### Task 1.3: Query Logic (Qdrant + Ranking)

- **What:** Embed query via the shared embedder, search the repo's Qdrant collection, return top-K (file, lines, code, score), formatted for Claude.
- **Owner:** Claude
- **Dependencies:** 1.1, 1.2
- **Outputs:** `src/query_handler.py`, response schema in `models.py`
- **Validation:** `/api/query/{repo_id}?q=...` returns sensibly ranked results on the test repo

#### Task 1.4: docker-compose Stack (qdrant + embedder + api)

- **What:** `docker-compose.yml` with three long-running services, **no source mounts**:
  - `qdrant` (official image, named volume for `/data`), **`embedder`** = `ghcr.io/ggml-org/llama.cpp:server-cuda`, `--gpus all`, flags `--embeddings --pooling last`, model = vendored `nomic-embed-code` Q4_K_M GGUF in a named volume (pinned by SHA256, downloaded from `nomic-ai/nomic-embed-code-GGUF` — NOT via Ollama), `api` (slim Python image, port 8000).
  - Stable network name so the ephemeral indexer can `--network <stack>_default`.
  - Healthchecks; `.env.example`.
- **Owner:** Claude
- **Dependencies:** 1.1–1.3
- **Outputs:** `docker-compose.yml`, `api/Dockerfile`, `.dockerignore`, `.env.example`, `README_SETUP.md`
- **Validation:** `docker compose up -d` reaches healthy; volumes persist across restart; indexer container can reach `qdrant` + `embedder` by service name

---

### **PHASE 2: Claude Skill + Host Scripts (thin skill, fat scripts)**

_Deliverable: `/vault-*` skill that delegates to named, individually-debuggable scripts (AD-4)._

> **Sequencing (revised 2026-05-17 — supersedes original 2.1→2.2→2.3):**
> Build the **scripts (with error handling intrinsic) first, then write
> SKILL.md last** against their frozen contracts. Rationale: AD-4 makes
> SKILL.md *pure delegation* — its entire content is a function of the
> scripts' final arg/JSON/exit-code contracts, and error handling lives
> *inside* the scripts (consistent exit codes), not the skill. Writing
> the skill first means writing it against contracts that don't exist
> yet and rewriting it twice as the scripts and their error handling
> settle. The command surface itself was already designed at planning
> time (enumerated in Task 2.2 below), so nothing is lost by writing the
> file last. Error handling is therefore folded into the script task
> (former Task 2.3 is not a separate pass — bolting it on later produces
> inconsistent handling). One Phase 2 PR: SKILL.md is tiny and
> meaningless without the scripts.

#### Task 2.1: Host Scripts + Error Handling (all logic lives here)

Each script: clear name, single responsibility, runnable standalone with documented args, explicit exit codes, `--verbose` logging to stderr, machine-readable (JSON) stdout for the skill to parse. Error handling is written **with** each script, not after.

- `scripts/repo-id.ps1 <path>` — print canonical repo_id (the AD-2/contract source of truth). **Build first** — every other script resolves repo_id through it.
- `scripts/vault-health.ps1` — stack reachable? `/api/status` 200. Exit 0/!=0.
- `scripts/vault-status.ps1 <path>` — registered? returns `{registered, indexed_sha, indexed_at, head_sha, stale, changed_files[]}`.
- `scripts/index-repo.ps1 <path> [--incremental] [--wait]` — Option B launcher: `docker run --rm --network <stack>_default -v <hostpath>:/repo:ro indexer ...`. Prints `{job_id|container_id}`. `--wait` blocks and streams progress.
- `scripts/index-status.ps1 <container_id>` — `docker wait`/`docker inspect` → `{state, exit_code, done}`.
- `scripts/query.ps1 <path> <query>` — resolve repo_id, call `/api/query`, return formatted results.
- `scripts/vault-inspect.ps1 <path> [--files] [--language <lang>]` — resolve repo_id, call `/api/repos/{repo_id}/stats` (and `/files` with `--files`); returns indexed SHA/time, file + chunk counts, per-language breakdown, skipped count, optional file inventory. Read-only (AD-9).
- `scripts/install-git-hooks.ps1 <path> [--remove]` — writes a minimal POSIX `post-commit`/`post-merge` hook (git runs hooks via bundled `sh` on Windows) that fires `index-repo` non-blocking; hook degrades gracefully if the stack is down.
- **Error handling & fallbacks (intrinsic to each script, consistent exit codes — never in the skill):** stack down → restart instructions; repo not registered → offer `/vault-index`; not a git repo → explain; indexer non-zero exit → surface `docker logs`; VRAM/queue busy → retry guidance.
- **Owner:** Claude
- **Dependencies:** Phase 1 complete
- **Validation:** every script runs correctly when invoked **by hand** with args, independent of the skill; each error scenario produces a clear, actionable message via a consistent exit code; JSON contracts documented in `scripts/README.md`

#### Task 2.2: SKILL.md Definition (thin delegation — written last, against frozen contracts)

- **What:** Commands only, each mapping to one script (the command surface is fixed here at planning time; the file is written against the now-frozen `scripts/README.md` JSON contracts):
  - `/vault-status` → check stack + registration + freshness
  - `/vault-index` → index/reindex current repo
  - `/vault-search <query>` → semantic search current repo
  - `/vault-inspect` → show what's indexed for current repo (counts, per-language breakdown, skipped files, file inventory) — AD-9, read-only
  - `/vault-hooks` → install/remove git hooks
- **Owner:** Claude
- **Dependencies:** 2.1 complete (script contracts frozen)
- **Outputs:** `SKILL.md`
- **Validation:** commands recognized in Claude UI; SKILL.md contains no logic, only delegation

---

### **PHASE 3: Testing & Validation**

> **Resolved 2026-05-17 — CI-vs-PowerShell (Option B chosen):** the CI
> runner is Linux + `pytest`, with no Docker stack/GPU. Script logic
> splits into *pure* (repo_id contract, exit-code/JSON emitter, arg
> validation, hook-file generation — mockable, no stack) vs
> *integration* (real index/query — needs the GPU stack). Decision:
> automate the pure half with **Pester** in a **second CI job** running
> `pwsh` on the free Linux runner (git/docker/HTTP mocked); keep the
> end-to-end `smoke_test.ps1` as a **documented manual gate** (a
> self-hosted GPU runner to automate it is disproportionate and only
> re-proves the already-closed B-1 path). Note: the Python unit/
> integration tests below were already written alongside Phases 1.1–1.3
> (ahead of plan); Task 3.1 is therefore mostly the Pester job + manual
> smoke doc.

#### Task 3.1: Smoke Test Suite

- Python unit/integration: **already delivered** in Phases 1.1–1.3 —
  `tests/test_models.py`, `test_chunker.py`, `test_embedder.py`,
  `test_indexer.py`, `test_query_handler.py`, `test_api.py` (28 tests,
  in-memory fakes, the existing required CI gate).
- New: **`tests/scripts.Tests.ps1`** — Pester tests for the pure script
  logic (repo_id/AD-2 contract first, exit codes, JSON shape, hook
  file), `git`/`docker`/`Invoke-WebRequest` mocked.
- New: **`.github/workflows/ci.yml`** gains a `pester` job (`pwsh` on
  `ubuntu-latest`, no GPU) run alongside `pytest`.
- **`tests/smoke_test.ps1`** — true E2E (`compose up` → `index-repo.ps1`
  on a fixture → query → verify); **manual gate**, documented, not in
  CI. (The live end-to-end run was already exercised by hand in Phase 2.)
- **Owner:** Claude + GitHub Actions (CI)
- **Outputs:** `tests/scripts.Tests.ps1`, `tests/smoke_test.ps1`, updated `.github/workflows/ci.yml`

#### Task 3.2: Manual Testing on Windows + Docker Desktop

- Multi-project: index 2+ repos in different host locations, switch between them, verify isolation by `repo_id`. Stale detection after a commit. Git-hook auto-reindex. Background completion reporting. `/vault-inspect` reports correct per-language counts on a mixed C#/Py/JS/TS repo and lists skipped files.
- **Owner:** User (Kieron) — ~30 min

#### Task 3.3: Documentation — **DONE (2026-05-17)**

- `docs/SETUP.md`, `docs/TROUBLESHOOTING.md`, `docs/EXAMPLES.md`, `docs/ARCHITECTURE.md` written (synthesize, don't duplicate — they cross-link `README_SETUP.md` for the GPU stack and `scripts/README.md` for I/O contracts, both of which already existed). README gains a Documentation index.
- **Owner:** Claude

---

### **PHASE 4: CI/CD & Publishing (GitHub Agents)**

#### Task 4.1: GitHub Actions — Build & Push — **DEFERRED (2026-05-17)**

- _Original:_ build + push both images (`api`, `indexer`) to GHCR on
  push to `main` / dispatch; smoke first; tag `latest`.
- **Deferred — rationale:** this is a single-user, single-machine local
  tool. Both images already build locally (`docker compose up -d
  --build`; `index-repo.ps1 -Build` → `vault-indexer:local`) and Docker
  caches the layers. GHCR publishing only adds value with multiple
  machines, external consumers, or a need for frozen reproducible
  artifacts — none of which apply today. Same "single user; defer"
  reasoning as Phase 5.2/5.3. Revisit if any of those conditions change
  (note: `indexer/Dockerfile` uses a floating `python:3.12-slim` base,
  so reproducibility is the most likely trigger).
- **Outputs (when revived):** `.github/workflows/build-and-push.yml`

#### Task 4.2: Semantic Versioning & Tagging — **lightweight scope**

- Rescoped to the part with standalone value and no secrets/registry
  dependency (4.1 deferred): `CHANGELOG.md` (Keep a Changelog) +
  documented SemVer `vMAJOR.MINOR.PATCH` git-tag convention +
  tag-triggered **GitHub Release** workflow (built-in `GITHUB_TOKEN`,
  no image push, no `GHCR_TOKEN`). Image-version tagging drops with 4.1.
- **Owner:** Claude
- **Outputs:** `CHANGELOG.md`, `.github/workflows/release.yml`

#### Task 4.3: GitHub Secrets & Security — **DEFERRED (2026-05-17)**

- _Original:_ `GHCR_TOKEN`, rotation docs, no secrets in logs.
- **Deferred — rationale:** exists only to serve 4.1's GHCR push;
  deferred with it. The lightweight 4.2 release workflow uses the
  built-in `GITHUB_TOKEN`, so no managed secret is introduced. Revive
  alongside 4.1.

---

### **PHASE 5: Optional Enhancements**

- **5.1 Auto-index file watcher** — superseded by git hooks (Task 2.2) for the common case; keep watcher only if real-time (pre-commit) freshness needed. _Defer._
- **5.2 API authentication** — single user; defer.
- **5.3 Web UI** — browse repos / stats / history; defer.
- **5.4 More languages** — beyond the locked initial set (C#, Python, JavaScript, TypeScript — AD-8): Go, Rust, C++, Java, Ruby via added tree-sitter grammars + chunking rules; extend on demand.

---

## Dependencies & Sequencing

```
Phase 1 (sequential):
  1.1 (API/Registry) → 1.2 (Indexer) → 1.3 (Query) → 1.4 (Compose stack)
       (1.2 & 1.3 need the embedder from 1.4's services; bring embedder+qdrant up early
        as a dev sub-stack so 1.2/1.3 can be validated before full 1.4)

Phase 2 (after Phase 1):
  2.1 (Host scripts + error handling) → 2.2 (SKILL.md, thin, last)

Phase 3: 3.1 (CI tests) ‖ 3.2 (manual) → 3.3 (docs)
Phase 4: 4.2 (lightweight, standalone)   [4.1, 4.3 deferred — see Phase 4]
Phase 5: future
```

---

## Validation Checkpoints

| Phase | Checkpoint        | Success Criteria                                              |
| ----- | ----------------- | ------------------------------------------------------------- |
| 1.1   | API up            | `/api/status` 200, `/api/repos` `[]` on fresh start           |
| 1.2   | Indexer works     | `docker run` indexes C#/Py/JS/TS fixture; collection + SHA + per-lang stats + skipped count present |
| 1.3   | Query works       | `/api/query/{repo_id}` returns ranked results                 |
| 1.4   | Stack works       | `docker compose up -d` healthy; indexer reaches qdrant/embedder |
| 2.1   | Scripts standalone| Each script runs correctly invoked by hand with args; each error scenario gives a clear message + consistent exit code |
| 2.2   | Skill defined     | Commands appear; SKILL.md contains no logic, only delegation   |
| 2.E   | End-to-end        | `/vault-search` returns results; `/vault-inspect` shows correct counts/languages for the repo |
| 3.1   | Tests pass        | Unit/integration/E2E + per-script tests green                 |
| 3.2   | Manual multi-proj | 2+ repos isolated by repo_id; stale detect + hooks work       |
| 3.3   | Docs complete     | Script contracts documented; new user can follow setup        |
| 4.x   | CI/CD             | Both images build, push to GHCR, versioned, secrets safe      |

---

## File Structure (Final)

```
local_ai_code_vault/
├── docker-compose.yml
├── .dockerignore
├── .env.example
│
├── api/
│   └── Dockerfile               # slim python (api only, no source mount)
├── src/
│   ├── app.py                   # FastAPI server
│   ├── registry.py              # repo registry (Qdrant-backed)
│   ├── inspection.py            # AD-9: stats / file inventory (read-only)
│   ├── query_handler.py         # search logic
│   └── models.py                # Pydantic schemas (shared)
│
├── indexer/
│   ├── Dockerfile               # ephemeral indexer image
│   ├── index.py                 # entrypoint (args: repo-id, urls, changed-files)
│   ├── chunker.py               # tree-sitter chunking (C#, Py, JS, TS)
│   └── embedder.py              # embedder client (llama.cpp /v1/embeddings)
│
├── scripts/                     # ALL skill logic (Option B, AD-4)
│   ├── vault-health.ps1
│   ├── repo-id.ps1              # repo_id contract — single source of truth
│   ├── vault-status.ps1
│   ├── index-repo.ps1           # docker run launcher
│   ├── index-status.ps1
│   ├── query.ps1
│   ├── vault-inspect.ps1        # AD-9: what's indexed (read-only)
│   ├── install-git-hooks.ps1
│   └── README.md                # arg + JSON-output contracts
│
├── tests/
│   ├── test_registry.py
│   ├── test_indexer.py
│   ├── test_query.py
│   ├── test_api.py
│   ├── test_scripts.ps1
│   ├── smoke_test.ps1
│   └── fixtures/test_repo/
│
├── .github/workflows/
│   ├── build-and-push.yml
│   └── release.yml
│
├── docs/
│   ├── SETUP.md
│   ├── TROUBLESHOOTING.md
│   ├── EXAMPLES.md
│   └── ARCHITECTURE.md
│
├── SKILL.md                     # thin: commands → scripts only
├── README.md
├── CHANGELOG.md
└── requirements.txt
```

---

## Estimated Timeline

| Phase | Tasks    | Effort               | Timeline                           |
| ----- | -------- | -------------------- | ---------------------------------- |
| 1     | 1.1–1.4  | High (core)          | ~3–4 sessions (Claude)             |
| 2     | 2.1–2.3  | Medium (skill+scripts)| ~2 sessions (Claude)              |
| 3     | 3.1–3.3  | Medium               | ~1–2 sessions (Claude + user)      |
| 4     | 4.2 only | Low (4.1/4.3 deferred)| ~0.5 session (Claude)             |
| 5     | Optional | Varies               | Future                             |

**Total: ~7–9 sessions for Phases 1–4**

---

## Notes for Future Sessions

- Each session references this plan and states the active task; validate checkpoints before moving on.
- **repo_id contract is sacred** — only `scripts/repo-id.ps1` computes it; everything else calls that script.
- **No logic in SKILL.md** — if you're tempted to add logic to the skill, it belongs in a named script under `scripts/`.
- Known limitation: background-index completion is reported only while the Claude session is open (no detached OS notification).
- **Embedding model pinned (`nomic-embed-code` Q4_K_M, AD-7, dim 3584)** — never swap without dropping/re-indexing every Qdrant collection; `EMBED_DIM = 3584` is the only place the dimension is defined (`models.py`).
- **AD-10 prompt-prefix is a contract** — queries get `Represent this query for searching relevant code: `, code gets none; one shared helper used by both indexer and query path. A silent mismatch wrecks retrieval quality.
- **Embedder runtime = llama.cpp `--embeddings --pooling last`** (NOT Ollama — Ollama emits all-zero vectors for this model because it skips last-token pooling).

---

**Created:** 2026-05-16 · **Revised:** 2026-05-17 (Phase 1 complete: 1.1–1.4 merged; **Phase 2 resequenced** — scripts+error-handling first, thin SKILL.md last). Prior revision 2026-05-16 (decomposed stack, ephemeral indexer, Option B, script-based skill, languages C#/Py/JS/TS, introspection first-class; **B-1 RESOLVED**: nomic-embed-code Q4_K_M via llama.cpp `--pooling last`, dim 3584)
**Status:** ✅ Phase 1 complete (1.1 API/registry, 1.2 indexer, 1.3 query, 1.4 compose stack — all merged; live `docker compose up` smoke test in progress). ▶ Next: Phase 2.1 (host scripts + error handling).
