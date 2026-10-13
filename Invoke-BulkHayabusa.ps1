#Requires -Version 5.1

<#
.SYNOPSIS
    Runs Hayabusa across a folder of per-host KAPE collections.

.DESCRIPTION
    Point InputRoot at a parent folder holding one entry per host: a loose
    KAPE output folder, a ZIP, or a VHDX or VHD. Each host gets its own
    Hayabusa run, alert report and timeline under OutputRoot, and the results
    are rolled up into a cross-host triage view.

    Each top-level entry of InputRoot is a collection. Folders, .zip, .vhd
    and .vhdx are collections. Everything else is skipped. Collections are
    run one at a time, each into OutputRoot\<Collection>, and recorded in
    OutputRoot\run_manifest.csv keyed by collection name. Every run writes
    a provenance record to OutputRoot\_runs.

    A collection already Completed or CompletedWithErrors is skipped on a
    rerun unless -Force is given. One collection failing is recorded and
    the run moves on to the next.

    When the batch finishes, the cross-host rollup is rebuilt:
    triage_rules.csv, triage_hosts.csv and triage_dashboard.html under
    OutputRoot.
    Invoke-HayabusaRollup.ps1 rebuilds the same files from an existing
    OutputRoot without rerunning anything.

    Settings are resolved in this order: command line, then the config file
    given by -ConfigPath, then built-in defaults.

    A normal run prints one progress line per collection and a short
    summary at the end, through the information stream. Problems are
    warnings. -Verbose adds the detail. -InformationAction SilentlyContinue
    hides the progress lines.

.PARAMETER InputRoot
    Parent folder holding one entry per host.

.PARAMETER OutputRoot
    Where per-host output, the manifest, run metadata and the rollup are
    written. Created if missing. Must not be inside InputRoot.

.PARAMETER HayabusaPath
    Full path to hayabusa.exe.

.PARAMETER MinLevel
    Severity floor passed to Hayabusa: informational, low, medium, high,
    critical or emergency. Defaults to high. When given on the
    command line it overrides MinLevel or ExactLevel from the config file.

.PARAMETER Threads
    Thread count passed to Hayabusa. Omit to let Hayabusa decide.

.PARAMETER Force
    Rerun collections already recorded as Completed or CompletedWithErrors.

.PARAMETER KeepArtifacts
    Keep the extracted ZIP and the differencing disk after each host
    finishes, for debugging. Disk images are always dismounted. Off by
    default.

.PARAMETER ConfigPath
    Optional engagement config file (.psd1). Loaded as data only with
    Import-PowerShellDataFile. See config\engagement.example.psd1.

.EXAMPLE
    .\Invoke-BulkHayabusa.ps1 -InputRoot D:\Cases\Case01\KAPE -OutputRoot D:\Cases\Case01\Hayabusa -HayabusaPath D:\Tools\hayabusa\hayabusa.exe

.EXAMPLE
    .\Invoke-BulkHayabusa.ps1 -InputRoot D:\Cases\Case01\KAPE -OutputRoot D:\Cases\Case01\Hayabusa -HayabusaPath D:\Tools\hayabusa\hayabusa.exe -ConfigPath D:\Cases\Case01\engagement.psd1 -MinLevel medium
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$InputRoot,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputRoot,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$HayabusaPath,

    [ValidateSet('informational', 'low', 'medium', 'high', 'critical', 'emergency')]
    [string]$MinLevel = 'high',

    [ValidateRange(1, 256)]
    [int]$Threads,

    [switch]$Force,

    [switch]$KeepArtifacts,

    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$ConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Progress and the end-of-run summary go to the information stream, which
# PowerShell hides by default. Show it unless the caller chose otherwise.
if (-not $PSBoundParameters.ContainsKey('InformationAction')) {
    $InformationPreference = 'Continue'
}

$ToolVersion = '0.6.2'

$libDir = Join-Path -Path $PSScriptRoot -ChildPath 'lib'
foreach ($lib in @('Paths', 'Elevation', 'Config', 'Manifest', 'RunMeta', 'Archive', 'Discovery', 'DiskImage', 'Resolve', 'Hayabusa', 'Results', 'Batch', 'Rollup', 'Dashboard')) {
    . (Join-Path -Path $libDir -ChildPath "$lib.ps1")
}

# Paths
$InputRoot = ConvertTo-NormalizedPath -Path $InputRoot
$OutputRoot = ConvertTo-NormalizedPath -Path $OutputRoot
$HayabusaPath = ConvertTo-NormalizedPath -Path $HayabusaPath

if (Test-PathIsWithin -Path $OutputRoot -Parent $InputRoot) {
    throw "OutputRoot ($OutputRoot) must not be inside InputRoot ($InputRoot). Output would be picked up as a host and written next to evidence."
}

# Settings
$config = $null
if ($PSBoundParameters.ContainsKey('ConfigPath')) {
    $config = Import-EngagementConfig -Path (ConvertTo-NormalizedPath -Path $ConfigPath)
    Write-Verbose "Loaded config $($config.Path) (SHA256 $($config.Sha256))"
}

$commandLine = @{}
if ($PSBoundParameters.ContainsKey('MinLevel')) {
    $commandLine['MinLevel'] = $MinLevel
}

$resolved = Resolve-RunSetting -CommandLine $commandLine -Config $config -HayabusaPath $HayabusaPath

$threadsValue = $null
if ($PSBoundParameters.ContainsKey('Threads')) {
    $threadsValue = $Threads
}

# Discovery reads InputRoot and lists ZIP entries. Nothing is extracted,
# mounted or written until the checks below pass.
$collections = @(Get-InputCollection -InputRoot $InputRoot)
Assert-UniqueCollectionName -Collections $collections
Assert-CollectionNameAllowed -Collections $collections
Write-Verbose "Discovered $($collections.Count) collection(s)."

