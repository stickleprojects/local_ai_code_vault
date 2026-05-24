# Vault host scripts — contracts (Phase 2)

All `/vault-*` logic lives here (AD-4: thin skill, fat scripts). Every
script is runnable **by hand**, independent of the skill. `SKILL.md`
only delegates to these and formats their JSON for the user.

> Every contract below was validated live against a running stack
> before this file was written (Phase 2 sequencing: scripts first,
> docs against frozen behaviour).

## Invocation

```
pwsh -NoProfile -File scripts/<name>.ps1 [PositionalPath] [-Switches]
```

Path arguments accept any path inside the repo; the repo root (and
`repo_id`) is resolved from it. Default path is the current directory.

## I/O contract (uniform)

- **stdout** — exactly one JSON object. On success it includes
  `"ok": true, "code": 0`. On failure it is
  `{"ok": false, "error": "...", "code": N, ...}`. Parse stdout the
  same way regardless of outcome.
- **stderr** — human/diagnostic text and `-Verbose` logging only.
  Never parse stderr.
- **exit code** — mirrors `code` in the JSON. Stable values:

| code | name          | meaning                                               |
| ---- | ------------- | ----------------------------------------------------- |
| 0    | Ok            | success                                               |
| 2    | Usage         | bad/missing arguments                                 |
| 3    | NotGitRepo    | path missing or not inside a git work tree            |
| 4    | StackDown     | vault API unreachable (`docker compose up -d`)        |
| 5    | NotRegistered | repo not registered / not indexed yet                 |
| 6    | Docker        | docker missing, indexer image missing, indexer failed |
| 7    | ApiError      | API reachable but returned a non-2xx                  |

## Environment overrides

| var                   | default                 | used by                                          |
| --------------------- | ----------------------- | ------------------------------------------------ |
| `VAULT_API_BASE`      | `http://localhost:8000` | all API callers                                  |
| `VAULT_NETWORK`       | `vault_default`         | index-repo                                       |
| `VAULT_INDEXER_IMAGE` | `vault-indexer:local`   | index-repo                                       |
| `VAULT_STATS_DIR`     | OS local app-data path  | query, vault-savings                             |
| `VAULT_HOME`          | (set by install-skill)  | the skill, to locate these scripts from any repo |

These scripts are **never copied into the repos you search** — they
live in one clone and take the target repo as `<path>`. The skill finds
them via `VAULT_HOME` (set once by `install-skill.ps1`); the scripts
themselves are cwd-independent (`$PSScriptRoot`).

`vault_default` is the compose network (project pinned `name: vault` in
`docker-compose.yml`). The indexer image is built from
`indexer/Dockerfile`; `index-repo.ps1 -Build` builds it on demand.

## repo_id contract (sacred — single source of truth)

`repo-id.ps1` is the **only** computer of `repo_id`
(`slug(basename(repo_root)) + "-" + sha1(normalized_abs_root)[:8]`,
AD-2). Every other script and `_common.ps1`'s `Get-RepoId` shells out
to it; nothing recomputes it. A subdirectory resolves to the same
`repo_id` as the repo root (git-toplevel resolution).

## Scripts

### `repo-id.ps1 [Path] [-Raw]`

→ `{repo_id, repo_root, normalized_path, slug}` (or bare id with `-Raw`).

### `vault-health.ps1`

→ `{reachable, api_version, embed_model, embed_dim, qdrant_connected}`.
Exit 4 if the stack is down. No repo context needed.

### `vault-status.ps1 [Path]`

→ `{repo_id, registered, indexed_sha, indexed_at, head_sha, stale,
changed_files[]}`. `changed_files` is `null` when undeterminable (e.g.
indexed SHA not in local history), `[]` when not stale.

### `index-repo.ps1 [Path] [-Incremental] [-Wait] [-Build] [-Rebuild]`

Option-B launcher: `docker run` of the indexer image, repo bind-mounted
read-only at `/repo`, joined to `VAULT_NETWORK`. `repo_id` is resolved
here and passed explicitly (never recomputed in the container).

