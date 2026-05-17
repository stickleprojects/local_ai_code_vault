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
    AfterAll  { Remove-Item -Recurse -Force $script:repo -ErrorAction SilentlyContinue }

    It 'emits a stable {repo_id, repo_root, slug} JSON object' {
        $r = Invoke-Script 'repo-id.ps1' @('-Path', $repo)
        $r.Code | Should -Be 0
        $r.Json.ok | Should -BeTrue
        $r.Json.repo_id | Should -Match '^[a-z0-9-]+-[0-9a-f]{8}$'
    }

    It 'is deterministic and identical from a subdirectory' {
        $sub = Join-Path $repo 'pkg'; New-Item -ItemType Directory -Path $sub | Out-Null
        $a = (Invoke-Script 'repo-id.ps1' @('-Path', $repo, '-Raw')).Raw.Trim()
        $b = (Invoke-Script 'repo-id.ps1' @('-Path', $sub,  '-Raw')).Raw.Trim()
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
            embed_dim = 3584; qdrant_connected = $true } })
        try {
            $env:VAULT_API_BASE = $stub.Base
            $r = Invoke-Script 'vault-health.ps1' @()
            $r.Code | Should -Be 0
            $r.Json.reachable | Should -BeTrue
            $r.Json.embed_dim | Should -Be 3584
        } finally { $env:VAULT_API_BASE = $null; Stop-StubApi $stub }
    }

    It 'exits 4 (StackDown) when nothing is listening' {
        $env:VAULT_API_BASE = "http://localhost:$(Get-FreePort)"
        try {
            $r = Invoke-Script 'vault-health.ps1' @()
            $r.Code | Should -Be 4
            $r.Json.ok | Should -BeFalse
        } finally { $env:VAULT_API_BASE = $null }
    }
}

Describe 'vault-status.ps1 — registration & staleness' {
    BeforeAll { $script:repo = New-TempGitRepo }
    AfterAll  { Remove-Item -Recurse -Force $script:repo -ErrorAction SilentlyContinue }

    It 'registered:false on 404' {
        $stub = Start-StubApi @(@{ match = '^/api/repos/'; status = 404; body = @{ detail = 'no' } })
        try {
            $env:VAULT_API_BASE = $stub.Base
            $r = Invoke-Script 'vault-status.ps1' @('-Path', $repo)
            $r.Code | Should -Be 0
            $r.Json.registered | Should -BeFalse
            $r.Json.head_sha   | Should -Not -BeNullOrEmpty
        } finally { $env:VAULT_API_BASE = $null; Stop-StubApi $stub }
    }

    It 'stale:false when indexed SHA == HEAD' {
        $head = (& git -C $repo rev-parse HEAD).Trim()
        $stub = Start-StubApi @(@{ match = '^/api/repos/'; status = 200; body = @{
            repo_id = 'x'; indexed_sha = $head; indexed_at = '2026-01-01T00:00:00Z' } })
        try {
            $env:VAULT_API_BASE = $stub.Base
            $r = Invoke-Script 'vault-status.ps1' @('-Path', $repo)
            $r.Json.registered | Should -BeTrue
            $r.Json.stale | Should -BeFalse
            $r.Json.changed_files | Should -Be @()
        } finally { $env:VAULT_API_BASE = $null; Stop-StubApi $stub }
    }

    It 'stale:true + changed_files when indexed SHA is an older commit' {
        $first = (& git -C $repo rev-parse HEAD).Trim()
        'two' | Set-Content (Join-Path $repo 'file2.py')
        & git -C $repo add -A; & git -C $repo commit -qm 'B'
        $stub = Start-StubApi @(@{ match = '^/api/repos/'; status = 200; body = @{
            repo_id = 'x'; indexed_sha = $first; indexed_at = '2026-01-01T00:00:00Z' } })
        try {
            $env:VAULT_API_BASE = $stub.Base
            $r = Invoke-Script 'vault-status.ps1' @('-Path', $repo)
            $r.Json.stale | Should -BeTrue
            $r.Json.changed_files | Should -Contain 'file2.py'
        } finally { $env:VAULT_API_BASE = $null; Stop-StubApi $stub }
    }
}

