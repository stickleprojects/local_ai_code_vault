# Stack setup (Phase 1.4)

The `docker compose` stack runs three long-running services — **qdrant**,
**embedder** (llama.cpp on GPU), **api** — plus a one-shot **model-fetch**
that vendors the embedding model. No source code is ever mounted into
these services; the per-repo indexer is separate (see *Indexer network
join* below).

## Prerequisites

- Docker Engine + Compose v2 (`docker compose version` ≥ 2.20).
- **NVIDIA GPU + driver + [NVIDIA Container Toolkit]**, so the embedder
  can use `--gpus`. Verify:
  ```
  docker run --rm --gpus all nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi
  ```
  If that prints your GPU, the stack will too. The B-1 spike ran
  `nomic-embed-code` Q4_K_M (≈4.4 GB) comfortably on a 16 GB RTX 4080.
- ~5 GB free disk for the model volume.

[NVIDIA Container Toolkit]: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html

## Bring it up

```
cp .env.example .env          # adjust if needed
docker compose up -d --build
```

First start downloads the GGUF (~4.4 GB) and **SHA256-verifies** it
before the embedder is allowed to start. The model lives in the
`model_cache` named volume, so subsequent starts skip the download.

## What "healthy" means

```
docker compose ps
```

- `model-fetch` → state `exited (0)` (one-shot; expected).
- `api` → `healthy` (its healthcheck hits `/api/status`).
- `qdrant`, `embedder` → `running`.

`qdrant` and `embedder` carry **no Docker healthcheck**: their base
images ship no shell tooling to run one reliably. The `api` healthcheck
is authoritative because `/api/status` reports Qdrant connectivity, and
the embedder check below confirms the model loaded warm.

## Validate (Phase 1.4 acceptance)

Service-name reachability from inside the stack network:

```
# api → qdrant
docker compose exec api curl -fsS http://qdrant:6333/healthz

# api → embedder: a real embedding. Expect 3584 numbers (B-1 dim).
docker compose exec api curl -fsS http://embedder:8080/v1/embeddings \
  -H 'content-type: application/json' \
  -d '{"model":"nomic-embed-code","input":["def add(a,b): return a+b"]}'

# the API itself
curl -fsS http://localhost:${API_PORT:-8000}/api/status
```

`/api/status` should report `qdrant_connected: true` and
`embed_dim: 3584`.

Persistence across restart:

```
docker compose restart        # or: down (WITHOUT -v) then up -d
docker compose exec api curl -fsS http://localhost:8000/api/repos
```

Named volumes (`qdrant_data`, `model_cache`) survive `restart` and
`down`. **`docker compose down -v` deletes them** (re-downloads the
model, drops all indexes) — only do that to reset deliberately.

## Indexer network join (forward ref — Phase 2)

The ephemeral indexer is not in this compose file. It runs per job and
joins this stack's network by its deterministic name. The compose
project is pinned to `name: vault`, so the network is **`vault_default`**:

```
docker run --rm --network vault_default \
  -v <HOST_REPO_PATH>:/repo:ro \
  <indexer-image> --repo-id <id> \
  --qdrant-url http://qdrant:6333 \
  --embedder-url http://embedder:8080
```

(The Phase 2 host scripts wrap this; shown here so the contract is
documented now.)

## Troubleshooting

- **`MODEL_SHA256` is required / mismatch:** the download didn't match
  the pinned hash. The stack refuses to serve an unverified model. If
  Hugging Face legitimately repackaged the file, verify a trusted copy's
  `sha256sum` and update `MODEL_SHA256` in `.env`.
- **Embedder returns all-zero vectors / wrong dimension:** the
  `--embeddings --pooling last` flags were lost. `--pooling last` is the
  B-1 fix and is mandatory — never remove it from the `embedder.command`.
- **`could not select device driver "nvidia"`:** NVIDIA Container
  Toolkit isn't installed/configured; re-run the `nvidia-smi` check
  above.
- **Embedder slow to first response:** model load is ~10–15 s on GPU;
  the `api` healthcheck `start_period` allows for it.
