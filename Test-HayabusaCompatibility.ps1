#Requires -Version 5.1

<#
.SYNOPSIS
    Checks a Hayabusa release still works with this tool.

.DESCRIPTION
    Builds a one-event Security log in a temporary folder, then runs the
    given Hayabusa over it with the exact arguments the tool uses for real
    runs, built by the same New-HayabusaArgument. Five runs between them
    send every flag the tool can pass: the flags every run sends, -m, -e,
    --include-tag, --exclude-tag, --timeline-start, --timeline-end and
    --threads, with both output profiles.

    Then it checks, and prints PASS or FAIL for each:

    - version: the version line is read from hayabusa help
    - profiles: the output profiles listed in config\profiles.yaml beside
      the binary can be read, with the ones the tool accepts, those whose
      columns include Level, Computer and RuleTitle
    - flag coverage: every flag the tool can emit was sent at least once
    - sample: Hayabusa read the sample's one event, from the baseline
      run's summary. A FAIL here means the generated sample is at fault,
      not the release
    - run: Hayabusa accepted dfir-timeline and every flag, and applied the
      filters. A non-zero exit names the flag, subcommand or value it
      refused, from its stderr
    - columns: the CSV has Level, Computer and RuleTitle, which the rollup
      reads
    - levels: every Level value maps to emergency, critical, high, medium,
      low or informational

    The sample event is Security 1102, which Hayabusa's own "Log Cleared"
    rule detects at level high. A detection is needed because Hayabusa
    writes an empty CSV, with no header row, when it detects nothing. Three
    runs must drop that detection: -e critical, --include-tag with a tag the
    rule lacks, and --exclude-tag with its tag. Each passes only on an empty
    CSV, so a release that accepts a filter but ignores it fails.

    Exits 0 when every check passes and 1 otherwise. Each run's CSV, report
    and log are kept with -KeepArtifacts. Needs Windows, but not an
    elevated session.

.PARAMETER HayabusaPath
    Full path to the hayabusa.exe to check.

.PARAMETER RulesPath
    The rules folder to run with, normally the rules folder beside
    hayabusa.exe.

.PARAMETER KeepArtifacts
    Keep the temporary working folder, with the sample log and each run's
    CSV, report and log, and print where it is. Off by default.

.PARAMETER Help
    Print a short usage summary and stop. -h does the same. Nothing is
    read or written.

.EXAMPLE
    .\Test-HayabusaCompatibility.ps1 -HayabusaPath D:\Tools\hayabusa-4.2.0\hayabusa.exe -RulesPath D:\Tools\hayabusa-4.2.0\rules

.EXAMPLE
    .\Test-HayabusaCompatibility.ps1 -Help
#>
[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Run')]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$HayabusaPath,

    [Parameter(Mandatory, ParameterSetName = 'Run')]
    [ValidateScript({ Test-Path -LiteralPath $_ })]
    [string]$RulesPath,

    [Parameter(ParameterSetName = 'Run')]
    [switch]$KeepArtifacts,

    # In a set of its own, so -Help binds without asking for the required
    # parameters.
    [Parameter(ParameterSetName = 'Help')]
    [Alias('h')]
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Help) {
    @(
        'Test-HayabusaCompatibility.ps1: checks a Hayabusa release still works with this tool, by running it over a generated sample.'
        ''
        'Usage:'
        '  .\Test-HayabusaCompatibility.ps1 -HayabusaPath <hayabusa.exe> -RulesPath <rules folder> [options]'
        ''
        'Required:'
        '  -HayabusaPath   Full path to the hayabusa.exe to check'
        '  -RulesPath      The rules folder to run with, normally the one beside hayabusa.exe'
        ''
        'Options:'
        '  -KeepArtifacts  Keep the temporary working folder with each run''s CSV, report and log'
        ''
        'Prints PASS or FAIL per check. Exits 0 when everything passes, 1 otherwise.'
        ''
        'Example:'
        '  .\Test-HayabusaCompatibility.ps1 -HayabusaPath D:\Tools\hayabusa-4.2.0\hayabusa.exe -RulesPath D:\Tools\hayabusa-4.2.0\rules'
        ''
        'For the complete help: Get-Help .\Test-HayabusaCompatibility.ps1 -Full'
    )
    return
}

$libDir = Join-Path -Path $PSScriptRoot -ChildPath 'lib'
foreach ($lib in @('Paths', 'Elevation', 'Hayabusa', 'Results', 'Compatibility')) {
    . (Join-Path -Path $libDir -ChildPath "$lib.ps1")
}

Assert-HayabusaHost

$HayabusaPath = ConvertTo-NormalizedPath -Path $HayabusaPath
$RulesPath = ConvertTo-NormalizedPath -Path $RulesPath

$stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ', [System.Globalization.CultureInfo]::InvariantCulture)
$workDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "hayabusa-compat-$stamp-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
New-Item -ItemType Directory -Path $workDir | Out-Null

$exitCode = 1
try {
    'Hayabusa compatibility check'
    "Binary: $HayabusaPath"
    "Rules:  $RulesPath ($((Get-RulesVersion -RulesPath $RulesPath).Summary))"
    ''
    $result = Invoke-HayabusaCompatibilityCheck -HayabusaPath $HayabusaPath -RulesPath $RulesPath -WorkingDirectory $workDir
    Format-CompatibilityReport -Check $result.Checks
    $exitCode = $result.ExitCode
}
finally {
    if ($KeepArtifacts) {
        "Working folder kept: $workDir"
    }
    else {
        Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
        if ($exitCode -ne 0) {
            'Working folder removed. Rerun with -KeepArtifacts to keep each run''s CSV, report and log.'
        }
    }
}

exit $exitCode
