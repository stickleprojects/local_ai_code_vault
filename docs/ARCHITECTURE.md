# Architecture

A readable synthesis of the system. **`plan.md` is authoritative** for
architecture decisions (`AD-*`), the resolved B-1 embedding blocker, and
phase sequencing — read it for the *why*. This page is the *what* and
*how it fits together*.

## One sentence

Instead of Claude reading source files directly, it queries a local
vector store; a long-running Docker stack serves search, an ephemeral
container indexes one repo at a time, and PowerShell host scripts + a
thin Claude skill drive both.

## Components

| Part | Lives in | Role |
|---|---|---|
| **API service** | `src/` (FastAPI) | Serves search/inspection. `app.py` wires routes; `query_handler.py` is semantic search; `inspection.py` is AD-9 read-only introspection; `registry.py` reads the implicit repo registry; `models.py` is the **single source of truth** for the embedding contract. |
| **Indexer** | `indexer/` | Standalone per-job image (`docker run`). `chunker.py` (tree-sitter: C#/Py/JS/TS), `embedder.py`, `qdrant_writer.py`, `index.py` (CLI). *Producer* of the registry that `src/` reads. |
| **Stack** | `docker-compose.yml` | `qdrant` + `embedder` (llama.cpp `server-cuda`, GPU) + `api`, plus one-shot SHA256-pinned `model-fetch`. Project pinned `name: vault` ⇒ network **`vault_default`**. |
| **Host scripts** | `scripts/*.ps1` | AD-4 "thin skill, fat scripts": all logic, runnable by hand, uniform JSON/exit-code contract (`scripts/README.md`). |
| **Skill** | `SKILL.md` | Pure delegation: picks a script, runs it, formats its JSON. No logic. |

## Data flow

```
Index:  repo ──(scripts/index-repo.ps1)──▶ ephemeral indexer container
          bind-mounts repo :ro at /repo, joins vault_default
          tree-sitter chunk → embed (code, raw) → write to Qdrant → exit

Search: /vault-search ──(scripts/query.ps1)──▶ api :8000
          embed query (prefixed) → Qdrant cosine search → ranked chunks
```

No long-running service ever mounts source. Source is visible **only**
during the short-lived indexer run.

## The three sacred contracts

Breaking any of these silently corrupts results — they are treated like
production invariants.

1. **`repo_id` (AD-2)** — computed by **exactly one** place,
   `scripts/repo-id.ps1`
   (`slug(basename(root)) + "-" + sha1(normalized_abs_root)[:8]`).
   Everything else shells out to it; nothing recomputes it. A
   subdirectory resolves to the same `repo_id` as the repo root.
2. **Embedding (AD-7 / B-1)** — `nomic-embed-code`, dim **3584**,
   cosine. The dimension constant lives **only** in `src/models.py`.
   Changing the model ⇒ drop + re-index everything.
3. **Prompt-prefix asymmetry (AD-10)** — queries are prefixed
   (`Represent this query for searching relevant code: `); code chunks
   get **no** prefix. Indexer embeds code raw; the query path prefixes.
   One helper per side; a mismatch silently degrades retrieval.

## Layering rule

`src/` must **not** import from `indexer/`. The indexer depends on
`src/` (it reuses the `src/models.py` embedding contract), not the
reverse. A round-trip test locks the registry payload contract between
the two.

## Why these shapes

- **Ephemeral indexer (AD-2/AD-3):** no fixed `/repos` mount, repos can
  live anywhere, no Docker socket exposed to the skill (Option B: Claude
  already runs on the host with shell + Docker).
- **Thin skill / fat scripts (AD-4):** every behaviour is debuggable by
  hand with stable exit codes; the skill can't drift from the logic.
- **Freshness by commit SHA (AD-6):** staleness = `indexed_sha !=
  git rev-parse HEAD`, enabling incremental reindex via
  `git diff --name-only`.

See also: [SETUP.md](SETUP.md) · [EXAMPLES.md](EXAMPLES.md) ·
[TROUBLESHOOTING.md](TROUBLESHOOTING.md) ·
[../scripts/README.md](../scripts/README.md) (script contracts) ·
[../plan.md](../plan.md) (authoritative design).
