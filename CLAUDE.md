# CLAUDE.md

Guidance for Claude Code working in this repository.

## What this is

A local semantic code-search service for Claude: instead of reading
source files directly, Claude queries an indexed vector store. A
long-running Docker stack serves search; an ephemeral container indexes
a repo on demand; PowerShell host scripts + a thin skill drive it.

Authoritative design lives in `plan.md` (phases, architecture
decisions `AD-*`, the resolved B-1 embedding blocker). Read it before
non-trivial changes.

## Architecture (the parts that span files)

- **`src/`** — FastAPI service (Phase 1). `app.py` wires routes;
  `registry.py` reads the implicit repo registry from a reserved Qdrant
  collection; `inspection.py` is AD-9 read-only introspection;
  `query_handler.py` is semantic search; `models.py` is the **single
  source of truth** for the embedding contract.
- **`indexer/`** — standalone per-job image (`docker run --rm`).
  `chunker.py` (tree-sitter, C#/Py/JS/TS), `embedder.py`,
  `qdrant_writer.py`, `index.py` (orchestration + CLI). It is the
  *producer* of the registry that `src/` reads — a round-trip test
  locks that payload contract.
- **`docker-compose.yml`** — `qdrant` + `embedder`
  (`llama.cpp:server-cuda`, GPU) + `api`, plus one-shot `model-fetch`
  (SHA256-pinned GGUF). Project pinned `name: vault` ⇒ network
  **`vault_default`**, which the indexer joins by name.
- **`scripts/*.ps1`** + **`SKILL.md`** — AD-4 "thin skill, fat
  scripts": all logic in standalone scripts, the skill only delegates.

## Sacred contracts (breaking these silently corrupts results)

- **`repo_id` (AD-2):** computed by **exactly one** place,
  `scripts/repo-id.ps1`. Nothing else recomputes it.
- **Embedding (AD-7/B-1):** `nomic-embed-code`, dim **3584**, cosine.
  The constant lives only in `src/models.py`.
- **Prompt-prefix asymmetry (AD-10):** queries get
  `format_query` (prefixed), code gets `format_code` (no prefix).
  Indexer embeds code raw; query path prefixes. One helper per side.

## Commands

- Tests: `pytest` (config in `pyproject.toml`; CI runs `pytest -v`).
  Single test: `pytest tests/test_query_handler.py::test_handler_none_when_repo_unregistered`.
  Tests use in-memory fakes — **no Qdrant/embedder needed**.
- Local venv is Python 3.14; CI is 3.12. tree-sitter is pinned
  `>=0.25,<0.26` (core) so wheels exist on both.
- Stack: `docker compose up -d` (needs NVIDIA + Container Toolkit; see
  `README_SETUP.md`). Index a repo by hand:
  `pwsh -NoProfile -File scripts/index-repo.ps1 <path> -Build -Wait`.
- Script I/O contract + exit codes: `scripts/README.md`.

## Conventions

- **Never commit to `main`.** Every phase/change = feature branch →
  PR → merge. Enforced by a local `PreToolUse` hook in
  `.claude/settings.json` *and* server-side branch protection
  (`pytest` is a required check, strict, admins included).
- Keep CI green on every PR. CI = `.github/workflows/ci.yml` (pytest on
  PRs to `main`).
- Match existing module style: a thin injectable class with a lazy
  client and a `Protocol` for the test fake (see `registry.py`,
  `qdrant_writer.py`).
- `src/` must not import from `indexer/` (layering: indexer depends on
  src, not vice versa).
- Don't commit `.claude/settings.local.json` (machine-local).