Describe 'query.ps1' {
    BeforeAll { $script:repo = New-TempGitRepo }
    AfterAll  { Remove-Item -Recurse -Force $script:repo -ErrorAction SilentlyContinue }

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
        } finally { $env:VAULT_API_BASE = $null; Stop-StubApi $stub }
    }

    It 'passes results through on 200' {
        $stub = Start-StubApi @(@{ match = '^/api/query/'; status = 200; body = @{
            repo_id = 'x'; query = 'q'; results = @(@{ path = 'a.py'; language = 'python'
            start_line = 1; end_line = 2; code = 'def f(): ...'; score = 0.5 }) } })
        try {
            $env:VAULT_API_BASE = $stub.Base
            $r = Invoke-Script 'query.ps1' @('q', '-Path', $repo)
            $r.Code | Should -Be 0
            $r.Json.count | Should -Be 1
            $r.Json.results[0].path | Should -Be 'a.py'
        } finally { $env:VAULT_API_BASE = $null; Stop-StubApi $stub }
    }
}

Describe 'vault-inspect.ps1 — AD-9 read-only' {
    BeforeAll { $script:repo = New-TempGitRepo }
    AfterAll  { Remove-Item -Recurse -Force $script:repo -ErrorAction SilentlyContinue }

    It 'exits 5 when stats 404' {
        $stub = Start-StubApi @(@{ match = '/stats$'; status = 404; body = @{ detail = 'no' } })
        try {
            $env:VAULT_API_BASE = $stub.Base
            (Invoke-Script 'vault-inspect.ps1' @('-Path', $repo)).Code | Should -Be 5
        } finally { $env:VAULT_API_BASE = $null; Stop-StubApi $stub }
    }

    It 'returns stats and (with -Files) a filtered inventory' {
        $stub = Start-StubApi @(
            @{ match = '/stats$'; status = 200; body = @{ repo_id = 'x'; indexed_sha = 's'
               indexed_at = 't'; file_count = 2; chunk_count = 5; skipped_count = 1
               languages = @(@{ language = 'python'; files = 2; chunks = 5 }) } },
            @{ match = '/files$'; status = 200; body = @{ repo_id = 'x'; total = 2; offset = 0
               limit = 100; files = @(
                 @{ path = 'a.py'; language = 'python'; chunk_count = 3 },
                 @{ path = 'b.ts'; language = 'typescript'; chunk_count = 2 }) } }
        )
        try {
            $env:VAULT_API_BASE = $stub.Base
            $r = Invoke-Script 'vault-inspect.ps1' @('-Path', $repo, '-Files', '-Language', 'python')
            $r.Code | Should -Be 0
            $r.Json.stats.chunk_count | Should -Be 5
            $r.Json.files.returned | Should -Be 1
            $r.Json.files.files[0].path | Should -Be 'a.py'
        } finally { $env:VAULT_API_BASE = $null; Stop-StubApi $stub }
    }
}

Describe 'install-git-hooks.ps1' {
    BeforeEach { $script:repo = New-TempGitRepo }
    AfterEach  { Remove-Item -Recurse -Force $script:repo -ErrorAction SilentlyContinue }

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
    }

    It 'index-repo.ps1 exits 6 when the image is missing and no -Build' {
        $env:VAULT_FAKE_IMAGE_MISSING = '1'
        try {
            $r = Invoke-Script 'index-repo.ps1' @('-Path', $repo)
            $r.Code | Should -Be 6
            $r.Json.error | Should -Match 'not found'
        } finally { $env:VAULT_FAKE_IMAGE_MISSING = $null }
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
        } finally { $env:VAULT_FAKE_INSPECT = $null }
    }
}
