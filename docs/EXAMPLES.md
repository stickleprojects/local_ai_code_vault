# Examples

Concrete walkthroughs. Each `/vault-*` skill command maps 1:1 to a
script you can also run by hand from the vault clone — both shown.
Full contracts: [../scripts/README.md](../scripts/README.md).

By-hand pattern (the skill does this via `$env:VAULT_HOME`):

```
pwsh -NoProfile -File scripts/<name>.ps1 [PositionalPath] [-Switches]
```

`PositionalPath` is any path inside the target repo (default: current
directory); the repo root and `repo_id` are resolved from it.

## Check the stack

```
/vault-status
```
```
pwsh -NoProfile -File scripts/vault-health.ps1
# → {"ok":true,"code":0,"reachable":true,"api_version":"...",
#    "embed_model":"nomic-embed-code","embed_dim":3584,
#    "qdrant_connected":true}
```

## First index of a repo

Small repo, wait for completion:

```
pwsh -NoProfile -File scripts/index-repo.ps1 C:\code\myapp -Build -Wait
# → {"ok":true,"code":0,"repo_id":"myapp-1a2b3c4d","mode":"full",
#    "waited":true,"exit_code":0,
#    "indexer":{"files":42,"chunks":318,"skipped":7}}
```

Large repo, background (default) — then poll:

```
pwsh -NoProfile -File scripts/index-repo.ps1 C:\code\bigrepo
# → {"ok":true,"repo_id":"bigrepo-9f8e7d6c","mode":"full",
#    "waited":false,"container_id":"a1b2c3...","hint":"poll index-status"}

pwsh -NoProfile -File scripts/index-status.ps1 a1b2c3
# → {"ok":true,"container_id":"a1b2c3","state":"running","done":false}
# ...repeat until:
# → {"ok":true,"state":"exited","exit_code":0,"done":true}
```

Via the skill, `/vault-index` polls automatically and reports
completion in-session.

## Search

```
/vault-search "where is the JWT verified"
```
```
pwsh -NoProfile -File scripts/query.ps1 "where is the JWT verified" C:\code\myapp -Limit 5
# → {"ok":true,"repo_id":"myapp-1a2b3c4d","query":"...","count":5,
#    "results":[{"path":"src/auth/jwt.cs","language":"csharp",
#                "start_line":40,"end_line":71,"score":0.62,
#                "code":"public bool VerifyToken(...) { ... }"}, ...]}
```
A 404 (repo not indexed) → exit 5; the skill offers `/vault-index`.

## Inspect what's indexed (read-only, AD-9)

```
/vault-inspect
```
```
pwsh -NoProfile -File scripts/vault-inspect.ps1 C:\code\myapp
# → {"ok":true,"repo_id":"myapp-1a2b3c4d",
#    "stats":{"indexed_sha":"abc123","indexed_at":"2026-05-17T...",
#             "file_count":42,"chunk_count":318,"skipped_count":7,
#             "languages":[{"language":"csharp","files":30}, ...]},
#    "files":null}

# Add the inventory, filtered to one language, paged:
pwsh -NoProfile -File scripts/vault-inspect.ps1 C:\code\myapp -Files -Language python -Offset 0 -Limit 50
```

## Keep it fresh — incremental + git hooks

After commits, reindex only changed files:

```
pwsh -NoProfile -File scripts/index-repo.ps1 C:\code\myapp -Incremental
# up to date → {"ok":true,"skipped":true,"reason":"index current"}
```

Automate it (non-blocking `post-commit`/`post-merge` hooks):

```
/vault-hooks
pwsh -NoProfile -File scripts/install-git-hooks.ps1 C:\code\myapp
# remove only vault-managed hooks:
pwsh -NoProfile -File scripts/install-git-hooks.ps1 C:\code\myapp -Remove
```
Hooks fire an incremental reindex in the background and `exit 0`
immediately — a commit is never blocked, and a down stack just no-ops.

## Multiple repos

`repo_id` is derived from the normalized absolute repo root, so each
repo is isolated automatically (one Qdrant collection per `repo_id`).
Just run the same commands from inside each repo — no per-repo config,
nothing copied into them.