- default (background): `docker run -d` (**not** `--rm`, so the
  container survives for `index-status.ps1`). → `{repo_id, mode,
waited:false, container_id, hint}`.
- `-Wait`: `docker run --rm` attached; indexer logs stream to stderr;
  → `{repo_id, mode, waited:true, exit_code, indexer:{...summary}}`.
- `-Incremental`: reindex only files changed since the indexed SHA
  (via `vault-status.ps1`); if up to date → `{skipped:true, reason}`;
  if not registered → falls back to a full index.
- `-Build`: build the indexer image first **if missing** (no-op when
  one already exists — stale images persist; use `-Rebuild`).
- `-Rebuild`: force `docker build` of the indexer image **even if it
  exists**. Required to pick up `indexer/` code changes; without it an
  old image keeps running silently.

### `index-status.ps1 <ContainerId> [-Keep]`

→ `{container_id, state, exit_code, done}`. Reaps the container once
exited (`-Keep` to retain for `docker logs`). A vanished container is
reported `state:"gone", done:true`.

### `query.ps1 <Query> [Path] [-Limit N]`

→ `{repo_id, query, count, results:[{path,language,start_line,
end_line,score,code}], savings:{...}}`. `savings` is an estimate/upper
bound of context tokens avoided this query. Appends one best-effort JSONL
ledger event per call (stats failures never fail search). 404 → exit 5
(skill offers `/vault-index`). Rendering for the user is the skill's job.

### `query-smart.ps1 <Query> [Path] [-Limit N] [-DoNotIndex] [-Build]`

Shared Claude+Copilot search orchestration wrapper:

- Checks stack reachability first.
- Runs semantic query.
- If unregistered (`code:5`), auto-indexes by default and retries once
  (unless `-DoNotIndex`, which forces fallback).
- If stack is down, indexing is declined, or no semantic hits are
  found, returns a **successful** payload with
  `used_vault:false`, `fallback_reason`, `fallback_message`, and
  `next_action:"workspace_search"` so callers can continue normal file
  search/read flow and explain why vault was not used.

Primary output keeps query-compatible fields:
`{repo_id, query, count, results, savings, used_vault, ...}`.

### `vault-savings.ps1 [Path] [-Days N]`

Aggregates query ledger events for the repo and returns all-time + recent
window estimates:
`{repo_id, stats_file, recorded_queries, corrupt_lines, all_time:{...}, window:{days,...}, basis}`.

### `vault-inspect.ps1 [Path] [-Files] [-Language L] [-Offset N] [-Limit N]`

AD-9 read-only introspection (not search). →
`{repo_id, stats:{indexed_sha,indexed_at,file_count,chunk_count,
skipped_count,languages[]}, files:{...}|null}`. `-Files`/`-Language`
adds the (optionally filtered) inventory.

### `install-git-hooks.ps1 [Path] [-Remove] [-Force]`

Writes LF-newline POSIX `post-commit`/`post-merge` hooks that fire an
**incremental** reindex in the background and `exit 0` immediately — a
commit is never blocked or failed, and if the stack is down the reindex
simply no-ops. Hooks carry a marker so `-Remove` only deletes
vault-managed ones; a pre-existing non-vault hook is left untouched
unless `-Force`. Requires `pwsh` on PATH at commit time.

### `install-skill.ps1 [-SkillsRoot <dir>] [-Remove] [-NoPersist] [-SettingsPath <file>] [-PermissionHook Ask|Install|Skip] [-IgnoreAvBlock] [-RepoHooks Ask|Install|Skip] [-RepoPath <path>]`

One-time setup so `/vault-*` works in **any** repo: copies `SKILL.md`
to `<SkillsRoot>/vault/` (default `~/.claude/skills/vault/`) and records
`VAULT_HOME` = this clone's root (persisted to the Windows User
environment unless `-NoPersist`; on non-Windows it sets the process var
and prints the profile line to add). Re-run after moving/updating the
clone. `-Remove` uninstalls the skill **and** removes the
permission-bypass hook (fail-safe: re-enables the prompt) — backs up
`settings.json` first, drops only the `local_ai_code_vault` PreToolUse
entry, keeps other hooks, leaves an unparseable file untouched; result
adds `permission_hook_removed`, `settings_backup`. Restart Claude Code
afterwards.

