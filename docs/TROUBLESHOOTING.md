# Troubleshooting

Every script prints **one JSON object** on stdout (`ok`, `code`, plus
fields) and exits with a code mirroring `code`. Diagnose by `code`
first, then by surface. Stack-level (model/GPU) issues are covered in
[README_SETUP.md](../README_SETUP.md#troubleshooting) — not duplicated
here.

## By exit code

| code | name | What it means → do this |
|---|---|---|
| 0 | Ok | success |
| 2 | Usage | bad/missing arguments — the `error` field states what to fix |
| 3 | NotGitRepo | path missing or not inside a git work tree — run from inside a repo, or `git init` |
| 4 | StackDown | vault API unreachable — `docker compose up -d` (see [SETUP.md](SETUP.md)); don't retry blindly |
| 5 | NotRegistered | repo not indexed yet — run `/vault-index` (or `index-repo.ps1`) |
| 6 | Docker | docker missing / indexer image missing / indexer failed — see below |
| 7 | ApiError | API reachable but returned non-2xx — surface the `error`; check `docker compose logs api` |

## Common symptoms

**`/vault-*` says the skill can't find scripts / `VAULT_HOME` unset.**
Run `pwsh -NoProfile -File scripts/install-skill.ps1` from your vault
clone and **restart Claude Code**. `install-skill.ps1` persists
`VAULT_HOME` to the Windows User environment; a shell opened before that
won't see it.

**Claude Code prompts for approval on every `/vault-*` call.** The
PowerShell-tool permission matcher works on the parsed AST, so a
`permissions.allow` rule like `PowerShell(& "...\scripts/*)` never
matches and cannot suppress the prompt. The fix is a **scoped
`PreToolUse` hook** in your **user** settings
`~/.claude/settings.json` (user-level, not the project's
`.claude/settings.json` — the skill runs from *other* repos). This is
a **one-time, global** step; it is not per-repo.

**Easiest:** let the installer pre-approve it (explicit grant only):

```
pwsh -NoProfile -File scripts/install-skill.ps1 -PermissionHook Install
```

This is **fail-closed**: it writes the hook only on an explicit grant
(that flag, or typing exactly `yes` at the interactive prompt) and backs up
`settings.json` first. A non-interactive run, a `no`, a malformed
`settings.json`, or any write error leaves the prompt **in place**
(`permission_hook_action` = `skipped`/`failed`) — the security is never
bypassed by accident. Restart Claude Code afterwards (hooks load at
session start).

**Good antivirus citizen.** Some AV products (e.g. Bitdefender, or
Defender via AMSI) flag the auto-allow hook. We deal with this
*honestly and without ever weakening your antivirus*:

- The hook command is kept in a **data file**
  (`scripts/vault-permission-hook.json`), never inlined into a `.ps1`,
  so the installer itself doesn't resemble a "config-writing dropper".
- Before writing the hook the installer runs a **non-evasive probe**:
  it executes the real hook command once and checks whether your
  AV/AMSI lets it run. It does **not** disable, suppress, or circumvent
  the antivirus.
- If the probe is blocked, the installer reports
  `permission_hook_action = av-blocked`, names the product
  (`av_product`), and **keeps the per-call prompt** (fail-closed).
  Interactively it asks; non-interactively it declines.

The sanctioned fix is for **you** to allowlist it in your AV (we never
do this for you). In Bitdefender: *Protection → Antivirus → Settings →
Manage exceptions → Add an exception* for your vault clone's `scripts`
folder and for `~/.claude/settings.json` (and, if AMSI-scanned,
re-allow the blocked item from *Notifications*). Then re-run
`-PermissionHook Install`. To proceed despite the block (you accept it
may be quarantined until you add the exception), pass the explicit
override:

```
pwsh -NoProfile -File scripts/install-skill.ps1 -PermissionHook Install -IgnoreAvBlock
```

**Or merge it by hand** into `~/.claude/settings.json` and **restart
Claude Code**:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "PowerShell",
        "hooks": [
          {
            "type": "command",
            "shell": "powershell",
            "command": "$j=[Console]::In.ReadToEnd()|ConvertFrom-Json;$c=[string]$j.tool_input.command;if($c -match '^\\s*&\\s+\"[^\"]*local_ai_code_vault[\\\\/]+scripts[\\\\/]'){@{hookSpecificOutput=@{hookEventName='PreToolUse';permissionDecision='allow';permissionDecisionReason='Vault skill script (scoped auto-allow)'}}|ConvertTo-Json -Compress -Depth 5}",
            "timeout": 15,
            "statusMessage": "Vault: auto-allowing scoped skill script"
          }
        ]
      }
    ]
  }
}
```

It auto-allows **only** a call-operator invocation of a script inside
a `local_ai_code_vault/scripts/` directory; every other PowerShell
command stays gated. If your clone directory is not named
`local_ai_code_vault`, widen the regex accordingly.

**Risk vs benefit (decide before you install it).** Benefit: no
approval prompt on every `/vault-*` call. Cost: this is an
intentional, narrowly-scoped relaxation of Claude Code's
human-in-the-loop approval gate — anything able to produce a command
matching that regex runs vault scripts with no prompt. The scope is a
single command shape (call-operator invocation of a script under
`…/local_ai_code_vault/scripts/`); nothing else is auto-approved. The
installer is opt-in, fail-closed, backs up `settings.json`, and
probes your AV first (it never disables or evades it). If you are not
comfortable with that trade-off, **don't install the hook** — keep
clicking approve, or paste a manually narrowed variant.

**Decline now, enable later.** You do **not** have to decide at install
time. Install the skill with the prompt left on — `-PermissionHook
Skip` (or just answer anything other than `yes` at the interactive
prompt, or run non-interactively). Nothing in `settings.json` is
touched. Use `/vault-*` like that for as long as you want; when (if)
you decide to accept the trade-off, enable the bypass any time by
re-running:

```
pwsh -NoProfile -File scripts/install-skill.ps1 -PermissionHook Install
```

**Undo / remove the permission hook.** `install-skill.ps1 -Remove`
uninstalls the *skill* **and removes the pre-approval hook** (fail-safe
— this re-enables the prompt). It backs up `settings.json` first,
drops only the `hooks.PreToolUse` entry whose `command` contains
`local_ai_code_vault`, and leaves every other hook intact; an
unparseable `settings.json` is left untouched (remove the entry by
hand). You can also revert manually: restore the timestamped
`~/.claude/settings.json.bak-<timestamp>` (its path is reported as
`settings_backup`), or delete that one `PreToolUse` entry yourself.
Restart Claude Code; the per-call prompt returns immediately.

**code 4 but `docker compose ps` looks up.** The API healthcheck is
authoritative — check `curl -fsS http://localhost:8000/api/status`. If
it reports `qdrant_connected:false`, Qdrant isn't reachable from the
api container; restart the stack. Custom port/host? Set `VAULT_API_BASE`.

