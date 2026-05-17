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
2. **Install the skill (one-time, from this clone):**
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

## Documentation

- [docs/SETUP.md](docs/SETUP.md) — zero-to-first-search walkthrough.
- [docs/EXAMPLES.md](docs/EXAMPLES.md) — concrete command + script usage.
- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) — diagnose by exit
  code / symptom.
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — how the parts fit; the
  three sacred contracts.
- [scripts/README.md](scripts/README.md) — script I/O contracts.
- [plan.md](plan.md) — authoritative design (`AD-*`, phases).
- [CHANGELOG.md](CHANGELOG.md) — release history & versioning convention.

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

Phases 1 (stack, indexer, query), 2 (skill + scripts), and 3 (testing,
validation & docs) complete. Phase 4.2 (CHANGELOG + release tagging)
done; 4.1/4.3 (image publishing) deferred — see [plan.md](plan.md).
