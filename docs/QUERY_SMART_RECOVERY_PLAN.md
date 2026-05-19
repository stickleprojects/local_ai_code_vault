# Query Smart Failure: Diagnosis and Recovery Plan

## Executive Summary

The shared wrapper script in [scripts/query-smart.ps1](../scripts/query-smart.ps1) is intended to always return exit code 0 with a structured fallback payload for non-fatal search paths.

Current behavior in tests and local repro is that some valid control-flow paths exit with code 1 instead. This blocks the intended Claude and Copilot fallback behavior.

Companion docs for overnight execution:

- [docs/OVERNIGHT_AGENT_PROMPT.md](OVERNIGHT_AGENT_PROMPT.md)
- [docs/RUN_OVERNIGHT_AGENT.md](RUN_OVERNIGHT_AGENT.md)

The likely causes are now narrowed to two concrete PowerShell issues:

1. Child-script invocation argument binding problems when passing named parameters via array splatting.
2. Strict-mode property access failures when JSON is returned as hashtables instead of objects.

## What Is Failing

From [tests/scripts.Tests.ps1](../tests/scripts.Tests.ps1), these query-smart cases are expected to return code 0 but currently return code 1:

- indexing declined path with DoNotIndex
- zero semantic hits path
- successful semantic hit path

These are all non-error product paths and should never hard-fail.

## Confirmed Findings So Far

1. A direct repro of query-smart against a stub API produced code 1 with this failure class:
   - positional parameter binding error passed into child scripts.
2. After adjusting invocation style, a second repro produced code 1 with this failure class:
   - strict-mode property lookup failures such as missing results on body objects.
3. [scripts/vault-health.ps1](../scripts/vault-health.ps1) was already hardened for object-or-hashtable body shape.
4. Equivalent hardening is still needed in [scripts/query.ps1](../scripts/query.ps1), which currently assumes object-style property access for response body and result items.

## Root Cause Hypothesis

There is an inconsistent JSON shape contract across scripts:

- Some code assumes ConvertFrom-Json returns objects.
- Some call paths currently receive hashtables.
- Under strict mode, direct property access against the wrong shape throws and exits 1.

In parallel, argument passing into child scripts can silently break if invocation mechanics are not explicit about named parameters.

Together these create brittle behavior in wrapper orchestration despite otherwise valid API responses.

## Overnight Execution Plan

### Phase 1: Lock Down Repro and Signal (30-45 min)

Goal: make failures fast and observable.

Tasks:

1. Add temporary diagnostic output in [scripts/query-smart.ps1](../scripts/query-smart.ps1) under a switch like VerboseChildErrors.
2. In Invoke-JsonScript, capture stderr text into the returned object when code is non-zero.
3. Ensure diagnostics are opt-in so normal output contract remains unchanged.

Acceptance criteria:

- One command run shows exact child error text for each failing scenario.
- Normal JSON output shape is unchanged when diagnostics are off.

### Phase 2: Normalize JSON Access (45-60 min)

Goal: remove object-vs-hashtable fragility.

Tasks:

1. Add a shared helper in [scripts/\_common.ps1](../scripts/_common.ps1), for example Get-VaultBodyValue, that safely reads by key from either hashtable or object.
2. Refactor [scripts/query.ps1](../scripts/query.ps1) to use helper for:
   - top-level response keys like results
   - per-hit keys like code and path
3. Keep output payload contract exactly the same.

Acceptance criteria:

- query.ps1 succeeds with both object-shaped and hashtable-shaped response bodies.
- No regression in savings calculation fields.

### Phase 3: Validate Child Invocation Contract (30 min)

Goal: ensure child scripts always receive parameters as intended.

Tasks:

1. Keep named hashtable splatting in [scripts/query-smart.ps1](../scripts/query-smart.ps1) for query and index calls.
2. Add tests proving the wrapper sends Path and Limit correctly to query script.
3. Add one negative test where query fails and wrapper still returns fallback payload code 0.

Acceptance criteria:

- No positional binding errors from child scripts.
- Wrapper behavior is deterministic for all branches.

### Phase 4: Test Matrix and Regression Guardrails (45-60 min)

Goal: make this class of bug hard to reintroduce.

Tasks:

1. Extend [tests/scripts.Tests.ps1](../tests/scripts.Tests.ps1) with shape-variant cases:
   - status endpoint body as object
   - status endpoint body as hashtable-equivalent JSON
   - query results as object entries and hashtable-equivalent entries
2. Keep existing 3 failing tests as required gating tests.
3. Add at least one test for fallback payload keys:
   - used_vault
   - fallback_reason
   - next_action

Acceptance criteria:

- Full Pester scripts suite passes.
- Existing MCP server tests continue to pass.

### Phase 5: Final Verification and Commit Hygiene (20-30 min)

Goal: land a clean, reviewable fix.

Tasks:

1. Run:
   - pwsh -NoProfile -Command "Invoke-Pester tests/scripts.Tests.ps1 -Output Detailed"
   - python -m pytest -q tests/test_mcp_vault_server.py
2. Verify docs and instruction files still align with shared wrapper behavior:
   - [SKILL.md](../SKILL.md)
   - [copilot/instructions/vault-global.instructions.md](../copilot/instructions/vault-global.instructions.md)
3. Commit with a message focused on wrapper reliability and JSON-shape hardening.

Acceptance criteria:

- Green test run for both commands.
- No contract drift in wrapper output fields.

## Task List for Overnight Agents

1. Implement shared safe body accessor in \_common and migrate query script usage.
2. Keep query-smart child invocation explicit with named arguments.
3. Add opt-in diagnostics in query-smart for future triage.
4. Add shape-variant tests and fallback contract tests.
5. Run test matrix and post exact pass counts in final summary.

## Non-Negotiable Output Contract

query-smart must always emit JSON with code 0 for non-fatal fallback cases. Required fields:

- used_vault
- fallback_reason
- fallback_message
- next_action
- count
- results
- savings

This is the integration contract consumed by both Claude and Copilot flows.

## Rollback Safety

If unexpected regressions appear:

1. Keep query-smart fallback behavior intact first.
2. Temporarily disable optional diagnostics before final merge.
3. Avoid touching repo_id logic and embedding constants.

## Definition of Done

Done means all of the following are true:

1. The three query-smart failures in scripts.Tests.ps1 are green.
2. test_mcp_vault_server.py remains green.
3. query-smart returns code 0 and proper fallback payload for:
   - stack unavailable
   - indexing declined
   - zero hits
4. query-smart returns code 0 and used_vault true when hits exist.
5. The fix is documented in PR notes with the root cause and prevention strategy.
