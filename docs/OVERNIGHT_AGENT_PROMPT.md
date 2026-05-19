# Overnight Copilot Agent Prompt

Copy everything in this file and paste it into a new Copilot Agent chat.

## Prompt
You are the coding agent for local_ai_code_vault. Execute the recovery plan end-to-end and do not stop until all acceptance criteria are met or you are genuinely blocked.

Primary plan document:
- [docs/QUERY_SMART_RECOVERY_PLAN.md](docs/QUERY_SMART_RECOVERY_PLAN.md)

Mandatory constraints:
1. Keep AD-4 intact: orchestration logic in scripts, not in SKILL or instruction prose.
2. Preserve output contract of query-smart (fallback payload fields must remain stable).
3. Do not change repo_id computation source or embedding model/dimension contract.
4. Keep changes minimal and targeted to the failure.
5. If a test fails, fix root cause and rerun required suites before stopping.

Execution goals:
1. Make these script tests pass in [tests/scripts.Tests.ps1](tests/scripts.Tests.ps1):
   - indexing_declined path
   - no_semantic_hits path
   - semantic hit path
2. Keep MCP server tests green in [tests/test_mcp_vault_server.py](tests/test_mcp_vault_server.py).
3. Ensure query-smart returns exit code 0 for non-fatal fallback paths.

Suggested implementation order:
1. Inspect and harden JSON shape access for object vs hashtable in scripts.
2. Verify child script invocation in query-smart uses explicit named parameters.
3. Add or adjust tests for payload shape and fallback contract.
4. Run validation commands and summarize exact results.

Required validation commands:
1. `pwsh -NoProfile -Command "Invoke-Pester tests/scripts.Tests.ps1 -Output Detailed"`
2. `python -m pytest -q tests/test_mcp_vault_server.py`

Completion checklist:
1. Report final pass/fail counts for both test commands.
2. List every changed file with one-line reason.
3. Confirm query-smart non-fatal paths return code 0.
4. Provide a commit message suggestion.

Output format required at completion:
1. Status: complete or blocked.
2. Test summary: exact pass/fail counts.
3. Files changed: bullet list.
4. Remaining risk: short bullets.
5. Next action for human reviewer: one paragraph.
