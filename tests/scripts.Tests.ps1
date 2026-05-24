<#
Pester suite for the vault host scripts (Phase 3, Option B).

Strategy: drive the REAL scripts as they are actually invoked — no
production refactor, no Pester command-mocking. External edges are made
deterministic instead:
  * git      — real, in throwaway temp repos (git is on every runner)
  * vault API — a tiny in-process System.Net.HttpListener stub
  * docker   — a PATH-shim fake (Linux/CI only; the docker paths were
               already validated live in Phase 2, so they're -Skip'd
               off-Linux rather than mocked)

Covers the pure, stack-free contracts: the sacred repo_id rule (AD-2),
the uniform JSON/exit-code envelope, status→exit mapping, stale logic,
and git-hook file generation.
#>

BeforeAll {
    $script:ScriptsDir = Join-Path $PSScriptRoot '..' 'scripts' | Resolve-Path | Select-Object -ExpandProperty Path

    function Get-FreePort {
        $t = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $t.Start(); $p = $t.LocalEndpoint.Port; $t.Stop(); $p
    }

    function Start-StubApi {
        # $Routes: array of @{ match='<regex on URL path>'; status=<int>; body=<obj> }
        param([array]$Routes)
        $port = Get-FreePort
        $prefix = "http://localhost:$port/"
        $routesJson = ($Routes | ConvertTo-Json -Depth 12 -Compress)
        if ($Routes.Count -eq 1) { $routesJson = "[$routesJson]" }  # keep it an array
        $job = Start-Job {
            param($Prefix, $RoutesJson)
            $routes = $RoutesJson | ConvertFrom-Json
            $l = [System.Net.HttpListener]::new()
            $l.Prefixes.Add($Prefix)
            $l.Start()
            while ($true) {
                $ctx = $l.GetContext()
                $path = $ctx.Request.Url.AbsolutePath
                if ($path -eq '/__stop') {
                    $ctx.Response.StatusCode = 200; $ctx.Response.Close(); break
                }
                $route = $routes | Where-Object { $path -match $_.match } | Select-Object -First 1
                if ($null -eq $route) {
                    $ctx.Response.StatusCode = 599
                    $ctx.Response.Close(); continue
                }
                $payload = [System.Text.Encoding]::UTF8.GetBytes(($route.body | ConvertTo-Json -Depth 12 -Compress))
                $ctx.Response.StatusCode = [int]$route.status
                $ctx.Response.ContentType = 'application/json'
                $ctx.Response.OutputStream.Write($payload, 0, $payload.Length)
                $ctx.Response.Close()
            }
            $l.Stop()
        } -ArgumentList $prefix, $routesJson
        # Wait until it accepts connections.
        $base = "http://localhost:$port"
        for ($i = 0; $i -lt 50; $i++) {
            try { Invoke-WebRequest "$base/__ping" -TimeoutSec 1 -SkipHttpErrorCheck | Out-Null; break }
            catch { Start-Sleep -Milliseconds 100 }
        }
        [pscustomobject]@{ Base = $base; Job = $job }
    }

    function Stop-StubApi {
        param($Stub)
        try { Invoke-WebRequest "$($Stub.Base)/__stop" -TimeoutSec 2 -SkipHttpErrorCheck | Out-Null } catch {}
        Remove-Job -Job $Stub.Job -Force -ErrorAction SilentlyContinue
    }

    function New-TempGitRepo {
        $d = Join-Path ([System.IO.Path]::GetTempPath()) ("vault-t-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $d | Out-Null
        & git -C $d init -q
        & git -C $d config user.email 't@t'
        & git -C $d config user.name 't'
        'one' | Set-Content (Join-Path $d 'file1.py')
        & git -C $d add -A; & git -C $d commit -qm 'A'
        (Resolve-Path $d).Path
    }

    function Invoke-Script {
        # Run the script exactly as it's really invoked: a child
        # `pwsh -File`. Inherits our $env: (VAULT_API_BASE, PATH shim),
        # avoids in-proc param-binding/scope quirks, gives a real exit code.
        param([string]$Name, [string[]]$ScriptArgs = @())
        $p = Join-Path $script:ScriptsDir $Name
        $out = & pwsh -NoProfile -File $p @ScriptArgs 2>$null
        $code = $LASTEXITCODE
        $raw = ($out -join "`n")
        $json = $null
        if ($raw.Trim()) {
            try { $json = $raw | ConvertFrom-Json } catch { $json = $null }
        }
        [pscustomobject]@{ Code = $code; Raw = $raw; Json = $json }
    }

    function New-DockerShim {
        # Linux/CI only: a `docker` on PATH that fakes the subcommands
        # index-repo / index-status use. Behaviour tuned via env vars.
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("vault-dk-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir | Out-Null
        $shim = Join-Path $dir 'docker'
        @'
#!/usr/bin/env pwsh
$a = $args
switch ($a[0]) {
  'image'   { if ($env:VAULT_FAKE_IMAGE_MISSING -eq '1') { exit 1 } else { exit 0 } }
  'build'   { if ($env:VAULT_FAKE_BUILD_FAIL -eq '1') { exit 1 } else { exit 0 } }
  'run'     {
      if ($a -contains '-d') { Write-Output 'cafef00dba5e'; exit 0 }
      [Console]::Error.WriteLine('[indexer] indexing...')
      Write-Output '{"repo_id":"stub","files":3,"chunks":9,"skipped":1,"sha":"abc123","incremental":false}'
      exit 0
  }
  'inspect' { if ($env:VAULT_FAKE_INSPECT -eq 'MISSING') { exit 1 } ; Write-Output ($(if ($env:VAULT_FAKE_INSPECT) { $env:VAULT_FAKE_INSPECT } else { 'exited|0' })); exit 0 }
  'rm'      { exit 0 }
  default   { exit 0 }
}
'@ | Set-Content -LiteralPath $shim
        if ($IsLinux -or $IsMacOS) { & chmod +x $shim }
        $dir
    }
}

Describe 'repo-id.ps1 — AD-2 sacred contract' {
    BeforeAll { $script:repo = New-TempGitRepo }
    AfterAll { Remove-Item -Recurse -Force $script:repo -ErrorAction SilentlyContinue }

    It 'emits a stable {repo_id, repo_root, slug} JSON object' {
        $r = Invoke-Script 'repo-id.ps1' @('-Path', $repo)
        $r.Code | Should -Be 0
        $r.Json.ok | Should -BeTrue
        $r.Json.repo_id | Should -Match '^[a-z0-9-]+-[0-9a-f]{8}$'
    }

    It 'is deterministic and identical from a subdirectory' {
        $sub = Join-Path $repo 'pkg'; New-Item -ItemType Directory -Path $sub | Out-Null
        $a = (Invoke-Script 'repo-id.ps1' @('-Path', $repo, '-Raw')).Raw.Trim()
        $b = (Invoke-Script 'repo-id.ps1' @('-Path', $sub, '-Raw')).Raw.Trim()
        $a | Should -Not -BeNullOrEmpty
        $b | Should -Be $a
    }

    It 'exits 3 (NotGitRepo) outside a repo' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid())
        New-Item -ItemType Directory -Path $tmp | Out-Null
        $r = Invoke-Script 'repo-id.ps1' @('-Path', $tmp)
        $r.Code | Should -Be 3
        $r.Json.ok | Should -BeFalse
        Remove-Item -Recurse -Force $tmp
    }
}

