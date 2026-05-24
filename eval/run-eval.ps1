[CmdletBinding()]
param(
    [string]$CorpusPath = (Join-Path $PSScriptRoot 'corpus'),
    [string]$QueriesPath = (Join-Path $PSScriptRoot 'queries.yaml'),
    [string]$Baseline = (Join-Path $PSScriptRoot 'baseline.json'),
    [switch]$UpdateBaseline,
    [double]$Tolerance = 0.0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$script:ExitCode = @{
    Ok = 0
    Usage = 2
    StackDown = 4
    Runtime = 1
}

function Write-ResultAndExit {
    param(
        [Parameter(Mandatory)]$Object,
        [int]$Code = 0
    )

    $payload = [ordered]@{}
    if ($Object -is [hashtable] -or $Object -is [System.Collections.Specialized.OrderedDictionary]) {
        foreach ($k in $Object.Keys) { $payload[$k] = $Object[$k] }
    } else {
        foreach ($p in $Object.PSObject.Properties) { $payload[$p.Name] = $p.Value }
    }

    if (-not $payload.Contains('ok')) { $payload['ok'] = ($Code -eq 0) }
    if (-not $payload.Contains('code')) { $payload['code'] = $Code }

    Write-Output ($payload | ConvertTo-Json -Depth 14 -Compress)
    exit $Code
}

function Normalize-PathLike {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $p = $Path -replace '\\', '/'
    while ($p.StartsWith('./')) { $p = $p.Substring(2) }
    return $p.Trim()
}

function Get-ObjValue {
    param(
        [AllowNull()]$Obj,
        [Parameter(Mandatory)][string]$Key
    )

    if ($null -eq $Obj) { return $null }
    if ($Obj -is [hashtable]) {
        if ($Obj.ContainsKey($Key)) { return $Obj[$Key] }
        return $null
    }
    if ($Obj -is [System.Collections.IDictionary]) {
        if ($Obj.Contains($Key)) { return $Obj[$Key] }
        return $null
    }
    $prop = $Obj.PSObject.Properties[$Key]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

function Invoke-JsonScript {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [object[]]$PositionalArgs = @(),
        [hashtable]$NamedArgs = @{}
    )

    $raw = & $ScriptPath @PositionalArgs @NamedArgs 2>$null
    $code = $LASTEXITCODE
    $body = $null
    if ($raw) {
        try { $body = ($raw -join "`n") | ConvertFrom-Json -AsHashtable } catch { $body = $null }
    }
    if ($null -eq $body) {
        $body = [ordered]@{ ok = ($code -eq 0); code = $code; raw = "$raw" }
    }

    [ordered]@{ code = $code; body = $body }
}

function Test-MatchesAnyPattern {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$Patterns
    )

    foreach ($pattern in @($Patterns)) {
        if ([string]::IsNullOrWhiteSpace($pattern)) { continue }
        $wc = [System.Management.Automation.WildcardPattern]::new($pattern, [System.Management.Automation.WildcardOptions]::IgnoreCase)
        if ($wc.IsMatch($Path)) { return $true }
    }
    return $false
}

function Average-OrNull {
    param([object[]]$Values)

    $vals = @()
    foreach ($v in @($Values)) {
        if ($null -eq $v) { continue }
        $vals += [double]$v
    }
    if ($vals.Count -eq 0) { return $null }
    return ($vals | Measure-Object -Average).Average
}

function Round-OrNull {
    param($Value)
    if ($null -eq $Value) { return $null }
    return [math]::Round([double]$Value, 6)
}

function Build-Aggregate {
    param([object[]]$CaseRows)

    $recalls = @()
    $mrrs = @()
    $noises = @()
    $defRanks = @()
    $symComp = @()

    foreach ($c in @($CaseRows)) {
        $metrics = Get-ObjValue -Obj $c -Key 'metrics'
        if ($null -eq $metrics) { continue }

        $recall = Get-ObjValue -Obj $metrics -Key 'recall_at_k'
        $mrr = Get-ObjValue -Obj $metrics -Key 'mrr'
        $noise = Get-ObjValue -Obj $metrics -Key 'noise_at_k'
        $def = Get-ObjValue -Obj $metrics -Key 'definition_rank_pass'
        $sym = Get-ObjValue -Obj $metrics -Key 'symbol_completeness'

        if ($null -ne $recall) { $recalls += [double]$recall }
        if ($null -ne $mrr) { $mrrs += [double]$mrr }
        if ($null -ne $noise) { $noises += [double]$noise }
        if ($null -ne $def) { $defRanks += (if ([bool]$def) { 1.0 } else { 0.0 }) }
        if ($null -ne $sym) { $symComp += [double]$sym }
    }

    $total = @($CaseRows).Count
    $passed = @(@($CaseRows) | Where-Object { [bool](Get-ObjValue -Obj $_ -Key 'passed') }).Count

    [ordered]@{
        case_count = $total
        passed_count = $passed
        pass_rate = Round-OrNull (if ($total -gt 0) { $passed / [double]$total } else { $null })
        recall_at_k = Round-OrNull (Average-OrNull $recalls)
        mrr = Round-OrNull (Average-OrNull $mrrs)
        noise_at_k = Round-OrNull (Average-OrNull $noises)
        definition_rank_pass_rate = Round-OrNull (Average-OrNull $defRanks)
        symbol_completeness = Round-OrNull (Average-OrNull $symComp)
    }
}

