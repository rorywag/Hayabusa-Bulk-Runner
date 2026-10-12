# Shared setup for the test suite. Dot-source from a BeforeAll block:
#
#     BeforeAll { . (Join-Path $PSScriptRoot 'Helpers/TestHelpers.ps1') }
#
# Loads every lib file into the test's scope and provides fixture builders.
# Every fixture is synthetic and built under $TestDrive at test time.

$script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:FixtureRoot = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'fixtures'
$script:FakeHayabusaScript = Join-Path -Path $PSScriptRoot -ChildPath 'FakeHayabusa.ps1'
$script:MainScript = Join-Path -Path $script:RepoRoot -ChildPath 'Invoke-BulkHayabusa.ps1'
$script:RollupScript = Join-Path -Path $script:RepoRoot -ChildPath 'Invoke-HayabusaRollup.ps1'

$script:LibOrder = @('Paths', 'Elevation', 'Config', 'Manifest', 'RunMeta', 'Archive', 'Discovery', 'DiskImage', 'Resolve', 'Hayabusa', 'Results', 'Batch', 'Rollup', 'Dashboard')
foreach ($lib in $script:LibOrder) {
    . (Join-Path -Path $script:RepoRoot -ChildPath "lib/$lib.ps1")
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$script:TestOnWindows = ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
$script:TimelineHeader = '"Timestamp","Computer","Channel","EventID","Level","RecordID","RuleTitle","Details","RuleID"'

function Join-TestPath {
    # Joins any number of segments with the platform separator.
    param([Parameter(Mandatory, ValueFromRemainingArguments)][string[]]$Part)
    $p = $Part[0]
    for ($i = 1; $i -lt $Part.Count; $i++) {
        foreach ($seg in ($Part[$i] -split '[\\/]')) {
            if ($seg.Length -gt 0) { $p = Join-Path -Path $p -ChildPath $seg }
        }
    }
    return $p
}

function New-TestDirectory {
    param([Parameter(Mandatory)][string]$Path)
    # Only create it when missing. On 5.1, New-Item -Force fails on a drive root.
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
    return $Path
}

function Write-TestText {
    # UTF-8 without a BOM on both 5.1 and 7.
    param([Parameter(Mandatory)][string]$Path, [AllowEmptyCollection()][AllowEmptyString()][string[]]$Line = @())
    New-TestDirectory -Path (Split-Path -Parent $Path) | Out-Null
    [System.IO.File]::WriteAllLines($Path, [string[]]$Line, (New-Object System.Text.UTF8Encoding($false)))
    return $Path
}

function New-TestByteArray {
    param([Parameter(Mandatory)][int]$Count, [switch]$Random)
    $b = New-Object byte[] $Count
    if ($Random) { (New-Object System.Random 42).NextBytes($b) }
    return , $b
}

function New-TestZip {
    # Entries is an ordered dictionary of entry name to byte[] or string.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][System.Collections.IDictionary]$Entries)
    New-TestDirectory -Path (Split-Path -Parent $Path) | Out-Null
    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::CreateNew)
    $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($k in $Entries.Keys) {
            $entry = $zip.CreateEntry($k, [System.IO.Compression.CompressionLevel]::Optimal)
            $s = $entry.Open()
            $v = $Entries[$k]
            if ($v -is [string]) { $v = [System.Text.Encoding]::UTF8.GetBytes($v) }
            $bytes = [byte[]]$v
            $s.Write($bytes, 0, $bytes.Length)
            $s.Dispose()
        }
    }
    finally {
        $zip.Dispose()
        $fs.Dispose()
    }
    return $Path
}

function Find-ZipSignature {
    param([byte[]]$Bytes, [uint32]$Signature, [int]$Start = 0)
    for ($i = $Start; $i -le $Bytes.Length - 4; $i++) {
        if ([BitConverter]::ToUInt32($Bytes, $i) -eq $Signature) { return $i }
    }
    return -1
}