Describe 'vault-health.ps1' {
    It 'reports reachable + fields on 200' {
        $stub = Start-StubApi @(@{ match = '^/api/status$'; status = 200; body = @{
                    status = 'ok'; api_version = '0.1.0'; embed_model = 'nomic-embed-code'
                    embed_dim = 3584; qdrant_connected = $true 
                } 
            })
        try {
            $env:VAULT_API_BASE = $stub.Base
            $r = Invoke-Script 'vault-health.ps1' @()
            $r.Code | Should -Be 0
            $r.Json.reachable | Should -BeTrue
            $r.Json.embed_dim | Should -Be 3584
        }
        finally { $env:VAULT_API_BASE = $null; Stop-StubApi $stub }
    }

    It 'exits 4 (StackDown) when nothing is listening' {
        $env:VAULT_API_BASE = "http://localhost:$(Get-FreePort)"
        try {
            $r = Invoke-Script 'vault-health.ps1' @()
            $r.Code | Should -Be 4
            $r.Json.ok | Should -BeFalse
        }
        finally { $env:VAULT_API_BASE = $null }
    }
}

Describe 'vault-status.ps1 — registration & staleness' {
    BeforeAll { $script:repo = New-TempGitRepo }
    AfterAll { Remove-Item -Recurse -Force $script:repo -ErrorAction SilentlyContinue }

    It 'registered:false on 404' {
        $stub = Start-StubApi @(@{ match = '^/api/repos/'; status = 404; body = @{ detail = 'no' } })
        try {
            $env:VAULT_API_BASE = $stub.Base
            $r = Invoke-Script 'vault-status.ps1' @('-Path', $repo)
            $r.Code | Should -Be 0
            $r.Json.registered | Should -BeFalse
            $r.Json.head_sha   | Should -Not -BeNullOrEmpty
        }
        finally { $env:VAULT_API_BASE = $null; Stop-StubApi $stub }
    }

    It 'stale:false when indexed SHA == HEAD' {
        $head = (& git -C $repo rev-parse HEAD).Trim()
        $stub = Start-StubApi @(@{ match = '^/api/repos/'; status = 200; body = @{
                    repo_id = 'x'; indexed_sha = $head; indexed_at = '2026-01-01T00:00:00Z' 
                } 
            })
        try {
            $env:VAULT_API_BASE = $stub.Base
            $r = Invoke-Script 'vault-status.ps1' @('-Path', $repo)
            $r.Json.registered | Should -BeTrue
            $r.Json.stale | Should -BeFalse
            $r.Json.changed_files | Should -Be @()
        }
        finally { $env:VAULT_API_BASE = $null; Stop-StubApi $stub }
    }

    It 'stale:true + changed_files when indexed SHA is an older commit' {
        $first = (& git -C $repo rev-parse HEAD).Trim()
        'two' | Set-Content (Join-Path $repo 'file2.py')
        & git -C $repo add -A; & git -C $repo commit -qm 'B'
        $stub = Start-StubApi @(@{ match = '^/api/repos/'; status = 200; body = @{
                    repo_id = 'x'; indexed_sha = $first; indexed_at = '2026-01-01T00:00:00Z' 
                } 
            })
        try {
            $env:VAULT_API_BASE = $stub.Base
            $r = Invoke-Script 'vault-status.ps1' @('-Path', $repo)
            $r.Json.stale | Should -BeTrue
            $r.Json.changed_files | Should -Contain 'file2.py'
        }
        finally { $env:VAULT_API_BASE = $null; Stop-StubApi $stub }
    }
}

