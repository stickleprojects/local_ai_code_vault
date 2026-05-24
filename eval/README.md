# Retrieval eval harness

This directory contains the retrieval evaluation harness defined by `EVAL-HARNESS-SPEC.md`.

## Prerequisites

- Vault stack running and reachable (`docker compose up -d` from repo root).
- `pwsh`, `python`, `git`, and `docker` available on PATH.
- `eval/corpus/` and `eval/queries.yaml` are the fixed human-owned fixtures; do not edit them in eval runs.

Confirm stack reachability first:

```powershell
pwsh -NoProfile -File scripts/vault-health.ps1
```

Expected: `{"reachable":true, ...}` with exit code 0.

## Run the eval

From repository root:

```powershell
pwsh -NoProfile -File eval/run-eval.ps1
```

Behavior:

1. Health-checks the vault stack.
2. Indexes `eval/corpus` hermetically (using a temporary standalone git repo when needed).
3. Executes each query case via `scripts/query-smart.ps1`.
4. Computes per-case metrics plus aggregate and per-tag rollups.
5. Writes one JSON object to stdout and a human-readable table to stderr.
6. Gates on:
   - failing `must_pass` cases (excluding `baseline.json` `expected_fail` IDs), and
   - aggregate metric regressions versus `baseline.json` beyond `-Tolerance`.

## Replayable CI path

PR 6 adds a GPU-free replay mode for CI:

- `docker-compose.replay.yml` swaps the live GPU embedder for `eval/embedder-stub/`.
- The stub replays vectors from `eval/vectors.json` by `sha256(input_text)`.
- On any missing key it returns HTTP 503 naming the missing hash; it never invents a vector.
- CI job `eval-replay` skips cleanly until `eval/vectors.json` is committed, then becomes the per-PR replay gate.

## Record `eval/vectors.json` (maintainer / GPU machine)

Record the fixture from one real eval run:

```powershell
pwsh -NoProfile -File eval/record-vectors.ps1
```

What it does:

1. Builds the stub image.
2. Replaces the compose `embedder` service with a recording proxy on `embedder:8080`.
3. Starts the real llama.cpp embedder as `real-embedder` on the same Docker network.
4. Runs `eval/run-eval.ps1` so the recorded keys exactly match the live path.
5. Writes `eval/vectors.json`.

Commit `eval/vectors.json` only after reviewing the run output.

## Re-baseline

To regenerate baseline from the current implementation:

```powershell
pwsh -NoProfile -File eval/run-eval.ps1 -UpdateBaseline
```

Optional tolerance example:

```powershell
pwsh -NoProfile -File eval/run-eval.ps1 -Tolerance 0.01 -UpdateBaseline
```

Commit `eval/baseline.json` only after human review.

## Known current defects

The current vault is expected to fail definition-oriented retrieval cases until later quality PRs land:

- `definition-fixture`
- `definition-above-callsite`

Additional currently-tracked expected failures in baseline:

- `noise-guard-init`
- `symbol-completeness` (until symbol mode support is available in query orchestration)

`semantic-anchor` is the non-regression sentinel and should remain passing.

## Sandbox note for this branch

The agent sandbox still cannot run the live GPU stack, so the maintainer-owned recorder step remains required for `eval/vectors.json`. Once that file is committed, `eval-replay` exercises the harness in CI without GPU/model download.
