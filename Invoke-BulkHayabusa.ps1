#Requires -Version 5.1

<#
.SYNOPSIS
    Runs Hayabusa across a folder of per-host KAPE collections.

.DESCRIPTION
    Point InputRoot at a parent folder holding one entry per host: a loose
    KAPE output folder, a ZIP, or a VHDX or VHD. Each host gets its own
    Hayabusa run, alert report and timeline under OutputRoot, and the results
    are rolled up into a cross-host triage view.

    Every run writes a provenance record to OutputRoot\_runs and records each
    host's outcome in OutputRoot\run_manifest.csv, keyed to the run's RunId.

    Settings are resolved in this order: command line, then the config file
    given by -ConfigPath, then built-in defaults.

.PARAMETER InputRoot
    Parent folder holding one entry per host.

.PARAMETER OutputRoot
    Where per-host output, the manifest, run metadata and the rollup are
    written. Created if missing. Must not be inside InputRoot.

.PARAMETER HayabusaPath
    Full path to hayabusa.exe.

.PARAMETER MinLevel
    Severity floor passed to Hayabusa. Defaults to high. When given on the
    command line it overrides MinLevel or ExactLevel from the config file.

.PARAMETER Threads
    Thread count passed to Hayabusa. Omit to let Hayabusa decide.

.PARAMETER Force
    Reprocess hosts that already have output.

.PARAMETER KeepArtifacts
    Keep extracted or mounted content after each host finishes, for
    debugging. Off by default.

.PARAMETER ConfigPath
    Optional engagement config file (.psd1). Loaded as data only with
    Import-PowerShellDataFile. See config\engagement.example.psd1.

.EXAMPLE
    .\Invoke-BulkHayabusa.ps1 -InputRoot D:\Case\KAPE -OutputRoot D:\Case\Hayabusa -HayabusaPath D:\Tools\hayabusa\hayabusa.exe

.EXAMPLE
    .\Invoke-BulkHayabusa.ps1 -InputRoot D:\Case\KAPE -OutputRoot D:\Case\Hayabusa -HayabusaPath D:\Tools\hayabusa\hayabusa.exe -ConfigPath D:\Case\engagement.psd1 -MinLevel medium
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

    [ValidateSet('informational', 'low', 'medium', 'high', 'critical')]
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

$ToolVersion = '0.1.0'

$libDir = Join-Path -Path $PSScriptRoot -ChildPath 'lib'
foreach ($lib in @('Paths', 'Elevation', 'Config', 'Manifest', 'RunMeta')) {
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

$resolved = Resolve-SelectionSetting -CommandLine $commandLine -Config $config -HayabusaPath $HayabusaPath

$threadsValue = $null
if ($PSBoundParameters.ContainsKey('Threads')) {
    $threadsValue = $Threads
}

# Fail before anything is written if disk images need an elevated session.
Assert-ElevationForContainer -InputRoot $InputRoot

# Run setup
if (-not (Test-Path -LiteralPath $OutputRoot -PathType Container)) {
    New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
    Write-Verbose "Created OutputRoot: $OutputRoot"
}

$runId = [guid]::NewGuid().ToString()
$startedUtc = (Get-Date).ToUniversalTime()

$manifestPath = Join-Path -Path $OutputRoot -ChildPath 'run_manifest.csv'
Initialize-RunManifest -Path $manifestPath | Out-Null

$runMeta = New-RunMeta `
    -RunId $runId `
    -StartedUtc $startedUtc `
    -ToolVersion $ToolVersion `
    -InputRoot $InputRoot `
    -OutputRoot $OutputRoot `
    -HayabusaPath $HayabusaPath `
    -Resolved $resolved `
    -Config $config `
    -Threads $threadsValue `
    -Force $Force.IsPresent `
    -KeepArtifacts $KeepArtifacts.IsPresent

$runMetaPath = Get-RunMetaPath -OutputRoot $OutputRoot -StartedUtc $startedUtc
Save-RunMeta -Path $runMetaPath -RunMeta $runMeta | Out-Null

Write-Verbose "RunId $runId"
Write-Verbose "Manifest: $manifestPath"
Write-Verbose "Run metadata: $runMetaPath"

Write-Warning 'Host discovery and processing are not implemented yet. The run has been initialised only.'

[pscustomobject]@{
    RunId        = $runId
    ManifestPath = $manifestPath
    RunMetaPath  = $runMetaPath
}