function Build-TagAggregates {
    param([object[]]$CaseRows)

    $tags = @{}
    foreach ($c in @($CaseRows)) {
        $caseTags = @(Get-ObjValue -Obj $c -Key 'tags')
        foreach ($t in $caseTags) {
            $tag = [string]$t
            if ([string]::IsNullOrWhiteSpace($tag)) { continue }
            if (-not $tags.ContainsKey($tag)) { $tags[$tag] = @() }
            $tags[$tag] += $c
        }
    }

    $out = [ordered]@{}
    foreach ($tag in ($tags.Keys | Sort-Object)) {
        $out[$tag] = Build-Aggregate -CaseRows $tags[$tag]
    }
    return $out
}

function New-TempEvalRepo {
    param([Parameter(Mandatory)][string]$SourceCorpus)

    $tmpRoot = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), ('vault-eval-' + [guid]::NewGuid().ToString('N')))
    $null = New-Item -ItemType Directory -Path $tmpRoot -Force
    Copy-Item -Path (Join-Path $SourceCorpus '*') -Destination $tmpRoot -Recurse -Force

    & git -C $tmpRoot init -q
    if ($LASTEXITCODE -ne 0) {
        throw "failed to initialize temp git repository for eval corpus"
    }

    & git -C $tmpRoot add .
    if ($LASTEXITCODE -ne 0) {
        throw "failed to stage eval corpus files in temp repo"
    }

    & git -C $tmpRoot -c user.email='eval@local' -c user.name='eval harness' commit -q -m 'eval corpus snapshot'
    if ($LASTEXITCODE -ne 0) {
        throw "failed to commit eval corpus files in temp repo"
    }

    return $tmpRoot
}

function Load-YamlDocument {
    param([Parameter(Mandatory)][string]$Path)

    $yamlText = Get-Content -LiteralPath $Path -Raw
    if ([string]::IsNullOrWhiteSpace($yamlText)) {
        return $null
    }

    $convertFromYaml = Get-Command -Name ConvertFrom-Yaml -ErrorAction SilentlyContinue
    if ($null -ne $convertFromYaml) {
        try {
            return ($yamlText | ConvertFrom-Yaml -Ordered)
        } catch {
            throw "failed to parse YAML file: $Path"
        }
    }

    if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
        throw 'PowerShell ConvertFrom-Yaml or python+PyYAML is required to parse YAML queries'
    }

    $json = & python -c "import json,sys,yaml; print(json.dumps(yaml.safe_load(open(sys.argv[1], encoding='utf-8').read())))" $Path 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($json)) {
        throw "failed to parse YAML file: $Path"
    }
    return ($json | ConvertFrom-Json -AsHashtable)
}

if (-not (Test-Path -LiteralPath $CorpusPath -PathType Container)) {
    Write-ResultAndExit -Object ([ordered]@{ error = "corpus path not found: $CorpusPath" }) -Code $script:ExitCode.Usage
}
if (-not (Test-Path -LiteralPath $QueriesPath -PathType Leaf)) {
    Write-ResultAndExit -Object ([ordered]@{ error = "queries file not found: $QueriesPath" }) -Code $script:ExitCode.Usage
}
if ($Tolerance -lt 0) {
    Write-ResultAndExit -Object ([ordered]@{ error = '-Tolerance must be >= 0' }) -Code $script:ExitCode.Usage
}

$scriptRoot = Split-Path -Parent $PSCommandPath
$scriptsDir = Join-Path (Split-Path -Parent $scriptRoot) 'scripts'
$healthScript = Join-Path $scriptsDir 'vault-health.ps1'
$indexScript = Join-Path $scriptsDir 'index-repo.ps1'
$querySmartScript = Join-Path $scriptsDir 'query-smart.ps1'

