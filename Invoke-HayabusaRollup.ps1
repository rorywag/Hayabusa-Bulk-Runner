#Requires -Version 5.1

<#
.SYNOPSIS
    Rebuilds the cross-host triage view from an existing OutputRoot.

.DESCRIPTION
    Reads OutputRoot\run_manifest.csv, each collection's timeline CSV and
    the run-meta files under OutputRoot\_runs, then writes:

    - triage_rules.csv: one row per rule that fired, by severity then hosts affected
    - triage_hosts.csv: one row per collection, worst first
    - index.html: a self-contained dashboard with no script and no external requests

    No host is rerun. The manifest and per-host output are read only. This
    does not need Windows, Hayabusa, the original InputRoot or an elevated
    session, so the view can be rebuilt anywhere OutputRoot is available.

    Invoke-BulkHayabusa.ps1 runs the same rollup at the end of every batch.

.PARAMETER OutputRoot
    The OutputRoot of an earlier run, holding run_manifest.csv.

.EXAMPLE
    .\Invoke-HayabusaRollup.ps1 -OutputRoot D:\Case\Hayabusa
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$OutputRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$libDir = Join-Path -Path $PSScriptRoot -ChildPath 'lib'
foreach ($lib in @('Paths', 'Manifest', 'Results', 'Rollup', 'Dashboard')) {
    . (Join-Path -Path $libDir -ChildPath "$lib.ps1")
}

$OutputRoot = ConvertTo-NormalizedPath -Path $OutputRoot

$result = Invoke-Rollup -OutputRoot $OutputRoot
Write-Verbose "Rollup: $($result.HostCount) host row(s), $($result.RuleCount) rule(s)."
$result
