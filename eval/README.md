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

In this CI sandbox, the stack cannot currently reach the model source required by `model-fetch` (`huggingface.co` DNS failure), so a full live baseline run cannot be completed here. Re-run `eval/run-eval.ps1 -UpdateBaseline` in an environment where the vault stack is reachable and commit the resulting baseline.