foreach ($requiredScript in @($healthScript, $indexScript, $querySmartScript)) {
    if (-not (Test-Path -LiteralPath $requiredScript -PathType Leaf)) {
        Write-ResultAndExit -Object ([ordered]@{ error = "required script not found: $requiredScript" }) -Code $script:ExitCode.Runtime
    }
}

$queries = $null
try {
    $queries = Load-YamlDocument -Path $QueriesPath
} catch {
    Write-ResultAndExit -Object ([ordered]@{ error = $_.Exception.Message }) -Code $script:ExitCode.Usage
}
if ($null -eq $queries) {
    Write-ResultAndExit -Object ([ordered]@{ error = "queries file is empty: $QueriesPath" }) -Code $script:ExitCode.Usage
}
$queries = @($queries)

$health = Invoke-JsonScript -ScriptPath $healthScript
if ($health.code -ne 0) {
    $err = Get-ObjValue -Obj $health.body -Key 'error'
    $out = [ordered]@{
        ok = $false
        code = $script:ExitCode.StackDown
        error = if ($err) { $err } else { 'vault stack is unavailable; run docker compose up -d' }
    }
    [Console]::Error.WriteLine('Vault stack is unavailable; run: docker compose up -d, then re-run eval.')
    Write-ResultAndExit -Object $out -Code $script:ExitCode.StackDown
}

$resolvedCorpus = (Resolve-Path -LiteralPath $CorpusPath).Path
$evalRepoPath = $resolvedCorpus
$tempRepo = $null