Describe 'query.ps1' {
    BeforeAll { $script:repo = New-TempGitRepo }
    AfterAll { Remove-Item -Recurse -Force $script:repo -ErrorAction SilentlyContinue }

    It 'exits 2 (Usage) on a blank query' {
        # ' ' binds past Mandatory[string]; the script's own guard fires.
        $r = Invoke-Script 'query.ps1' @(' ', '-Path', $repo)
        $r.Code | Should -Be 2
    }

    It 'exits 5 (NotRegistered) on 404' {
        $stub = Start-StubApi @(@{ match = '^/api/query/'; status = 404; body = @{ detail = 'no' } })
        try {
            $env:VAULT_API_BASE = $stub.Base
            $r = Invoke-Script 'query.ps1' @('find login', '-Path', $repo)
            $r.Code | Should -Be 5
        }
        finally { $env:VAULT_API_BASE = $null; Stop-StubApi $stub }
    }

    It 'passes results through on 200' {
        $stub = Start-StubApi @(@{ match = '^/api/query/'; status = 200; body = @{
                    repo_id = 'x'; query = 'q'; results = @(@{ path = 'a.py'; language = 'python'
                            start_line = 1; end_line = 2; code = 'def f(): ...'; score = 0.5 
                        }) 
                } 
            })
        try {
            $env:VAULT_API_BASE = $stub.Base
            $r = Invoke-Script 'query.ps1' @('q', '-Path', $repo)
            $r.Code | Should -Be 0
            $r.Json.count | Should -Be 1
            $r.Json.results[0].path | Should -Be 'a.py'
        }
        finally { $env:VAULT_API_BASE = $null; Stop-StubApi $stub }
    }

    It 'emits savings and appends one ledger event on 200' {
        $statsDir = Join-Path ([System.IO.Path]::GetTempPath()) ("vault-stats-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $statsDir | Out-Null
        $stub = Start-StubApi @(@{ match = '^/api/query/'; status = 200; body = @{
                    repo_id = 'x'; query = 'q'; results = @(
                        @{ path = 'file1.py'; language = 'python'; start_line = 1; end_line = 1; code = 'one'; score = 0.9 }
                    ) 
                } 
            })
        try {
            $env:VAULT_API_BASE = $stub.Base
            $env:VAULT_STATS_DIR = $statsDir
            $r = Invoke-Script 'query.ps1' @('q', '-Path', $repo)
            $r.Code | Should -Be 0
            $r.Json.savings.returned_tokens | Should -BeGreaterThan 0
            $r.Json.savings.baseline_tokens_upper | Should -BeGreaterThan 0
            $r.Json.savings.files_counted | Should -Be 1
            $repoId = (Invoke-Script 'repo-id.ps1' @('-Path', $repo, '-Raw')).Raw.Trim()
            $ledger = Join-Path $statsDir "$repoId.jsonl"
            Test-Path -LiteralPath $ledger | Should -BeTrue
            $lines = [IO.File]::ReadAllLines($ledger)
            $lines.Count | Should -Be 1
            $event = $lines[0] | ConvertFrom-Json
            $event.repo_id | Should -Be $repoId
            $event.returned_tokens | Should -BeGreaterThan 0
        }
        finally {
            $env:VAULT_API_BASE = $null
            $env:VAULT_STATS_DIR = $null
            Stop-StubApi $stub
            Remove-Item -Recurse -Force $statsDir -ErrorAction SilentlyContinue
        }
    }
}

Describe 'query-smart.ps1' {
    BeforeAll { $script:repo = New-TempGitRepo }
    AfterAll { Remove-Item -Recurse -Force $script:repo -ErrorAction SilentlyContinue }

    It 'returns exact symbol matches with mode=symbol (case-sensitive, no partial-token matches)' {
        $repoPath = $script:repo
        $repoPath | Should -Not -BeNullOrEmpty

        @(
            'class OrderService:',
            '    pass'
        ) | Set-Content (Join-Path $repoPath 'service.py')
        @(
            'from service import OrderService',
            'def uses_symbol():',
            '    return OrderService()'
        ) | Set-Content (Join-Path $repoPath 'consumer.py')
        @(
            'OrderServiceHelper = 1',
            'orderservice = 2'
        ) | Set-Content (Join-Path $repoPath 'noise.py')

        & git -C $repoPath add service.py consumer.py noise.py

        $r = Invoke-Script 'query-smart.ps1' @('OrderService', '-Path', $repoPath, '-Symbol')
        $r.Code | Should -Be 0
        $r.Json.mode | Should -Be 'symbol'
        $r.Json.used_vault | Should -BeTrue
        $r.Json.fallback_reason | Should -BeNullOrEmpty

        $paths = @($r.Json.results | ForEach-Object { $_.path } | Sort-Object -Unique)
        $paths | Should -Contain 'service.py'
        $paths | Should -Contain 'consumer.py'
        $paths | Should -Not -Contain 'noise.py'
    }

    It 'falls back when the vault stack is unavailable' {
        $env:VAULT_API_BASE = "http://localhost:$(Get-FreePort)"
        try {
            $r = Invoke-Script 'query-smart.ps1' @('q', '-Path', $repo)
            $r.Code | Should -Be 0
            $r.Json.mode | Should -Be 'semantic'
            $r.Json.used_vault | Should -BeFalse
            $r.Json.fallback_reason | Should -Be 'vault_unavailable'
            $r.Json.next_action | Should -Be 'workspace_search'
            $r.Json.index_stale | Should -BeFalse
            $r.Json.changed_files_not_indexed | Should -Be @()
        }
        finally { $env:VAULT_API_BASE = $null }
    }

    It 'falls back with indexing_declined when repo is unregistered and DoNotIndex is set' {
        $stub = Start-StubApi @(
            @{ match = '^/api/status$'; status = 200; body = @{ status = 'ok'; api_version = '0.1.0'; embed_model = 'nomic-embed-code'; embed_dim = 3584; qdrant_connected = $true } },
            @{ match = '^/api/query/'; status = 404; body = @{ detail = 'no' } }
        )
        try {
            $env:VAULT_API_BASE = $stub.Base
            $r = Invoke-Script 'query-smart.ps1' @('q', '-Path', $repo, '-DoNotIndex')
            $r.Code | Should -Be 0
            $r.Json.mode | Should -Be 'semantic'
            $r.Json.used_vault | Should -BeFalse
            $r.Json.fallback_reason | Should -Be 'indexing_declined'
        }
        finally { $env:VAULT_API_BASE = $null; Stop-StubApi $stub }
    }

    It 'falls back with no_semantic_hits on zero results' {
        $stub = Start-StubApi @(
            @{ match = '^/api/status$'; status = 200; body = @{ status = 'ok'; api_version = '0.1.0'; embed_model = 'nomic-embed-code'; embed_dim = 3584; qdrant_connected = $true } },
            @{ match = '^/api/query/'; status = 200; body = @{ repo_id = 'x'; query = 'q'; results = @() } }
        )
        try {
            $env:VAULT_API_BASE = $stub.Base
            $r = Invoke-Script 'query-smart.ps1' @('q', '-Path', $repo)
            $r.Code | Should -Be 0
            $r.Json.mode | Should -Be 'semantic'
            $r.Json.used_vault | Should -BeFalse
            $r.Json.fallback_reason | Should -Be 'no_semantic_hits'
            $r.Json.count | Should -Be 0
        }
        finally { $env:VAULT_API_BASE = $null; Stop-StubApi $stub }
    }

    It 'returns vault results when semantic hits are found' {
        $stub = Start-StubApi @(
            @{ match = '^/api/status$'; status = 200; body = @{ status = 'ok'; api_version = '0.1.0'; embed_model = 'nomic-embed-code'; embed_dim = 3584; qdrant_connected = $true } },
            @{ match = '^/api/query/'; status = 200; body = @{ repo_id = 'x'; query = 'q'; results = @(@{ path = 'a.py'; language = 'python'; start_line = 1; end_line = 2; code = 'def f(): pass'; score = 0.8 }) } }
        )
        try {
            $env:VAULT_API_BASE = $stub.Base
            $r = Invoke-Script 'query-smart.ps1' @('q', '-Path', $repo)
            $r.Code | Should -Be 0
            $r.Json.mode | Should -Be 'semantic'
            $r.Json.used_vault | Should -BeTrue
            $r.Json.fallback_reason | Should -BeNullOrEmpty
            $r.Json.count | Should -Be 1
            $r.Json.index_stale | Should -BeFalse
            $r.Json.changed_files_not_indexed | Should -Be @()
        }
        finally { $env:VAULT_API_BASE = $null; Stop-StubApi $stub }
    }

    It 'surfaces index_stale and changed_files_not_indexed when HEAD moved past indexed SHA' {
        $first = (& git -C $repo rev-parse HEAD).Trim()
        'three' | Set-Content (Join-Path $repo 'file3.py')
        & git -C $repo add -A; & git -C $repo commit -qm 'C'

        $stub = Start-StubApi @(
            @{ match = '^/api/status$'; status = 200; body = @{ status = 'ok'; api_version = '0.1.0'; embed_model = 'nomic-embed-code'; embed_dim = 3584; qdrant_connected = $true } },
            @{ match = '^/api/repos/'; status = 200; body = @{ repo_id = 'x'; indexed_sha = $first; indexed_at = '2026-01-01T00:00:00Z' } },
            @{ match = '^/api/query/'; status = 200; body = @{ repo_id = 'x'; query = 'q'; results = @(@{ path = 'a.py'; language = 'python'; start_line = 1; end_line = 2; code = 'def f(): pass'; score = 0.8 }) } }
        )
        try {
            $env:VAULT_API_BASE = $stub.Base
            $r = Invoke-Script 'query-smart.ps1' @('q', '-Path', $repo)
            $r.Code | Should -Be 0
            $r.Json.index_stale | Should -BeTrue
            $r.Json.changed_files_not_indexed | Should -Contain 'file3.py'
        }
        finally { $env:VAULT_API_BASE = $null; Stop-StubApi $stub }
    }
}

Describe 'vault-savings.ps1' {
    BeforeAll { $script:repo = New-TempGitRepo }
    AfterAll { Remove-Item -Recurse -Force $script:repo -ErrorAction SilentlyContinue }

    It 'aggregates all-time and window totals from the ledger' {
        $statsDir = Join-Path ([System.IO.Path]::GetTempPath()) ("vault-stats-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $statsDir | Out-Null
        try {
            $env:VAULT_STATS_DIR = $statsDir
            $repoId = (Invoke-Script 'repo-id.ps1' @('-Path', $repo, '-Raw')).Raw.Trim()
            $statsFile = Join-Path $statsDir "$repoId.jsonl"
            $recentTs = [DateTime]::UtcNow.AddDays(-1).ToString('o')
            $oldTs = [DateTime]::UtcNow.AddDays(-20).ToString('o')
            @(
                @{ ts = $recentTs; repo_id = $repoId; returned_tokens = 10; baseline_tokens_upper = 100; saved_tokens_upper = 90 }
                @{ ts = $oldTs; repo_id = $repoId; returned_tokens = 20; baseline_tokens_upper = 80; saved_tokens_upper = 60 }
            ) | ForEach-Object {
                [IO.File]::AppendAllText($statsFile, (($_ | ConvertTo-Json -Compress) + "`n"))
            }
            [IO.File]::AppendAllText($statsFile, "not json`n")

            $r = Invoke-Script 'vault-savings.ps1' @('-Path', $repo, '-Days', '7')
            $r.Code | Should -Be 0
            $r.Json.recorded_queries | Should -Be 2
            $r.Json.corrupt_lines | Should -Be 1
            $r.Json.all_time.queries | Should -Be 2
            $r.Json.all_time.returned_tokens | Should -Be 30
            $r.Json.all_time.baseline_tokens_upper | Should -Be 180
            $r.Json.all_time.saved_tokens_upper | Should -Be 150
            $r.Json.window.days | Should -Be 7
            $r.Json.window.queries | Should -Be 1
            $r.Json.window.returned_tokens | Should -Be 10
            $r.Json.window.saved_tokens_upper | Should -Be 90
        }
        finally {
            $env:VAULT_STATS_DIR = $null
            Remove-Item -Recurse -Force $statsDir -ErrorAction SilentlyContinue
        }
    }
}

Describe 'vault-inspect.ps1 — AD-9 read-only' {
    BeforeAll { $script:repo = New-TempGitRepo }
    AfterAll { Remove-Item -Recurse -Force $script:repo -ErrorAction SilentlyContinue }

    It 'exits 5 when stats 404' {
        $stub = Start-StubApi @(@{ match = '/stats$'; status = 404; body = @{ detail = 'no' } })
        try {
            $env:VAULT_API_BASE = $stub.Base
            (Invoke-Script 'vault-inspect.ps1' @('-Path', $repo)).Code | Should -Be 5
        }
        finally { $env:VAULT_API_BASE = $null; Stop-StubApi $stub }
    }

    It 'returns stats and (with -Files) a filtered inventory' {
        $stub = Start-StubApi @(
            @{ match = '/stats$'; status = 200; body = @{ repo_id = 'x'; indexed_sha = 's'
                    indexed_at = 't'; file_count = 2; chunk_count = 5; skipped_count = 1
                    languages = @(@{ language = 'python'; files = 2; chunks = 5 }) 
                } 
            },
            @{ match = '/files$'; status = 200; body = @{ repo_id = 'x'; total = 2; offset = 0
                    limit = 100; files = @(
                        @{ path = 'a.py'; language = 'python'; chunk_count = 3 },
                        @{ path = 'b.ts'; language = 'typescript'; chunk_count = 2 }) 
                } 
            }
        )
        try {
            $env:VAULT_API_BASE = $stub.Base
            $r = Invoke-Script 'vault-inspect.ps1' @('-Path', $repo, '-Files', '-Language', 'python')
            $r.Code | Should -Be 0
            $r.Json.stats.chunk_count | Should -Be 5
            $r.Json.files.returned | Should -Be 1
            $r.Json.files.files[0].path | Should -Be 'a.py'
        }
        finally { $env:VAULT_API_BASE = $null; Stop-StubApi $stub }
    }
}

Describe 'install-git-hooks.ps1' {
    BeforeEach { $script:repo = New-TempGitRepo }
    AfterEach { Remove-Item -Recurse -Force $script:repo -ErrorAction SilentlyContinue }

    It 'installs LF, marker-bearing post-commit & post-merge hooks' {
        $r = Invoke-Script 'install-git-hooks.ps1' @('-Path', $repo)
        $r.Code | Should -Be 0
        foreach ($h in 'post-commit', 'post-merge') {
            $p = Join-Path $repo ".git/hooks/$h"
            Test-Path $p | Should -BeTrue
            $raw = Get-Content -Raw $p
            $raw | Should -Match 'vault-managed hook'
            $raw | Should -Not -Match "`r`n"
        }
    }

    It '-Remove deletes only vault-managed hooks' {
        Invoke-Script 'install-git-hooks.ps1' @('-Path', $repo) | Out-Null
        $r = Invoke-Script 'install-git-hooks.ps1' @('-Path', $repo, '-Remove')
        $r.Code | Should -Be 0
        Test-Path (Join-Path $repo '.git/hooks/post-commit') | Should -BeFalse
    }

    It 'refuses to clobber a pre-existing non-vault hook without -Force' {
        $p = Join-Path $repo '.git/hooks/post-commit'
        New-Item -ItemType Directory -Force -Path (Split-Path $p) | Out-Null
        "#!/bin/sh`necho mine" | Set-Content $p
        $r = Invoke-Script 'install-git-hooks.ps1' @('-Path', $repo)
        $r.Code | Should -Be 2
        (Get-Content -Raw $p) | Should -Match 'echo mine'
    }
}

Describe 'install-skill.ps1' {
    It 'installs the skill + records VAULT_HOME (temp root, no persist)' {
        $root = Join-Path $TestDrive 'skills'
        $r = Invoke-Script 'install-skill.ps1' @('-SkillsRoot', $root, '-NoPersist')
        $r.Code | Should -Be 0
        $r.Json.installed | Should -BeTrue
        $dest = Join-Path $root 'vault' 'SKILL.md'
        Test-Path $dest | Should -BeTrue
        $skill = Get-Content -Raw $dest
        # Placeholder must be substituted with the literal scripts dir so
        # the skill invokes scripts via `&` with no $env: / child pwsh.
        $skill | Should -Not -Match '\{\{VAULT_SCRIPTS\}\}'
        $r.Json.scripts_dir | Should -Not -BeNullOrEmpty
        Test-Path $r.Json.scripts_dir | Should -BeTrue
        $skill | Should -BeLike "*$($r.Json.scripts_dir)*"
        Test-Path $r.Json.vault_home | Should -BeTrue   # points at a real clone
    }

    It 'fail-closed: default non-interactive run never bypasses the prompt' {
        $root = Join-Path $TestDrive 'skills3'
        $set = Join-Path $TestDrive 'fc-default.json'
        $r = Invoke-Script 'install-skill.ps1' @('-SkillsRoot', $root, '-NoPersist', '-SettingsPath', $set)
        $r.Code | Should -Be 0
        $r.Json.installed | Should -BeTrue                 # skill still installs
        $r.Json.permission_hook_present | Should -BeOfType [bool]
        $r.Json.permission_hook_present | Should -BeFalse  # security NOT bypassed
        $r.Json.permission_hook_action  | Should -Be 'skipped'
        $r.Json.permission_hook_hint    | Should -Not -BeNullOrEmpty
        $r.Json.repo_hooks_action       | Should -Be 'skipped'
        $r.Json.repo_hooks_hint         | Should -Not -BeNullOrEmpty
        Test-Path $set | Should -BeFalse                   # settings.json untouched
    }

    It 'installs repo freshness hooks when explicitly requested' {
        $root = Join-Path $TestDrive 'skills-hooks-install'
        $repo = New-TempGitRepo
        try {
            $r = Invoke-Script 'install-skill.ps1' @('-SkillsRoot', $root, '-NoPersist', '-RepoHooks', 'Install', '-RepoPath', $repo)
            $r.Code | Should -Be 0
            $r.Json.repo_hooks_action | Should -Be 'installed'
            $r.Json.repo_hooks_repo_root | Should -Be $repo
            Test-Path (Join-Path $repo '.git/hooks/post-commit') | Should -BeTrue
            Test-Path (Join-Path $repo '.git/hooks/post-merge') | Should -BeTrue
        }
        finally {
            Remove-Item -Recurse -Force $repo -ErrorAction SilentlyContinue
        }
    }

    It 'fails gracefully when repo hook install is requested for a non-git path' {
        $root = Join-Path $TestDrive 'skills-hooks-fail'
        $notRepo = Join-Path $TestDrive 'not-a-repo'
        New-Item -ItemType Directory -Path $notRepo | Out-Null
        $r = Invoke-Script 'install-skill.ps1' @('-SkillsRoot', $root, '-NoPersist', '-RepoHooks', 'Install', '-RepoPath', $notRepo)
        $r.Code | Should -Be 0
        $r.Json.installed | Should -BeTrue
        $r.Json.repo_hooks_action | Should -Be 'failed'
        $r.Json.repo_hooks_error | Should -Not -BeNullOrEmpty
        $r.Json.repo_hooks_hint | Should -Not -BeNullOrEmpty
    }

    It 'explicit -PermissionHook Install pre-approves, idempotently, preserving other keys' {
        $root = Join-Path $TestDrive 'skills4'
        $set = Join-Path $TestDrive 'fc-install.json'
        Set-Content $set '{"model":"opus","hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"echo hi"}]}]}}'
        $r = Invoke-Script 'install-skill.ps1' @('-SkillsRoot', $root, '-NoPersist', '-SettingsPath', $set, '-PermissionHook', 'Install')
        $r.Code | Should -Be 0
        $r.Json.permission_hook_action  | Should -Be 'installed'
        $r.Json.permission_hook_present | Should -BeTrue
        $r.Json.settings_backup         | Should -Not -BeNullOrEmpty
        $j = Get-Content $set -Raw | ConvertFrom-Json
        $j.model | Should -Be 'opus'                        # existing key kept
        $j.hooks.PreToolUse.Count | Should -Be 2            # existing hook kept + ours
        # second run must not duplicate
        $r2 = Invoke-Script 'install-skill.ps1' @('-SkillsRoot', $root, '-NoPersist', '-SettingsPath', $set, '-PermissionHook', 'Install')
        $r2.Json.permission_hook_action | Should -Be 'present'
        (Get-Content $set -Raw | ConvertFrom-Json).hooks.PreToolUse.Count | Should -Be 2
    }

    It 'fail-closed: a malformed settings.json is left intact and the prompt stays' {
        $root = Join-Path $TestDrive 'skills5'
        $set = Join-Path $TestDrive 'fc-bad.json'
        Set-Content $set '{ not : valid json' -NoNewline
        $r = Invoke-Script 'install-skill.ps1' @('-SkillsRoot', $root, '-NoPersist', '-SettingsPath', $set, '-PermissionHook', 'Install')
        $r.Code | Should -Be 0                              # skill install still succeeds
        $r.Json.permission_hook_present | Should -BeFalse   # NOT bypassed on error
        $r.Json.permission_hook_action  | Should -Be 'failed'
        $r.Json.permission_hook_error   | Should -Not -BeNullOrEmpty
        (Get-Content $set -Raw) | Should -Be '{ not : valid json'   # untouched
    }

    It 'good citizen: AV-blocked + non-interactive + no override fails gracefully (no bypass)' {
        $root = Join-Path $TestDrive 'skills6'
        $set = Join-Path $TestDrive 'av-block.json'
        $env:VAULT_TEST_FORCE_AV_BLOCK = '1'
        try {
            $r = Invoke-Script 'install-skill.ps1' @('-SkillsRoot', $root, '-NoPersist', '-SettingsPath', $set, '-PermissionHook', 'Install')
        }
        finally { Remove-Item Env:VAULT_TEST_FORCE_AV_BLOCK -ErrorAction SilentlyContinue }
        $r.Code | Should -Be 0                              # skill install still ok
        $r.Json.av_blocks_hook          | Should -BeTrue
        $r.Json.permission_hook_present | Should -BeFalse   # NOT bypassed
        $r.Json.permission_hook_action  | Should -Be 'av-blocked'
        $r.Json.permission_hook_error   | Should -Not -BeNullOrEmpty
        Test-Path $set | Should -BeFalse                    # settings.json untouched
    }

    It 'good citizen: -IgnoreAvBlock is an explicit override that installs despite the AV block' {
        $root = Join-Path $TestDrive 'skills7'
        $set = Join-Path $TestDrive 'av-override.json'
        $env:VAULT_TEST_FORCE_AV_BLOCK = '1'
        try {
            $r = Invoke-Script 'install-skill.ps1' @('-SkillsRoot', $root, '-NoPersist', '-SettingsPath', $set, '-PermissionHook', 'Install', '-IgnoreAvBlock')
        }
        finally { Remove-Item Env:VAULT_TEST_FORCE_AV_BLOCK -ErrorAction SilentlyContinue }
        $r.Code | Should -Be 0
        $r.Json.av_blocks_hook          | Should -BeTrue    # still reported honestly
        $r.Json.permission_hook_action  | Should -Be 'installed'
        $r.Json.permission_hook_present | Should -BeTrue
        (Get-Content $set -Raw) | Should -Match 'local_ai_code_vault'
    }

    It '-Remove deletes the installed skill' {
        $root = Join-Path $TestDrive 'skills2'
        Invoke-Script 'install-skill.ps1' @('-SkillsRoot', $root, '-NoPersist') | Out-Null
        $r = Invoke-Script 'install-skill.ps1' @('-SkillsRoot', $root, '-NoPersist', '-Remove')
        $r.Code | Should -Be 0
        $r.Json.removed | Should -BeTrue
        Test-Path (Join-Path $root 'vault') | Should -BeFalse
    }

    It '-Remove also removes the permission hook, backs up, and keeps other hooks' {
        $root = Join-Path $TestDrive 'skills8'
        $set = Join-Path $TestDrive 'rm-hook.json'
        Set-Content $set '{"model":"x","hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"echo keepme"}]}]}}'
        Invoke-Script 'install-skill.ps1' @('-SkillsRoot', $root, '-NoPersist', '-SettingsPath', $set, '-PermissionHook', 'Install') | Out-Null
        (Get-Content $set -Raw) | Should -Match 'local_ai_code_vault'   # installed
        $r = Invoke-Script 'install-skill.ps1' @('-SkillsRoot', $root, '-NoPersist', '-SettingsPath', $set, '-Remove')
        $r.Code | Should -Be 0
        $r.Json.removed                 | Should -BeTrue
        $r.Json.permission_hook_removed | Should -BeTrue
        $r.Json.settings_backup         | Should -Not -BeNullOrEmpty
        $j = Get-Content $set -Raw | ConvertFrom-Json
        (Get-Content $set -Raw) | Should -Not -Match 'local_ai_code_vault'   # ours gone
        $j.model | Should -Be 'x'                                            # other keys kept
        $j.hooks.PreToolUse.Count | Should -Be 1                             # other hook kept
        $j.hooks.PreToolUse[0].hooks[0].command | Should -Be 'echo keepme'
    }

    It '-Remove is a no-op (no backup) when no vault hook is present' {
        $root = Join-Path $TestDrive 'skills9'
        $set = Join-Path $TestDrive 'rm-none.json'
        Set-Content $set '{"model":"opus"}' -NoNewline
        $r = Invoke-Script 'install-skill.ps1' @('-SkillsRoot', $root, '-NoPersist', '-SettingsPath', $set, '-Remove')
        $r.Code | Should -Be 0
        $r.Json.permission_hook_removed | Should -BeFalse
        $r.Json.settings_backup         | Should -BeNullOrEmpty
        (Get-Content $set -Raw) | Should -Be '{"model":"opus"}'             # untouched
    }
}

Describe 'install-copilot.ps1' {
    It 'installs MCP settings + global instruction file (no persist)' {
        $settings = Join-Path $TestDrive 'settings.json'
        $instructionsRoot = Join-Path $TestDrive 'instructions'
        $r = Invoke-Script 'install-copilot.ps1' @('-SettingsPath', $settings, '-InstructionsRoot', $instructionsRoot, '-NoPersist')
        $r.Code | Should -Be 0
        $r.Json.installed | Should -BeTrue

        Test-Path $settings | Should -BeTrue
        $cfg = Get-Content -Raw $settings | ConvertFrom-Json -AsHashtable
        $cfg['mcp.servers'].Contains('vault') | Should -BeTrue
        # Separator-agnostic: Windows yields backslashes, POSIX forward slashes.
        $cfg['mcp.servers']['vault']['args'][-1] | Should -Match 'vault_mcp[\\/]vault[\\/]server\.py'
        $cfg['mcp.servers']['vault']['command'] | Should -Not -BeNullOrEmpty

        $instr = Join-Path $instructionsRoot 'vault' 'vault-global.instructions.md'
        Test-Path $instr | Should -BeTrue
        (Get-Content -Raw $instr) | Should -Match 'vault_health'
        $r.Json.repo_hooks_action | Should -Be 'skipped'
        $r.Json.repo_hooks_hint | Should -Not -BeNullOrEmpty
    }

    It 'installs repo freshness hooks when explicitly requested' {
        $settings = Join-Path $TestDrive 'settings-hooks.json'
        $instructionsRoot = Join-Path $TestDrive 'instructions-hooks'
        $repo = New-TempGitRepo
        try {
            $r = Invoke-Script 'install-copilot.ps1' @('-SettingsPath', $settings, '-InstructionsRoot', $instructionsRoot, '-NoPersist', '-RepoHooks', 'Install', '-RepoPath', $repo)
            $r.Code | Should -Be 0
            $r.Json.repo_hooks_action | Should -Be 'installed'
            $r.Json.repo_hooks_repo_root | Should -Be $repo
            Test-Path (Join-Path $repo '.git/hooks/post-commit') | Should -BeTrue
            Test-Path (Join-Path $repo '.git/hooks/post-merge') | Should -BeTrue
        }
        finally {
            Remove-Item -Recurse -Force $repo -ErrorAction SilentlyContinue
        }
    }

    It 'fails gracefully when repo hook install is requested for a non-git path' {
        $settings = Join-Path $TestDrive 'settings-hooks-fail.json'
        $instructionsRoot = Join-Path $TestDrive 'instructions-hooks-fail'
        $notRepo = Join-Path $TestDrive 'not-a-repo-copilot'
        New-Item -ItemType Directory -Path $notRepo | Out-Null
        $r = Invoke-Script 'install-copilot.ps1' @('-SettingsPath', $settings, '-InstructionsRoot', $instructionsRoot, '-NoPersist', '-RepoHooks', 'Install', '-RepoPath', $notRepo)
        $r.Code | Should -Be 0
        $r.Json.installed | Should -BeTrue
        $r.Json.repo_hooks_action | Should -Be 'failed'
        $r.Json.repo_hooks_error | Should -Not -BeNullOrEmpty
        $r.Json.repo_hooks_hint | Should -Not -BeNullOrEmpty
    }

    It 'handles JSONC settings, preserves unrelated keys, and reports backup on rewrite' {
        $settings = Join-Path $TestDrive 'settings-comments.json'
        @'
{
  // keep this user's theme
  "workbench.colorTheme": "Solarized Dark",
  "mcp.servers": {
    "other": {
      "command": "python",
      "args": ["other.py"]
    }
  }
}
'@ | Set-Content -LiteralPath $settings

        $instructionsRoot = Join-Path $TestDrive 'instructions-comments'
        $r = Invoke-Script 'install-copilot.ps1' @('-SettingsPath', $settings, '-InstructionsRoot', $instructionsRoot, '-NoPersist')
        $r.Code | Should -Be 0
        $r.Json.settings_rewritten | Should -BeTrue
        $r.Json.settings_backup_path | Should -Not -BeNullOrEmpty
        Test-Path $r.Json.settings_backup_path | Should -BeTrue
        $r.Json.settings_notice | Should -Match 'rewritten'

        $cfg = Get-Content -Raw $settings | ConvertFrom-Json -AsHashtable
        $cfg['workbench.colorTheme'] | Should -Be 'Solarized Dark'
        $cfg['mcp.servers'].Contains('other') | Should -BeTrue
        $cfg['mcp.servers'].Contains('vault') | Should -BeTrue
    }

    It '-Remove unregisters MCP and deletes installed instruction file' {
        $settings = Join-Path $TestDrive 'settings-rm.json'
        $instructionsRoot = Join-Path $TestDrive 'instructions-rm'
        Invoke-Script 'install-copilot.ps1' @('-SettingsPath', $settings, '-InstructionsRoot', $instructionsRoot, '-NoPersist') | Out-Null

        $r = Invoke-Script 'install-copilot.ps1' @('-SettingsPath', $settings, '-InstructionsRoot', $instructionsRoot, '-NoPersist', '-Remove')
        $r.Code | Should -Be 0
        $r.Json.removed | Should -BeTrue

        $cfg = Get-Content -Raw $settings | ConvertFrom-Json -AsHashtable
        $cfg['mcp.servers'].Contains('vault') | Should -BeFalse
        Test-Path (Join-Path $instructionsRoot 'vault' 'vault-global.instructions.md') | Should -BeFalse
    }
}

Describe 'docker-backed scripts (Linux/CI — shimmed docker)' -Skip:(-not $IsLinux) {
    BeforeAll {
        $script:repo = New-TempGitRepo
        $script:shimDir = New-DockerShim
        $script:oldPath = $env:PATH
        $env:PATH = "$shimDir$([IO.Path]::PathSeparator)$env:PATH"
    }
    AfterAll {
        $env:PATH = $script:oldPath
        Remove-Item -Recurse -Force $script:repo, $script:shimDir -ErrorAction SilentlyContinue
        $env:VAULT_FAKE_IMAGE_MISSING = $null; $env:VAULT_FAKE_INSPECT = $null
        $env:VAULT_FAKE_BUILD_FAIL = $null
    }

    It 'index-repo.ps1 exits 6 when the image is missing and no -Build' {
        $env:VAULT_FAKE_IMAGE_MISSING = '1'
        try {
            $r = Invoke-Script 'index-repo.ps1' @('-Path', $repo)
            $r.Code | Should -Be 6
            $r.Json.error | Should -Match 'not found'
        }
        finally { $env:VAULT_FAKE_IMAGE_MISSING = $null }
    }

    It 'index-repo.ps1 -Rebuild forces a build even when the image exists' {
        # Image present (default shim) — without -Rebuild no build runs.
        # Make `docker build` fail; -Rebuild must still invoke it, so the
        # failure surfaces as exit 6 (proves the build path was taken).
        $env:VAULT_FAKE_BUILD_FAIL = '1'
        try {
            $r = Invoke-Script 'index-repo.ps1' @('-Path', $repo, '-Rebuild')
            $r.Code | Should -Be 6
            $r.Json.error | Should -Match 'build failed'
        }
        finally { $env:VAULT_FAKE_BUILD_FAIL = $null }
    }

    It 'index-repo.ps1 -Rebuild then runs normally when the build succeeds' {
        $r = Invoke-Script 'index-repo.ps1' @('-Path', $repo, '-Rebuild', '-Wait')
        $r.Code | Should -Be 0
        $r.Json.waited | Should -BeTrue
        $r.Json.indexer.chunks | Should -Be 9
    }

    It 'index-repo.ps1 -Wait parses the indexer JSON summary' {
        $r = Invoke-Script 'index-repo.ps1' @('-Path', $repo, '-Wait')
        $r.Code | Should -Be 0
        $r.Json.waited | Should -BeTrue
        $r.Json.indexer.chunks | Should -Be 9
    }

    It 'index-repo.ps1 (background) returns a container id' {
        $r = Invoke-Script 'index-repo.ps1' @('-Path', $repo)
        $r.Code | Should -Be 0
        $r.Json.container_id | Should -Be 'cafef00dba5e'
        $r.Json.waited | Should -BeFalse
    }

    It 'index-status.ps1 maps exited|0 -> done/exit_code' {
        $r = Invoke-Script 'index-status.ps1' @('abc123')
        $r.Code | Should -Be 0
        $r.Json.done | Should -BeTrue
        $r.Json.exit_code | Should -Be 0
    }

    It 'index-status.ps1 reports a vanished container as gone/done' {
        $env:VAULT_FAKE_INSPECT = 'MISSING'
        try {
            $r = Invoke-Script 'index-status.ps1' @('ghost')
            $r.Json.state | Should -Be 'gone'
            $r.Json.done | Should -BeTrue
        }
        finally { $env:VAULT_FAKE_INSPECT = $null }
    }
}
