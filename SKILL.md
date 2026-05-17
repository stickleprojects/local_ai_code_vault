---
name: vault
description: >-
  Semantic code search over the local AI code vault. Use when the user
  invokes /vault-status, /vault-index, /vault-search, /vault-inspect, or
  /vault-hooks, or asks to index / semantically search / check indexing
  status of the current repository against the local vault stack.
---

# Vault skill (thin delegation — AD-4)

**All logic lives in the vault scripts.** This skill ONLY: picks the
script for the command, runs it, parses its stdout JSON, and reports.
Do not reimplement script behaviour, recompute `repo_id`, or call the
API/Docker directly — always go through the scripts.

The scripts live in **one** clone of the vault repo, not in the user's
project. Invoke them by absolute path via `$env:VAULT_HOME` (set once by
`scripts/install-skill.ps1`), passing the user's current repo as the
path argument:

```
pwsh -NoProfile -File "$env:VAULT_HOME/scripts/<name>.ps1" <repo-path> [-Switches]
```

`<repo-path>` is the directory the user is working in (use `.` if you
are already there). If `$env:VAULT_HOME` is unset, tell the user to run
`pwsh -NoProfile -File scripts/install-skill.ps1` from their vault clone
and restart Claude Code.

Every script prints **one JSON object** on stdout (`ok`, `code`, plus
fields) and uses stable exit codes. Parse stdout regardless of success.
Full contracts: `$env:VAULT_HOME/scripts/README.md`.

## Resolving the subcommand (read this first)

This is **one** skill named `vault`; `status`/`index`/`search`/
`inspect`/`hooks` are subcommands, not separate skills. The harness may
hand you the invocation as bare `/vault` with the rest in arguments, so
**determine the subcommand from the user's literal message**, not from
the skill name alone.

- Take the first of these keywords that appears in the user's input —
  `index`, `status`, `search`, `inspect`, `hooks` — whether written
  `/vault-index`, `/vault index`, `vault-index`, or as natural language
  ("index this repo with vault"). A leading `-` (e.g. `-index`) is part
  of the subcommand token; strip it. That keyword selects the row in
  **Commands** below.
- For `search`, everything after the keyword is the query string.
- **Never** reply "you ran /vault with no subcommand" when any of those
  keywords is present — that is the bug this section exists to prevent.
  Treat it as "no subcommand" only when genuinely none is present *and*
  there is no clear intent; then ask which one (single question), don't
  re-loop the same prompt.
- Once resolved, act immediately per that row — in particular `index`
  runs right away (it is the user's explicit request; no confirmation).

## Commands

| Command | Script | Then |
|---|---|---|
| `/vault-status` | `vault-health.ps1`, then `vault-status.ps1 <path>` | Report reachable/registered/stale; if `stale`, say which/how many files changed and offer `/vault-index -Incremental`; if not registered, offer `/vault-index`. |
| `/vault-index` | `index-repo.ps1 <path> [-Incremental] [-Wait] [-Build]` | **Run immediately — the explicit `/vault-index` invocation is the user's consent. Do NOT ask "want me to index?" and do NOT gate on a prior `/vault-status` check; indexing is non-destructive.** Default background: report `container_id`, then poll `index-status.ps1 <id>` as a tracked task and report completion in-session. `-Wait` for small repos. |
| `/vault-search <query>` | `query.ps1 "<query>" <path> [-Limit N]` | Format `results[]` as a readable list (path, line range, score, code). |
| `/vault-inspect` | `vault-inspect.ps1 <path> [-Files] [-Language L]` | Summarise `stats` (counts, per-language, skipped); list inventory only if `-Files` was asked for. |
| `/vault-hooks` | `install-git-hooks.ps1 <path> [-Remove]` | Confirm install/removal; explain hooks auto-reindex on commit/merge, non-blocking. |

Each script name above is invoked as `$env:VAULT_HOME/scripts/<name>`
per the pattern at the top; `<path>` is the user's repo.

## Handling outcomes (surface, don't reimplement)

The scripts already produce actionable messages and consistent exit
codes. Read `code` from the JSON and act:

- `0` — success. Format the result for the user.
- `4` StackDown — the stack isn't up. Tell the user to run
  `docker compose up -d` (see `README_SETUP.md`); don't retry blindly.
- `5` NotRegistered — offer to run `/vault-index`.
- `3` NotGitRepo — explain the command must run inside a git repo.
- `6` Docker — surface the script's message (often: build the indexer
  image with `index-repo.ps1 -Build`, or `docker logs` the container).
- `2` / `7` — show the error; it states what to fix.

For `/vault-status`, always run `vault-health.ps1` first — if the stack
is down, stop there with the restart guidance rather than reporting a
misleading "not registered".

## Notes

- An explicit `/vault-*` command is itself the user's consent: act on
  it directly, don't ask a yes/no confirmation first. "Offer
  `/vault-index`" applies only to *other* commands hitting an
  unregistered repo (`/vault-status`, or `code 5` from search) — never
  to `/vault-index` itself.
- `repo_id` is derived solely by `repo-id.ps1`; treat it as opaque.
- `/vault-index` background jobs: poll `index-status.ps1` until
  `done:true`; completion is reported only within the open session
  (documented limitation — no detached OS notification).
- This skill performs no destructive action except `/vault-hooks
  -Remove` (removes only vault-managed hooks).