try {
    $gitTop = & git -C $resolvedCorpus rev-parse --show-toplevel 2>$null
    $gitTop = if ($LASTEXITCODE -eq 0) { "$gitTop".Trim() } else { '' }

    if ([string]::IsNullOrWhiteSpace($gitTop) -or (Normalize-PathLike $gitTop) -ne (Normalize-PathLike $resolvedCorpus)) {
        $tempRepo = New-TempEvalRepo -SourceCorpus $resolvedCorpus
        $evalRepoPath = $tempRepo
    }

    $index = Invoke-JsonScript -ScriptPath $indexScript -NamedArgs @{ Path = $evalRepoPath; Wait = $true }
    if ($index.code -ne 0) {
        $err = Get-ObjValue -Obj $index.body -Key 'error'
        Write-ResultAndExit -Object ([ordered]@{
                error = if ($err) { $err } else { 'indexing failed' }
                index = $index.body
            }) -Code $index.code
    }

    $qsCommand = Get-Command -Name $querySmartScript -ErrorAction Stop
    $supportsSymbolSwitch = $qsCommand.Parameters.ContainsKey('Symbol')
    $supportsModeParam = $qsCommand.Parameters.ContainsKey('Mode')

    $cases = @()
    foreach ($case in $queries) {
        $id = [string](Get-ObjValue -Obj $case -Key 'id')
        $queryText = [string](Get-ObjValue -Obj $case -Key 'query')
        $mode = [string](Get-ObjValue -Obj $case -Key 'mode')
        $kRaw = Get-ObjValue -Obj $case -Key 'k'
        $k = if ($null -ne $kRaw) { [int]$kRaw } else { 5 }
        $mustPass = [bool](Get-ObjValue -Obj $case -Key 'must_pass')
        $tags = @((Get-ObjValue -Obj $case -Key 'tags') | ForEach-Object { [string]$_ })

        $expectInTopK = @((Get-ObjValue -Obj $case -Key 'expect_in_top_k') | ForEach-Object { Normalize-PathLike ([string]$_) })
        $forbidInTopK = @((Get-ObjValue -Obj $case -Key 'forbid_in_top_k') | ForEach-Object { [string]$_ })
        $expectAll = @((Get-ObjValue -Obj $case -Key 'expect_all') | ForEach-Object { Normalize-PathLike ([string]$_) })
        $expectRankAbove = Get-ObjValue -Obj $case -Key 'expect_rank_above'

        $modeUnsupported = $false
        $queryBody = $null
        $queryCode = $script:ExitCode.Ok

        if ($mode -eq 'symbol' -and -not $supportsSymbolSwitch -and -not $supportsModeParam) {
            $modeUnsupported = $true
        } else {
            $named = @{ Path = $evalRepoPath; Limit = $k; DoNotIndex = $true }
            if ($mode -eq 'symbol') {
                if ($supportsSymbolSwitch) {
                    $named.Symbol = $true
                } elseif ($supportsModeParam) {
                    $named.Mode = 'symbol'
                }
            }
            $queryResult = Invoke-JsonScript -ScriptPath $querySmartScript -PositionalArgs @($queryText) -NamedArgs $named
            $queryCode = $queryResult.code
            $queryBody = $queryResult.body
        }

        $uniqueFiles = @()
        $rankByFile = @{}

        if ($null -ne $queryBody) {
            $results = @(Get-ObjValue -Obj $queryBody -Key 'results')
            foreach ($hit in $results) {
                $relPath = Normalize-PathLike ([string](Get-ObjValue -Obj $hit -Key 'path'))
                if ([string]::IsNullOrWhiteSpace($relPath)) { continue }
                if (-not $rankByFile.ContainsKey($relPath)) {
                    $uniqueFiles += $relPath
                    $rankByFile[$relPath] = $uniqueFiles.Count
                }
            }
        }

        $topKFiles = @($uniqueFiles | Select-Object -First $k)

        $recall = $null
        $mrr = $null
        if ($expectInTopK.Count -gt 0) {
            $firstRank = $null
            foreach ($file in $expectInTopK) {
                if ($rankByFile.ContainsKey($file)) {
                    $rank = [int]$rankByFile[$file]
                    if ($rank -le $k) {
                        if ($null -eq $firstRank -or $rank -lt $firstRank) {
                            $firstRank = $rank
                        }
                    }
                }
            }
            $recall = if ($null -ne $firstRank) { 1.0 } else { 0.0 }
            $mrr = if ($null -ne $firstRank) { 1.0 / [double]$firstRank } else { 0.0 }
        }

        $noiseAtK = $null
        if ($forbidInTopK.Count -gt 0) {
            if ($topKFiles.Count -gt 0) {
                $noiseHits = 0
                foreach ($f in $topKFiles) {
                    if (Test-MatchesAnyPattern -Path $f -Patterns $forbidInTopK) { $noiseHits++ }
                }
                $noiseAtK = $noiseHits / [double]$topKFiles.Count
            } else {
                $noiseAtK = 0.0
            }
        }

        $definitionRankPass = $null
        if ($null -ne $expectRankAbove) {
            $above = Normalize-PathLike ([string](Get-ObjValue -Obj $expectRankAbove -Key 'above'))
            $below = Normalize-PathLike ([string](Get-ObjValue -Obj $expectRankAbove -Key 'below'))
            if ($rankByFile.ContainsKey($above) -and $rankByFile.ContainsKey($below)) {
                $definitionRankPass = ([int]$rankByFile[$above] -lt [int]$rankByFile[$below])
            } else {
                $definitionRankPass = $false
            }
        }

        $symbolCompleteness = $null
        if ($expectAll.Count -gt 0) {
            $present = 0
            foreach ($f in $expectAll) {
                if ($rankByFile.ContainsKey($f)) { $present++ }
            }
            if ($expectAll.Count -gt 0) {
                $symbolCompleteness = $present / [double]$expectAll.Count
            }
        }

        $failedChecks = @()
        if ($modeUnsupported) {
            $failedChecks += 'mode_unsupported'
        }
        if ($queryCode -ne 0) {
            $failedChecks += "query_failed_code_$queryCode"
        }
        if ($null -ne $recall -and $recall -lt 1.0) {
            $failedChecks += 'expect_in_top_k'
        }
        if ($null -ne $noiseAtK -and $noiseAtK -gt 0.0) {
            $failedChecks += 'forbid_in_top_k'
        }
        if ($null -ne $definitionRankPass -and -not [bool]$definitionRankPass) {
            $failedChecks += 'expect_rank_above'
        }
        if ($null -ne $symbolCompleteness -and [math]::Abs([double]$symbolCompleteness - 1.0) -gt 1e-9) {
            $failedChecks += 'expect_all'
        }

        $passed = ($failedChecks.Count -eq 0)

        $caseOut = [ordered]@{
            id = $id
            query = $queryText
            mode = $mode
            k = $k
            must_pass = $mustPass
            tags = $tags
            passed = $passed
            failed_checks = $failedChecks
            top_k_files = $topKFiles
            metrics = [ordered]@{
                recall_at_k = Round-OrNull $recall
                mrr = Round-OrNull $mrr
                noise_at_k = Round-OrNull $noiseAtK
                definition_rank_pass = $definitionRankPass
                symbol_completeness = Round-OrNull $symbolCompleteness
            }
        }

        if ($modeUnsupported) {
            $caseOut['note'] = 'mode unsupported by query-smart.ps1'
        }

        $cases += $caseOut
    }

    $aggregate = Build-Aggregate -CaseRows $cases
    $byTag = Build-TagAggregates -CaseRows $cases

    $baselineObj = $null
    if (Test-Path -LiteralPath $Baseline -PathType Leaf) {
        try {
            $baselineObj = Get-Content -LiteralPath $Baseline -Raw | ConvertFrom-Json -AsHashtable
        } catch {
            Write-ResultAndExit -Object ([ordered]@{ error = "failed to parse baseline JSON: $Baseline" }) -Code $script:ExitCode.Usage
        }
    }

    $expectedFail = @()
    if ($null -ne $baselineObj) {
        $expectedFail = @((Get-ObjValue -Obj $baselineObj -Key 'expected_fail') | ForEach-Object { [string]$_ })
    }
    $expectedFailSet = @{}
    foreach ($id in $expectedFail) { $expectedFailSet[$id] = $true }

    $regressions = @()

    $baselineAgg = if ($null -ne $baselineObj) { Get-ObjValue -Obj $baselineObj -Key 'aggregate' } else { $null }
    if ($null -ne $baselineAgg) {
        $metricDirections = [ordered]@{
            recall_at_k = 'higher'
            mrr = 'higher'
            noise_at_k = 'lower'
            definition_rank_pass_rate = 'higher'
            symbol_completeness = 'higher'
        }

        foreach ($metric in $metricDirections.Keys) {
            $baseVal = Get-ObjValue -Obj $baselineAgg -Key $metric
            $curVal = Get-ObjValue -Obj $aggregate -Key $metric
            if ($null -eq $baseVal -or $null -eq $curVal) { continue }

            $base = [double]$baseVal
            $cur = [double]$curVal
            $direction = $metricDirections[$metric]
            $isRegression = $false

            if ($direction -eq 'higher') {
                if ($cur + $Tolerance -lt $base) { $isRegression = $true }
            } else {
                if ($cur - $Tolerance -gt $base) { $isRegression = $true }
            }

            if ($isRegression) {
                $regressions += [ordered]@{
                    type = 'aggregate_metric'
                    metric = $metric
                    baseline = Round-OrNull $base
                    current = Round-OrNull $cur
                    tolerance = $Tolerance
                }
            }
        }
    }

    $baselineCases = @{}
    if ($null -ne $baselineObj) {
        foreach ($bc in @((Get-ObjValue -Obj $baselineObj -Key 'cases'))) {
            if ($null -eq $bc) { continue }
            $bid = [string](Get-ObjValue -Obj $bc -Key 'id')
            if (-not [string]::IsNullOrWhiteSpace($bid)) {
                $baselineCases[$bid] = $bc
            }
        }
    }

    foreach ($c in $cases) {
        $id = [string](Get-ObjValue -Obj $c -Key 'id')
        $mustPass = [bool](Get-ObjValue -Obj $c -Key 'must_pass')
        $passed = [bool](Get-ObjValue -Obj $c -Key 'passed')

        if (-not $mustPass) { continue }
        if (-not $baselineCases.ContainsKey($id)) { continue }

        $basePassed = [bool](Get-ObjValue -Obj $baselineCases[$id] -Key 'passed')
        if ($basePassed -and -not $passed) {
            $regressions += [ordered]@{
                type = 'must_pass_flip'
                case_id = $id
                baseline = $true
                current = $false
            }
        }
    }

    $unexpectedMustPassFailures = @()
    foreach ($c in $cases) {
        $id = [string](Get-ObjValue -Obj $c -Key 'id')
        $mustPass = [bool](Get-ObjValue -Obj $c -Key 'must_pass')
        $passed = [bool](Get-ObjValue -Obj $c -Key 'passed')
        if ($mustPass -and -not $passed -and -not $expectedFailSet.ContainsKey($id)) {
            $unexpectedMustPassFailures += $id
        }
    }

    $exitCode = $script:ExitCode.Ok
    if ($unexpectedMustPassFailures.Count -gt 0 -or $regressions.Count -gt 0) {
        $exitCode = 1
    }

    $result = [ordered]@{
        ok = ($exitCode -eq 0)
        code = $exitCode
        corpus_path = $resolvedCorpus
        eval_repo_path = $evalRepoPath
        queries_path = (Resolve-Path -LiteralPath $QueriesPath).Path
        tolerance = $Tolerance
        expected_fail = $expectedFail
        cases = $cases
        aggregate = $aggregate
        by_tag = $byTag
        regressions = $regressions
        unexpected_must_pass_failures = $unexpectedMustPassFailures
    }

    [Console]::Error.WriteLine('Retrieval eval summary')
    [Console]::Error.WriteLine('ID                                PASS  MUST  MODE      RECALL  MRR     NOISE  DEF_RANK  SYM_COMP  NOTES')
    [Console]::Error.WriteLine('---------------------------------------------------------------------------------------------------------------')
    foreach ($c in $cases) {
        $m = Get-ObjValue -Obj $c -Key 'metrics'
        $line = '{0,-33} {1,-5} {2,-5} {3,-9} {4,-7} {5,-7} {6,-6} {7,-9} {8,-8} {9}' -f `
            ([string](Get-ObjValue -Obj $c -Key 'id')),
            ($(if ([bool](Get-ObjValue -Obj $c -Key 'passed')) { 'yes' } else { 'no' })),
            ($(if ([bool](Get-ObjValue -Obj $c -Key 'must_pass')) { 'yes' } else { 'no' })),
            ([string](Get-ObjValue -Obj $c -Key 'mode')),
            ([string](Get-ObjValue -Obj $m -Key 'recall_at_k')),
            ([string](Get-ObjValue -Obj $m -Key 'mrr')),
            ([string](Get-ObjValue -Obj $m -Key 'noise_at_k')),
            ([string](Get-ObjValue -Obj $m -Key 'definition_rank_pass')),
            ([string](Get-ObjValue -Obj $m -Key 'symbol_completeness')),
            (@(Get-ObjValue -Obj $c -Key 'failed_checks') -join ',')
        [Console]::Error.WriteLine($line)
    }
    [Console]::Error.WriteLine('')
    [Console]::Error.WriteLine(('Aggregate: recall_at_k={0}, mrr={1}, noise_at_k={2}, definition_rank_pass_rate={3}, symbol_completeness={4}, pass_rate={5}' -f `
            $aggregate.recall_at_k, $aggregate.mrr, $aggregate.noise_at_k, $aggregate.definition_rank_pass_rate, $aggregate.symbol_completeness, $aggregate.pass_rate))
    if ($unexpectedMustPassFailures.Count -gt 0) {
        [Console]::Error.WriteLine(('Unexpected must_pass failures: {0}' -f ($unexpectedMustPassFailures -join ', ')))
    }
    if ($regressions.Count -gt 0) {
        [Console]::Error.WriteLine(('Regressions: {0}' -f (($regressions | ConvertTo-Json -Compress))))
    }

    if ($UpdateBaseline) {
        $newExpectedFail = @()
        foreach ($c in $cases) {
            if ([bool](Get-ObjValue -Obj $c -Key 'must_pass') -and -not [bool](Get-ObjValue -Obj $c -Key 'passed')) {
                $newExpectedFail += [string](Get-ObjValue -Obj $c -Key 'id')
            }
        }

        $baselineOut = [ordered]@{
            generated_at = [DateTime]::UtcNow.ToString('o')
            corpus_path = $resolvedCorpus
            queries_path = (Resolve-Path -LiteralPath $QueriesPath).Path
            tolerance = $Tolerance
            expected_fail = $newExpectedFail
            aggregate = $aggregate
            cases = @($cases | ForEach-Object {
                    [ordered]@{
                        id = [string](Get-ObjValue -Obj $_ -Key 'id')
                        passed = [bool](Get-ObjValue -Obj $_ -Key 'passed')
                        must_pass = [bool](Get-ObjValue -Obj $_ -Key 'must_pass')
                        failed_checks = @(Get-ObjValue -Obj $_ -Key 'failed_checks')
                        metrics = Get-ObjValue -Obj $_ -Key 'metrics'
                    }
                })
        }

        $baselineDir = Split-Path -Parent $Baseline
        if ($baselineDir -and -not (Test-Path -LiteralPath $baselineDir)) {
            $null = New-Item -ItemType Directory -Path $baselineDir -Force
        }
        $baselineOut | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath $Baseline -Encoding utf8
    }

    Write-ResultAndExit -Object $result -Code $exitCode
}
finally {
    if ($tempRepo -and (Test-Path -LiteralPath $tempRepo)) {
        Remove-Item -LiteralPath $tempRepo -Recurse -Force -ErrorAction SilentlyContinue
    }
}