# ZIPs this tool cannot extract: one short warning line each, listed here
# before a long run starts, then the advice once in normal output. The
# collection's own progress line later refers back to this warning.
$unreadableZips = @($collections | Where-Object { $_.InputType -eq 'Zip' -and $null -ne $_.Zip -and -not $_.Zip.Readable })
if ($unreadableZips.Count -gt 0) {
    foreach ($z in $unreadableZips) {
        Write-Warning "$($z.Source) can't be extracted by this tool ($(Get-ZipReadReasonText -Info $z.Zip))."
    }
    Write-Information '  To include them, extract each one yourself, put the extracted folder in InputRoot, and rerun. Hosts already done are skipped.'
    foreach ($z in $unreadableZips) {
        $images = @($z.Zip.ImageEntries)
        if ($images.Count -gt 0) {
            $leaf = ($images | ForEach-Object { ($_ -split '[\\/]')[-1] }) -join ', '
            Write-Information "  $($z.Source) holds a disk image: put the extracted $leaf directly in InputRoot."
        }
    }
}

# Fail before anything is written if disk images need an elevated session.
Assert-ElevationForContainer -Collections $collections

if (-not (Test-Path -LiteralPath $resolved.Selection.RulesPath)) {
    throw "RulesPath not found: $($resolved.Selection.RulesPath). Run 'hayabusa.exe update-rules' once at the start of the engagement, or set RulesPath in the config file."
}

# Provenance for run-meta. A failed version read is recorded, not fatal.
$hayabusaVersion = Get-HayabusaVersion -HayabusaPath $HayabusaPath
if ($null -ne $hayabusaVersion.Error) {
    Write-Warning "Could not read the Hayabusa version: $($hayabusaVersion.Error)"
}
$rulesVersion = Get-RulesVersion -RulesPath $resolved.Selection.RulesPath
Write-Verbose "Hayabusa: $($hayabusaVersion.Version). Rules: $($rulesVersion.Summary)."

# Run setup
if (-not (Test-Path -LiteralPath $OutputRoot -PathType Container)) {
    New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
    Write-Verbose "Created OutputRoot: $OutputRoot"
}

$runId = [guid]::NewGuid().ToString()
$startedUtc = (Get-Date).ToUniversalTime()

$manifestPath = Join-Path -Path $OutputRoot -ChildPath 'run_manifest.csv'
Initialize-RunManifest -Path $manifestPath | Out-Null
$added = Add-PendingCollection -Path $manifestPath -Collections $collections -RunId $runId
Write-Verbose "Manifest: $added new collection(s) recorded as Pending."

$runMeta = New-RunMeta `
    -RunId $runId `
    -StartedUtc $startedUtc `
    -ToolVersion $ToolVersion `
    -InputRoot $InputRoot `
    -OutputRoot $OutputRoot `
    -HayabusaPath $HayabusaPath `
    -Resolved $resolved `
    -Config $config `
    -Collections $collections `
    -HayabusaVersion $hayabusaVersion `
    -RulesVersion $rulesVersion `
    -Threads $threadsValue `
    -Force $Force.IsPresent `
    -KeepArtifacts $KeepArtifacts.IsPresent

$runMetaPath = Get-RunMetaPath -OutputRoot $OutputRoot -StartedUtc $startedUtc -RunId $runId
Save-RunMeta -Path $runMetaPath -RunMeta $runMeta | Out-Null

Write-Verbose "RunId $runId"
Write-Verbose "Manifest: $manifestPath"
Write-Verbose "Run metadata: $runMetaPath"

$batch = Invoke-CollectionBatch -Collections $collections -ManifestPath $manifestPath -OutputRoot $OutputRoot `
    -HayabusaPath $HayabusaPath -Resolved $resolved -Threads $threadsValue -RunId $runId `
    -Force:$Force -KeepArtifacts:$KeepArtifacts

# A rollup failure is recorded and reported, and never hides the batch
# results already in the manifest.
$rollupRecord = [ordered]@{ HostsCsv = $null; RulesCsv = $null; Dashboard = $null; HostCount = $null; RuleCount = $null; Error = $null }
try {
    $rollup = Invoke-Rollup -OutputRoot $OutputRoot
    $rollupRecord.HostsCsv = $rollup.HostsCsv
    $rollupRecord.RulesCsv = $rollup.RulesCsv
    $rollupRecord.Dashboard = $rollup.Dashboard
    $rollupRecord.HostCount = $rollup.HostCount
    $rollupRecord.RuleCount = $rollup.RuleCount
}
catch {
    $rollupRecord.Error = $_.Exception.Message
    Write-Warning "Rollup failed: $($_.Exception.Message). Rebuild it with Invoke-HayabusaRollup.ps1 -OutputRoot $OutputRoot"
}

$runMeta['CompletedUtc'] = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
$runMeta['Summary'] = $batch
$runMeta['Rollup'] = $rollupRecord
Save-RunMeta -Path $runMetaPath -RunMeta $runMeta -Update | Out-Null

Write-Information ("Done: {0} processed, {1} completed, {2} completed with errors, {3} failed, {4} skipped." -f
    $batch.Processed, $batch.Completed, $batch.CompletedWithErrors, $batch.Failed, $batch.Skipped)
if ($null -eq $rollupRecord.Error) {
    Write-Information "Output is in $OutputRoot. Open triage_dashboard.html there to start triage."
}
else {
    Write-Information "Output is in $OutputRoot. The dashboard could not be built, see the warning above."
}

[pscustomobject]@{
    RunId        = $runId
    ManifestPath = $manifestPath
    RunMetaPath  = $runMetaPath
    Summary      = $batch
    Rollup       = $rollupRecord
    Collections  = $collections
}