`-PermissionHook` controls the per-call approval prompt (Claude Code
otherwise prompts on **every** `/vault-*` call — a deliberate safety
gate). `Install` pre-approves by merging a scoped `PreToolUse` hook
(payload = `scripts/vault-permission-hook.json`) into `-SettingsPath`
(default `~/.claude/settings.json`), backing it up first. **`Skip` is
the explicit "install but DON'T grant the bypass" choice** — test
`/vault-*` with the prompt on, then re-run with `-PermissionHook
Install` later if you accept the trade-off. **Fail-closed:** the prompt
is bypassed only on an explicit grant (this flag, or typing exactly
`yes` at the interactive `Ask` prompt) that writes cleanly; `Ask`
non-interactively, `Skip`, anything other than `yes`, malformed JSON,
or any write error all leave the prompt in place. Result adds
`permission_hook_present` / `_action`
(`installed`/`present`/`skipped`/`failed`/`av-blocked`) / `_error` /
`_hint`, `settings_path`, `settings_backup`. The skill install itself
still succeeds (exit 0) regardless of the hook outcome.

**Good AV citizen:** before writing the hook the installer runs a
non-evasive probe (executes the real hook command once) to see if the
machine's AV/AMSI blocks it. It never disables or circumvents the
antivirus. If blocked it reports `av_blocks_hook` / `av_product` and
`permission_hook_action = av-blocked`, keeps the prompt (asks when
interactive), and points the user at adding their own AV exclusion.
`-IgnoreAvBlock` is the explicit, informed override to install anyway
(the non-interactive equivalent of "install anyway"). See
[../docs/TROUBLESHOOTING.md](../docs/TROUBLESHOOTING.md).

`-RepoHooks` controls whether repo freshness hooks are installed during
skill setup. `Ask` (default) prompts only in interactive runs; in
non-interactive runs it safely skips. `Install` runs
`install-git-hooks.ps1 -Path <RepoPath>` so `post-commit`/`post-merge`
trigger background incremental reindexing. `Skip` leaves hooks
unchanged. Output includes `repo_hooks_action`
(`installed`/`skipped`/`failed`), `repo_hooks_repo_root`,
`repo_hooks_error`, and `repo_hooks_hint`.

### `install-copilot.ps1 [-SettingsPath <file>] [-InstructionsRoot <dir>] [-Remove] [-NoPersist] [-RepoHooks Ask|Install|Skip] [-RepoPath <path>]`

One-time user-scope Copilot setup (no per-repo config): records
`VAULT_HOME`, registers MCP server `vault_mcp/vault/server.py` under VS
Code user settings (`mcp.servers.vault`), installs global instruction
asset (`copilot/instructions/vault-global.instructions.md`), and runs a
post-install `vault-health.ps1` check. `-Remove` unregisters MCP +
instruction entry and deletes the installed instruction file.

This installer does **not** modify Claude permission-bypass settings.
Per-call approval prompts in Claude are controlled only by
`install-skill.ps1 -PermissionHook ...`, where the bypass is explicit,
opt-in, and user-responsibility.

`-RepoHooks` controls whether repo freshness hooks are installed during
Copilot setup. `Ask` (default) prompts only in interactive runs; in
non-interactive runs it safely skips. `Install` runs
`install-git-hooks.ps1 -Path <RepoPath>` so `post-commit`/`post-merge`
trigger background incremental reindexing. `Skip` leaves hooks
unchanged. Output includes `repo_hooks_action`
(`installed`/`skipped`/`failed`), `repo_hooks_repo_root`,
`repo_hooks_error`, and `repo_hooks_hint`.

## Prerequisites

- The stack is up (`docker compose up -d`; see `README_SETUP.md`).
- Docker on PATH; the indexer image built (`index-repo.ps1 -Build`).
- PowerShell 7+ (`pwsh`) and `git` on PATH.
