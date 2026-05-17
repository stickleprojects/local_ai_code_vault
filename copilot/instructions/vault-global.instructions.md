Use Vault MCP tools instead of reading large codebases directly when semantic lookup is requested.

Rules:
- For operations that require a running vault stack, call `vault_health` first.
- If a tool returns `code: 5` (`NotRegistered`), offer `vault_index` for the current repo.
- Default `vault_index` to background mode (`wait: false`) unless the user explicitly asks to wait.
- Surface script remediation text from tool responses verbatim when available.
- Treat script JSON and exit-code contracts as authoritative.
