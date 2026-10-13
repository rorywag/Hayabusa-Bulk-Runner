#Requires -Version 5.1

<#
.SYNOPSIS
    Rebuilds the cross-host triage view from an existing OutputRoot.

.DESCRIPTION
    Reads OutputRoot\run_manifest.csv, each collection's timeline CSV and
    the run-meta files under OutputRoot\_runs, then writes:

    - triage_rules.csv: one row per rule that fired, by severity then hosts affected
    - triage_hosts.csv: one row per collection, worst first
    - triage_dashboard.html: a self-contained dashboard with no script and no
      external requests

    No host is rerun. The manifest and per-host output are read only. This
    does not need Windows, Hayabusa, the original InputRoot or an elevated
    session, so the view can be rebuilt anywhere OutputRoot is available.

    Invoke-BulkHayabusa.ps1 runs the same rollup at the end of every batch.

.PARAMETER OutputRoot
    The OutputRoot of an earlier run, holding run_manifest.csv.

.PARAMETER Help
    Print a short usage summary and stop. -h does the same. Nothing is
    read or written.

.EXAMPLE
    .\Invoke-HayabusaRollup.ps1 -OutputRoot D:\Cases\Case01\Output

.EXAMPLE
    .\Invoke-HayabusaRollup.ps1 -Help
#>
[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Run')]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$OutputRoot,

    # In a set of its own, so -Help binds without asking for OutputRoot.
    [Parameter(ParameterSetName = 'Help')]
    [Alias('h')]
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Help) {
    @(
        'Invoke-HayabusaRollup.ps1: rebuilds the triage CSVs and dashboard from an existing OutputRoot, without rerunning anything.'
        ''
        'Usage:'
        '  .\Invoke-HayabusaRollup.ps1 -OutputRoot <folder>'
        ''
        'Required:'
        '  -OutputRoot  The OutputRoot of an earlier run, holding run_manifest.csv'
        ''
        'Example:'
        '  .\Invoke-HayabusaRollup.ps1 -OutputRoot D:\Cases\Case01\Output'
        ''
        'For the complete help: Get-Help .\Invoke-HayabusaRollup.ps1 -Full'
    )
    return
}

# Show the closing pointer unless the caller chose otherwise.
if (-not $PSBoundParameters.ContainsKey('InformationAction')) {
    $InformationPreference = 'Continue'
}

$libDir = Join-Path -Path $PSScriptRoot -ChildPath 'lib'
foreach ($lib in @('Paths', 'Manifest', 'Results', 'Rollup', 'Dashboard')) {
    . (Join-Path -Path $libDir -ChildPath "$lib.ps1")
}

$OutputRoot = ConvertTo-NormalizedPath -Path $OutputRoot

$result = Invoke-Rollup -OutputRoot $OutputRoot
Write-Verbose "Rollup: $($result.HostCount) host row(s), $($result.RuleCount) rule(s)."
Write-Information "Rebuilt the rollup in $OutputRoot. Open triage_dashboard.html there to start triage."
$result
