# Vault MCP adapter (thin wrapper)

This server exposes MCP tools that map 1:1 to existing host scripts:

- `vault_health` → `scripts/vault-health.ps1`
- `vault_status` → `scripts/vault-status.ps1`
- `vault_index` → `scripts/index-repo.ps1`
- `vault_search` → `scripts/query.ps1`
- `vault_inspect` → `scripts/vault-inspect.ps1`
- `vault_hooks` → `scripts/install-git-hooks.ps1`

Implementation contract:

- The adapter shells out to `$env:VAULT_HOME/scripts/<name>.ps1`.
- Script stdout JSON is passed through as tool payload.
- Existing script exit-code semantics remain authoritative.
- No script business logic is duplicated here.
