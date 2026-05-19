# Run the Overnight Agent Tonight

This guide shows the fastest way to launch Copilot Agent with the recovery prompt and capture a useful morning report.

## Preflight (2 minutes)
1. Open the repo root in VS Code.
2. Ensure your branch is the one you want the agent to modify.
3. Ensure there are no unrelated staged changes you do not want included.

Recommended quick checks:
1. `git status -sb`
2. `python --version`
3. `pwsh -NoProfile -Command "$PSVersionTable.PSVersion"`

## Launch Method A (recommended)
1. Open Copilot Chat in Agent mode.
2. Start a new chat.
3. Paste the full contents of [docs/OVERNIGHT_AGENT_PROMPT.md](docs/OVERNIGHT_AGENT_PROMPT.md).
4. Send the prompt and let the agent run.

## Launch Method B (if you prefer your own prompt)
1. Open [docs/QUERY_SMART_RECOVERY_PLAN.md](docs/QUERY_SMART_RECOVERY_PLAN.md).
2. Ask Copilot Agent to execute every phase and finish with the required output format.
3. Explicitly require both validation commands before completion.

## Suggested kickoff message (short version)
Use this if you do not want the full prompt template:

`Execute docs/QUERY_SMART_RECOVERY_PLAN.md end-to-end. Do not stop until tests are green or genuinely blocked. You must run Invoke-Pester tests/scripts.Tests.ps1 and python -m pytest -q tests/test_mcp_vault_server.py, then return exact counts and changed files.`

## What to ask for at the end
1. Exact test counts.
2. Changed files and why.
3. Any blockers with copied error text.
4. Proposed commit message.

## Morning review checklist
1. Confirm both required test commands are green.
2. Inspect [scripts/query-smart.ps1](scripts/query-smart.ps1), [scripts/query.ps1](scripts/query.ps1), and [tests/scripts.Tests.ps1](tests/scripts.Tests.ps1).
3. Verify no contract drift in [SKILL.md](SKILL.md) and [copilot/instructions/vault-global.instructions.md](copilot/instructions/vault-global.instructions.md).
4. Run `git diff --stat` and sanity-check scope.

## Optional: make this repeatable
If this workflow helps, keep [docs/OVERNIGHT_AGENT_PROMPT.md](docs/OVERNIGHT_AGENT_PROMPT.md) as your standard recovery prompt and update only the target plan doc per issue.
