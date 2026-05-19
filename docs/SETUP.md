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

### Optional: stop the per-call approval prompt (security trade-off)

Out of the box Claude Code prompts for approval on **every** `/vault-*`
call. You can pre-approve by adding `-PermissionHook Install`:

```
pwsh -NoProfile -File scripts/install-skill.ps1 -PermissionHook Install
```

**What it changes:** it writes a scoped `PreToolUse` hook into your
**global** `~/.claude/settings.json` that **auto-approves (no prompt)**
PowerShell calls which invoke a script under a
`local_ai_code_vault/scripts/` directory. Every other command still
prompts as normal.

- **Benefit:** no approval prompt on each `/vault-*` call.
- **Risk:** this is an intentional, narrowly-scoped relaxation of the
  human-in-the-loop approval gate for that one command class. Anything
  that can write a matching command could run vault scripts without a
  prompt.
- **Safeguards:** opt-in (the default does nothing to settings.json);
  fail-closed (a non-interactive run, `Skip`, a `no`, malformed JSON,
  or any write error keeps the prompt); a timestamped `.bak` is written
  first; a non-evasive antivirus probe runs before writing and never
  disables/evades your AV.
- **Reversible:** restore the `.bak`, or delete the `PreToolUse` entry
  whose command contains `local_ai_code_vault`, then restart Claude
  Code.

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
