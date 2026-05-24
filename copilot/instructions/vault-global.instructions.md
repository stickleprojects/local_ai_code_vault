Use Vault MCP tools instead of reading large codebases directly when semantic lookup is requested.

Rules:

- For operations that require a running vault stack, call `vault_health` first.
- `vault_search` uses shared script orchestration (`query-smart.ps1`) for
  auto-index + fallback behavior. Prefer `vault_search` over manually
  chaining `vault_status`/`vault_index`/`vault_search` for normal search.
- Default `vault_index` to background mode (`wait: false`) unless the user explicitly asks to wait.
- Surface script remediation text from tool responses verbatim when available.
- Treat script JSON and exit-code contracts as authoritative.
- For `vault_search`, when `savings.saved_tokens_upper > 0`, include one concise line only: `Upper-bound savings this query: <saved_tokens_upper> tokens across <files_counted> files (<pct_upper>%).` Do not include the full savings basis text unless asked.
- If `vault_search` returns `used_vault: false`, continue with normal
  workspace file search/read flow and surface `fallback_message`.
- If the user explicitly says `do not index`, pass `doNotIndex: true`
  to `vault_search`.
