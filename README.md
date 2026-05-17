# local_ai_code_vault

A local, Docker-contained semantic search vault for your code. Instead
of Claude reading source files directly, it queries an indexed vector
store; git commit hooks keep the index fresh.

## How it works

A long-running stack (`qdrant` + a GPU `embedder` + a FastAPI `api`)
serves search. An ephemeral container indexes one repo at a time
(tree-sitter chunking → embeddings → Qdrant). PowerShell host scripts
and a thin Claude skill (`/vault-*`) drive it. Architecture decisions
and phase plan are in [plan.md](plan.md).

## Requirements

- Docker + Compose v2, an NVIDIA GPU + the NVIDIA Container Toolkit.
- PowerShell 7+ (`pwsh`) and `git` on PATH.

## Usage

1. **Start the stack:** `cp .env.example .env` then
   `docker compose up -d --build`. Full setup, GPU prerequisites, and
   validation steps: [README_SETUP.md](README_SETUP.md).
2. **Open your repo** in Claude Code.
3. **Index it:**
   `pwsh -NoProfile -File scripts/index-repo.ps1 . -Build -Wait`
   (or use the `/vault-index` skill command).
4. **Search:** `/vault-search "<query>"`, or check state with
   `/vault-status`, inspect what's indexed with `/vault-inspect`, and
   auto-reindex on commit with `/vault-hooks`.

The skill is pure delegation; all logic is in standalone, individually
runnable scripts — contracts in [scripts/README.md](scripts/README.md).

## Development

- Tests: `pytest` (Python, in-memory fakes) and `tests/scripts.Tests.ps1`
  (Pester, host-script logic — fakes git/docker/API, no stack needed).
  Both run in CI on PRs to `main`. The live end-to-end check is the
  manual gate `pwsh -NoProfile -File tests/smoke_test.ps1` (needs the
  running stack; not in CI).
- Contributing: never commit to `main` — feature branch → PR → merge;
  keep CI green. See [CLAUDE.md](CLAUDE.md) for architecture and
  conventions.

## Status

Phases 1 (stack, indexer, query) and 2 (skill + scripts) complete.
Phase 3 (testing & validation) next — see [plan.md](plan.md).