**code 6 — "indexer image missing".** Build it:
`pwsh -NoProfile -File scripts/index-repo.ps1 <path> -Build`. It builds
`vault-indexer:local` from `indexer/Dockerfile`.

**code 6 — indexer ran but failed.** A background index uses
`docker run -d` (survives for inspection). Get the container id from the
`index-repo.ps1` JSON and `docker logs <id>`. `index-status.ps1 <id>
-Keep` reports state without reaping the container.

**Search returns 404 / code 5 right after indexing.** A background
index isn't instant. Poll `index-status.ps1 <container_id>` until
`done:true`, then search. Use `/vault-index -Wait` for small repos.

**`/vault-status` says `stale`.** The indexed SHA ≠ current `HEAD`.
Re-index changed files only: `/vault-index -Incremental` (falls back to
a full index if the repo isn't registered). `changed_files` is `null`
when the indexed SHA isn't in local history (e.g. after a force-push) —
do a full `/vault-index`.

**Embedder all-zero vectors / wrong dimension, GPU driver errors,
`MODEL_SHA256` mismatch, slow first response.** Stack-level — see
[README_SETUP.md](../README_SETUP.md#troubleshooting). The
`--embeddings --pooling last` flags are the B-1 fix and are mandatory.

**Files missing from results.** Only C#, Python, JavaScript, TypeScript
are indexed (AD-8). Other languages are **skipped, not errored**, and
counted in `skipped_count` — check `/vault-inspect`.

**Git hook didn't reindex on commit.** Hooks require `pwsh` on `PATH`
at commit time and are intentionally non-blocking: if the stack is down
the reindex silently no-ops (a commit is never failed). Re-check with
`/vault-status`; reinstall with `/vault-hooks` (`-Force` to overwrite a
pre-existing non-vault hook).

## Escalation

- API behaviour: `docker compose logs api`.
- Indexer behaviour: `docker logs <container_id>` (background runs are
  not `--rm`).
- Script behaviour: re-run the script by hand with `-Verbose` (stderr
  carries diagnostics; stdout stays pure JSON).