function Edit-ZipHeader {
    <#
    Patches header fields of every entry in a ZIP, in both the local headers
    and the central directory. Method sets the compression method, Flags
    ORs in general-purpose flag bits, DeclaredSize sets the uncompressed size.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$Method = -1,
        [int]$Flags = 0,
        [long]$DeclaredSize = -1
    )
    $b = [System.IO.File]::ReadAllBytes($Path)
    foreach ($sig in @(@(0x04034b50, 6, 8, 22), @(0x02014b50, 8, 10, 24))) {
        $pos = 0
        while (($pos = Find-ZipSignature -Bytes $b -Signature ([uint32]$sig[0]) -Start $pos) -ge 0) {
            if ($Flags -ne 0) {
                $f = [BitConverter]::ToUInt16($b, $pos + $sig[1]) -bor $Flags
                [BitConverter]::GetBytes([uint16]$f).CopyTo($b, $pos + $sig[1])
            }
            if ($Method -ge 0) {
                [BitConverter]::GetBytes([uint16]$Method).CopyTo($b, $pos + $sig[2])
            }
            if ($DeclaredSize -ge 0) {
                [BitConverter]::GetBytes([uint32]$DeclaredSize).CopyTo($b, $pos + $sig[3])
            }
            $pos += 4
        }
    }
    [System.IO.File]::WriteAllBytes($Path, $b)
}

function New-TimelineRow {
    param([string]$Computer, [string]$Level, [string]$Title)
    $fields = @('2026-10-01 10:00:00.000 +00:00', $Computer, 'Sec', '4624', $Level, '1', $Title, 'd', 'id')
    return (($fields | ForEach-Object { '"' + ([string]$_).Replace('"', '""') + '"' }) -join ',')
}

function New-TimelineRowSet {
    param([string]$Computer, [string]$Level, [string]$Title, [int]$Count)
    for ($i = 0; $i -lt $Count; $i++) { New-TimelineRow -Computer $Computer -Level $Level -Title $Title }
}

function Get-TestPowerShellPath {
    return (Get-Process -Id $PID).Path
}

