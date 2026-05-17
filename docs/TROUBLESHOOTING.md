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
