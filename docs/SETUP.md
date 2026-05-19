# Setup — zero to first search

End-to-end path. The GPU/stack specifics are not duplicated here —
[README_SETUP.md](../README_SETUP.md) is authoritative for the Docker
stack; this stitches the whole flow together.

## Prerequisites

- Docker Engine + Compose v2 (`docker compose version` ≥ 2.20).
- **NVIDIA GPU + driver + NVIDIA Container Toolkit** (the embedder needs
  `--gpus`). Verify with the `nvidia-smi` container check in
  [README_SETUP.md](../README_SETUP.md#prerequisites).
- **PowerShell 7+ (`pwsh`)** and **`git`** on `PATH`.
- ~5 GB free disk for the model volume.

## 1. Clone once

You clone **this** repo once. Its `scripts/` and `SKILL.md` are *never*
copied into the repos you want to search — the skill calls the central
scripts by absolute path and passes the target repo as an argument.

## 2. Start the stack

```
cp .env.example .env          # adjust if needed
docker compose up -d --build
```

First start downloads the GGUF (~4.4 GB) and SHA256-verifies it before
the embedder starts. Confirm healthy (see
[README_SETUP.md](../README_SETUP.md#what-healthy-means)):

```
docker compose ps                       # api healthy; model-fetch exited(0)
curl -fsS http://localhost:8000/api/status   # qdrant_connected:true, embed_dim:3584
```

## 3. Install the skill (one-time)

From this clone:

```
pwsh -NoProfile -File scripts/install-skill.ps1
```

Then **restart Claude Code**. This copies `SKILL.md` to
`~/.claude/skills/vault/` (so `/vault-*` works in any repo) and records
`VAULT_HOME` = this clone's root so the skill can locate the scripts.
Re-run after moving/updating the clone; `-Remove` uninstalls.

### Optional: disable the per-call approval prompt (your call, your risk)

> ⚠️ Out of the box Claude Code prompts you to approve **every**
> `/vault-*` call. That prompt is a safety check. You can turn it off
> for vault scripts — but **this deliberately weakens that check, and
> if you enable it the risk is on you.**

**The safe default:** just install the skill (step above) and use
`/vault-*` with the prompt on. **Nothing touches `settings.json`
unless you explicitly opt in.** Try it this way for as long as you
like first.

**To disable the prompt later, when/if you accept the trade-off**, opt
in explicitly:

```
pwsh -NoProfile -File scripts/install-skill.ps1 -PermissionHook Install
```

(or run the installer interactively and **type `yes`** at the security
prompt; `-PermissionHook Skip` is the explicit "install but do **not**
grant the bypass" choice.)

**What it changes:** it writes a scoped `PreToolUse` hook into your
**global** `~/.claude/settings.json` that **auto-approves (no prompt)**
PowerShell calls which invoke a script under a
`local_ai_code_vault/scripts/` directory. Every other command still
prompts as normal.

- **Benefit:** no approval prompt on each `/vault-*` call.
- **Risk (on you):** an intentional reduction of the human-in-the-loop
  approval gate for that command class. Anything that can produce a
  matching command then runs vault scripts without asking you.
- **Safeguards:** opt-in (explicit `yes`/flag only — the default does
  nothing); fail-closed (a non-interactive run, `Skip`, anything other
  than `yes`, malformed JSON, or any write error keeps the prompt); a
  timestamped `.bak` is written first; a non-evasive antivirus probe
  runs before writing and never disables/evades your AV.
- **Reversible:** `pwsh -NoProfile -File scripts/install-skill.ps1
  -Remove` removes the hook again (backs up first, keeps your other
  hooks). Or restore the `.bak`, or delete the `PreToolUse` entry whose
  command contains `local_ai_code_vault`. Restart Claude Code after.

Full detail, the exact hook, AV guidance, and the manual-paste
alternative: [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## 4. Build the indexer image

Built on demand by `index-repo.ps1 -Build` (first index below), or
explicitly once:

```
pwsh -NoProfile -File scripts/index-repo.ps1 <repo-path> -Build -Wait
```

## 5. Index and search a repo

Open the repo you want to search in Claude Code (any repo, anywhere —
it does not need this project's files), then:

- `/vault-index` — index it (background; `-Wait` for small repos).
- `/vault-status` — registered / stale?
- `/vault-search "<query>"` — semantic search.
- `/vault-inspect` — what's indexed (counts, languages, skipped).
- `/vault-hooks` — auto-reindex on commit.

Equivalent by-hand invocations and sample output:
[EXAMPLES.md](EXAMPLES.md). If anything fails:
[TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## Environment overrides (rarely needed)

| var | default | used by |
|---|---|---|
| `VAULT_API_BASE` | `http://localhost:8000` | all API callers |
| `VAULT_NETWORK` | `vault_default` | `index-repo.ps1` |
| `VAULT_INDEXER_IMAGE` | `vault-indexer:local` | `index-repo.ps1` |
| `VAULT_HOME` | set by `install-skill.ps1` | skill, to find scripts |