function New-FakeHayabusa {
    <#
    Creates a launcher for FakeHayabusa.ps1 in Directory, plus a rules folder
    beside it, and returns the launcher path. The launcher runs the fake as
    its own process with the same PowerShell that is running the tests.
    #>
    param([Parameter(Mandatory)][string]$Directory)
    New-TestDirectory -Path $Directory | Out-Null
    $rules = New-TestDirectory -Path (Join-Path -Path $Directory -ChildPath 'rules')
    Write-TestText -Path (Join-Path -Path $rules -ChildPath 'r.yml') -Line @('title: synthetic') | Out-Null
    $hostExe = Get-TestPowerShellPath
    if ($script:TestOnWindows) {
        $launcher = Join-Path -Path $Directory -ChildPath 'hayabusa.cmd'
        Write-TestText -Path $launcher -Line @(
            '@echo off'
            "`"$hostExe`" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$script:FakeHayabusaScript`" %*"
            'exit /b %ERRORLEVEL%'
        ) | Out-Null
    }
    else {
        $launcher = Join-Path -Path $Directory -ChildPath 'hayabusa'
        Write-TestText -Path $launcher -Line @(
            '#!/bin/sh'
            "exec `"$hostExe`" -NoProfile -NonInteractive -File `"$script:FakeHayabusaScript`" `"`$@`""
        ) | Out-Null
        & chmod +x $launcher
    }
    return $launcher
}

function New-FakeHost {
    # A Loose collection folder with a fake.behavior file and timeline CSVs.
    param(
        [Parameter(Mandatory)][string]$InputRoot,
        [Parameter(Mandatory)][string]$Name,
        [string]$Behavior = "EXIT=0`nCSV=r.csv",
        [System.Collections.IDictionary]$Files = @{}
    )
    $d = New-TestDirectory -Path (Join-Path -Path $InputRoot -ChildPath $Name)
    Write-TestText -Path (Join-Path -Path $d -ChildPath 'fake.behavior') -Line ($Behavior -split "`n") | Out-Null
    foreach ($k in $Files.Keys) {
        Write-TestText -Path (Join-Path -Path $d -ChildPath $k) -Line ([string[]]$Files[$k]) | Out-Null
    }
    return $d
}

function Get-ThrownMessage {
    # Returns the message of the error a scriptblock throws, or $null.
    param([Parameter(Mandatory)][scriptblock]$ScriptBlock)
    try {
        & $ScriptBlock 3>$null | Out-Null
        return $null
    }
    catch {
        return $_.Exception.Message
    }
}

function Test-TestElevated {
    if (-not $script:TestOnWindows) { return $false }
    $principal = New-Object System.Security.Principal.WindowsPrincipal([System.Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-TestRunSetting {
    # Default resolved settings for a fake Hayabusa path.
    param([Parameter(Mandatory)][string]$HayabusaPath)
    return (Resolve-RunSetting -CommandLine @{} -Config $null -HayabusaPath $HayabusaPath)
}

function New-RollupFixture {
    <#
    Builds a finished OutputRoot without running anything: a manifest with
    every status, per-host timeline CSVs (including the malicious fixture
    under a -HOST collection), and run-meta files for three runs with
    different severity floors. Returns the OutputRoot path.
    #>
    param([Parameter(Mandatory)][string]$OutputRoot)
    $out = New-TestDirectory -Path $OutputRoot
    $mp = Join-Path -Path $out -ChildPath 'run_manifest.csv'
    Initialize-RunManifest -Path $mp | Out-Null
    $h = $script:TimelineHeader
    $evil = '"><img src=x onerror=alert(1)>'
    $cweLog = Join-Path -Path (Join-Path -Path $out -ChildPath 'CWE') -ChildPath 'CWE_hayabusa.log'
    $spec = @(
        @{ C = 'WS01'; S = 'Completed'; H = 'WS01'; R = 'run1'; Csv = @($h) + @(New-TimelineRowSet -Computer 'WS01' -Level 'crit' -Title 'RuleA' -Count 2) + @(New-TimelineRowSet -Computer 'WS01' -Level 'high' -Title 'RuleB' -Count 3) + @(New-TimelineRow -Computer 'WS01' -Level 'high' -Title 'RuleF') + @(New-TimelineRow -Computer 'WS01' -Level 'med' -Title 'RuleC') + @(New-TimelineRow -Computer 'WS01' -Level 'low' -Title 'RuleD'); Html = $true; Log = $true }
        @{ C = 'WS02'; S = 'Completed'; H = 'WS02'; R = 'run1'; Csv = @($h) + @(New-TimelineRow -Computer 'WS02' -Level 'critical' -Title 'RuleA') + @(New-TimelineRow -Computer 'WS02' -Level 'High' -Title 'RuleB') + @(New-TimelineRow -Computer 'WS02' -Level 'medium' -Title 'RuleF'); Html = $true }
        @{ C = 'C'; S = 'Completed'; H = ''; R = 'run1'; Csv = @($h) }
        @{ C = 'FAILNOCSV'; S = 'Failed'; H = ''; R = 'run2'; E = 'Resolve: archive refused' }
        @{ C = 'FAILCSV'; S = 'Failed'; H = 'WS04'; R = 'run2'; E = 'Teardown: device busy'; Csv = @($h) + @(New-TimelineRow -Computer 'WS04' -Level 'high' -Title 'RuleE') }
        @{ C = 'CWE'; S = 'CompletedWithErrors'; H = 'WS05'; R = 'run2'; E = "Hayabusa exited with code 3. See $cweLog."; Csv = @($h) + @(New-TimelineRowSet -Computer 'WS05' -Level 'high' -Title 'RuleB' -Count 2) }
        @{ C = 'PEND'; S = 'Pending'; H = ''; R = 'run3'; Csv = @($h) + @(New-TimelineRowSet -Computer 'STALE' -Level 'crit' -Title 'StaleRule' -Count 9) }
        @{ C = 'RUN'; S = 'Running'; H = ''; R = 'run3'; Csv = @($h) + @(New-TimelineRowSet -Computer 'HALF' -Level 'crit' -Title 'HalfRule' -Count 9) }
        @{ C = 'MULTI'; S = 'Completed'; H = '[multiple]'; R = 'run1'; W = 'Multiple Computer values: DC01 (1), DC01.corp.local (1)'; Csv = @($h, (New-TimelineRow -Computer 'DC01' -Level 'crit' -Title 'RuleA'), (New-TimelineRow -Computer 'DC01.corp.local' -Level 'crit' -Title 'RuleA')) }
        @{ C = '-HOST'; S = 'Completed'; H = $evil; R = 'ghost'; Csv = [string[]](Get-Content -LiteralPath (Join-Path -Path $script:FixtureRoot -ChildPath 'malicious_timeline.csv')) }
        @{ C = 'BADCSV'; S = 'Completed'; H = 'WS09'; R = 'run1'; Csv = @('"Timestamp","Level"', '"x","high"') }
    )
    foreach ($e in $spec) {
        $warn = @(); if ($e.ContainsKey('W')) { $warn = @($e.W) }
        $err = @(); if ($e.ContainsKey('E')) { $err = @($e.E) }
        Set-RunManifestEntry -Path $mp -Collection $e.C -Source $e.C -RunId $e.R -InputType Loose -Status $e.S -HostName $e.H -WarningMessage $warn -ErrorMessage $err
        $p = Get-CollectionOutputPath -OutputRoot $out -Collection $e.C
        if ($e.ContainsKey('Csv')) { Write-TestText -Path $p.Csv -Line ([string[]]$e.Csv) | Out-Null }
        if ($e.ContainsKey('Html')) { Write-TestText -Path $p.Html -Line @('<html></html>') | Out-Null }
        if ($e.ContainsKey('Log')) { Write-TestText -Path $p.Log -Line @('log') | Out-Null }
    }
    $runs = New-TestDirectory -Path (Join-Path -Path $out -ChildPath '_runs')
    $metas = @(
        @{ File = 'run_meta_20261010T010000Z_run1.json'; M = @{ RunId = 'run1'; StartedUtc = '2026-10-10T01:00:00Z'; Selection = @{ MinLevel = 'high'; ExactLevel = $null; Profile = 'standard' }; Hayabusa = @{ Version = 'Hayabusa v4.1.0'; RulesVersion = 'newest rule file 2026-09-30T12:00:00Z, 4000 rule files' } } }
        @{ File = 'run_meta_20261010T020000Z_run2.json'; M = @{ RunId = 'run2'; StartedUtc = '2026-10-10T02:00:00Z'; Selection = @{ MinLevel = $null; ExactLevel = 'critical'; Profile = 'standard' }; Hayabusa = @{ Version = 'Hayabusa v4.1.0'; RulesVersion = 'x' } } }
        @{ File = 'run_meta_20261010T030000Z.json'; M = @{ RunId = 'run3'; StartedUtc = '2026-10-10T03:00:00Z'; Selection = @{ MinLevel = 'medium'; Profile = 'verbose' }; Hayabusa = @{ Version = $null; RulesVersion = $null } } }
    )
    foreach ($m in $metas) {
        Write-TestText -Path (Join-Path -Path $runs -ChildPath $m.File) -Line @(ConvertTo-Json -InputObject $m.M -Depth 5) | Out-Null
    }
    return $out
}

function Get-FileHashMap {
    # Hash of every file under a folder, keyed by full path.
    param([Parameter(Mandatory)][string]$Path)
    $map = @{}
    foreach ($f in (Get-ChildItem -LiteralPath $Path -Recurse -File)) {
        $map[$f.FullName] = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
    }
    return $map
}

function Test-Utf8Bom {
    param([Parameter(Mandatory)][string]$Path)
    $b = [System.IO.File]::ReadAllBytes($Path)
    return (($b.Length -ge 3) -and ($b[0] -eq 0xEF) -and ($b[1] -eq 0xBB) -and ($b[2] -eq 0xBF))
}
