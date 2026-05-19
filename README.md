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

## Quick Applicability Map

- **Shared (Claude + Copilot):** stack startup, indexing, search data model,
  and host scripts in `scripts/`.
- **Claude only:** `/vault-*` skill flow and `install-skill.ps1`
  `-PermissionHook` approval-bypass options.
- **Copilot only:** MCP flow via `install-copilot.ps1` and MCP tools
  (`vault_index`, `vault_search`, etc.).

## Usage

**You clone this repo once.** Its `scripts/` and `SKILL.md` are **never
copied into the repos you want to search** — the skill calls the central
scripts by absolute path, and they take the target repo as an argument.

1. **Start the stack:** `cp .env.example .env` then
   `docker compose up -d --build`. Full setup, GPU prerequisites, and
   validation steps: [README_SETUP.md](README_SETUP.md).
2. **Install Claude skill (one-time, from this clone, Claude only):**
   `pwsh -NoProfile -File scripts/install-skill.ps1`, then restart
   Claude Code. This places the skill in `~/.claude/skills/vault/` (so
   `/vault-*` works in _any_ repo) and records `VAULT_HOME` so it can
   find the scripts. Re-run it if you move/update the clone;
   `-Remove` uninstalls.

   > ⚠️ **SECURITY WARNING — read this before using `-PermissionHook
Install`.** By default Claude Code asks you to approve **every**
   > `/vault-*` call. The optional `-PermissionHook Install` writes an
   > auto-allow hook into your **global** `~/.claude/settings.json` so
   > that PowerShell calls to vault scripts **run without asking you**.
   > Everything else still prompts, but this **deliberately disables a
   > safety check**. **If you turn this on, that is your choice and the
   > risk is on you** — anything able to produce a matching command can
   > then run vault scripts unprompted. The installer will **not** do
   > this unless you explicitly opt in (interactive: you must type
   > `yes`; or pass `-PermissionHook Install`); it is fail-closed, backs
   > up `settings.json` first, and never disables your antivirus. The
   > **safe default does nothing** — install the skill, try `/vault-*`
   > with the prompt on, and only enable the bypass later (re-run with
   > `-PermissionHook Install`) if you accept the trade-off.
   > Bitdefender/AMSI note: see
   > [Good antivirus citizen (Claude only)](docs/TROUBLESHOOTING.md#good-antivirus-citizen-claude-only)
   > for exact guidance.
   > `install-skill.ps1 -Remove` removes the hook again. Full trade-off,
   > the exact hook, and undo: [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).
   >
   > If you only use Copilot, skip this step and go to
   > [Copilot global setup](README.md#copilot-global-setup-mcp-no-per-repo-config-copilot-only).

3. **Open the repo you want to search** in Claude Code (any repo,
   anywhere — it does not need this project's files).
4. **Index it:** `/vault-index` (or, by hand from this clone,
   `pwsh -NoProfile -File scripts/index-repo.ps1 <repo-path> -Build -Wait`).
5. **Search:** `/vault-search "<query>"`, or check state with
   `/vault-status`, inspect what's indexed with `/vault-inspect`, view
   estimated savings with `/vault-savings`, and auto-reindex on commit
   with `/vault-hooks`.

The skill is pure delegation; all logic is in standalone, individually
runnable scripts — contracts in [scripts/README.md](scripts/README.md).

## Automatic agent use (typical)

Most users will not type `/vault-*` directly. A more typical flow is:

1. User asks for a code change in plain language.
2. Claude/Copilot uses vault search/index tools behind the scenes to
   gather relevant code context.
3. Agent applies edits and tests with less broad file-searching.

### Example 1: schema/property rename

User prompt:

`change customer.surname to customer.lastname everywhere and fix tests`

Typical agent behavior with vault:

1. Finds model definitions, DTOs, serializers, mappers, API handlers,
   and tests that reference surname semantics.
2. Updates code + tests in targeted files.
3. Returns a normal edit summary.

How savings would be displayed:

- If savings are meaningful, include one line in search-style output:
  `Upper-bound savings this query: 1320 tokens across 3 files (76%).`
- If savings are zero/non-meaningful, omit the line (no noise).

### Example 2: behavior change request

User prompt:

`add retry with exponential backoff to payment API calls and update tests`

Typical agent behavior with vault:

1. Locates existing retry/backoff utilities and payment call sites.
2. Reuses project patterns for error handling/timeouts.
3. Updates integration tests around retry behavior.

How savings would be displayed:

- If the query path returns measurable savings:
  `Upper-bound savings this query: 940 tokens across 2 files (63%).`
- If the agent did not run a vault query (or savings are zero), no
  savings line is shown.

Savings numbers are estimates and upper bounds; details are available
via `/vault-savings` (Claude) or `vault_savings` (Copilot).

## Search safety behavior (shared)

Claude and Copilot now share the same search safety logic through a
single script wrapper (`scripts/query-smart.ps1`):

1. If vault is reachable but the repo is not indexed, the agent prompts
   once with opt-out wording and indexes by default unless you say
   `do not index`.
2. If vault is unavailable, indexing is declined, or semantic search
   returns no hits, the agent falls back to normal workspace file
   search/read flow.
3. In every fallback case, the user is told why vault was not used.

This keeps vault preferred (for token/context efficiency) without
blocking normal coding flow when vault cannot help.

## Shared Claude + Copilot architecture

Claude and Copilot intentionally reuse the same runtime contracts:

- **One script layer (`scripts/*.ps1`)** is the only place where vault
  business logic lives.
- **Claude skill (`SKILL.md`)** delegates `/vault-*` commands to those
  scripts.
- **Copilot MCP adapter (`vault_mcp/vault/server.py`)** delegates MCP tools to
  the same scripts.

This keeps behavior aligned across both clients and avoids duplicated
implementation paths.

## Copilot global setup (MCP, no per-repo config, Copilot only)

Copilot can use the same host scripts via a thin MCP adapter, installed
once at user scope (no repo-local Copilot files required):

1. `pwsh -NoProfile -File scripts/install-copilot.ps1`
2. Restart VS Code/Copilot.
3. In any repo, ask Copilot to run `vault_index` (or run
   `pwsh -NoProfile -File scripts/index-repo.ps1 <repo-path>` manually).
4. Use `vault_search`, `vault_status`, `vault_inspect`, `vault_savings`,
   `vault_hooks`.

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

Phases 1 (stack, indexer, query), 2 (skill + scripts), and 3 (testing,
validation & docs) complete. Phase 4.2 (CHANGELOG + release tagging)
done; 4.1/4.3 (image publishing) deferred — see [plan.md](plan.md).
