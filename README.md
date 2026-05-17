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

**You clone this repo once.** Its `scripts/` and `SKILL.md` are **never
copied into the repos you want to search** — the skill calls the central
scripts by absolute path, and they take the target repo as an argument.

1. **Start the stack:** `cp .env.example .env` then
   `docker compose up -d --build`. Full setup, GPU prerequisites, and
   validation steps: [README_SETUP.md](README_SETUP.md).
2. **Install Claude skill (one-time, from this clone):**
   `pwsh -NoProfile -File scripts/install-skill.ps1`, then restart
   Claude Code. This places the skill in `~/.claude/skills/vault/` (so
   `/vault-*` works in *any* repo) and records `VAULT_HOME` so it can
   find the scripts. Re-run it if you move/update the clone;
   `-Remove` uninstalls.
3. **Open the repo you want to search** in Claude Code (any repo,
   anywhere — it does not need this project's files).
4. **Index it:** `/vault-index` (or, by hand from this clone,
   `pwsh -NoProfile -File scripts/index-repo.ps1 <repo-path> -Build -Wait`).
5. **Search:** `/vault-search "<query>"`, or check state with
   `/vault-status`, inspect what's indexed with `/vault-inspect`, and
   auto-reindex on commit with `/vault-hooks`.

The skill is pure delegation; all logic is in standalone, individually
runnable scripts — contracts in [scripts/README.md](scripts/README.md).

## Shared Claude + Copilot architecture

Claude and Copilot intentionally reuse the same runtime contracts:

- **One script layer (`scripts/*.ps1`)** is the only place where vault
  business logic lives.
- **Claude skill (`SKILL.md`)** delegates `/vault-*` commands to those
  scripts.
- **Copilot MCP adapter (`mcp/vault/server.py`)** delegates MCP tools to
  the same scripts.

This keeps behavior aligned across both clients and avoids duplicated
implementation paths.

## Copilot global setup (MCP, no per-repo config)

Copilot can use the same host scripts via a thin MCP adapter, installed
once at user scope (no repo-local Copilot files required):

1. `pwsh -NoProfile -File scripts/install-copilot.ps1`
2. Restart VS Code/Copilot.
3. In any repo, ask Copilot to run `vault_index` (or run
   `pwsh -NoProfile -File scripts/index-repo.ps1 <repo-path>` manually).
4. Use `vault_search`, `vault_status`, `vault_inspect`, `vault_hooks`.

Validation checklist:
- [ ] `install-copilot.ps1` reports `installed:true` and shows a
      `settings_path`.
- [ ] In a new repo, Copilot can call `vault_index`/`vault_status`
      without adding repo files.
- [ ] If a repo is unregistered (`code:5`), Copilot offers indexing.
- [ ] Existing Claude `/vault-*` flow still works unchanged.

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
