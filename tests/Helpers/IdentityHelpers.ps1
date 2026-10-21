# Shared setup for the host identity tests. Dot-source after TestHelpers.ps1:
#
#     . (Join-Path $PSScriptRoot 'Helpers/IdentityHelpers.ps1')
#
# Fake hives that only start like one, a stand-in RECmd.exe that is never
# run, and a stand-in for RECmd's output, copied from the synthetic CSVs in
# tests\fixtures\identity. Nothing here reads or writes a real hive.

$script:IdentityFixture = Join-TestPath $FixtureRoot 'identity' 'recmd'
$script:FixtureStamp = '20261001120000'
$script:fakeRECmd = Write-TestText -Path (Join-TestPath $TestDrive 'tools' 'RECmd' 'RECmd.exe') -Line @('not a binary')

function New-FakeHive([string]$Path) {
    # A file that starts like a hive. RECmd is mocked, so it's never parsed.
    New-TestDirectory -Path (Split-Path -Parent $Path) | Out-Null
    $b = New-Object byte[] 8192
    [System.Text.Encoding]::ASCII.GetBytes('regf').CopyTo($b, 0)
    [System.IO.File]::WriteAllBytes($Path, $b)
    return $Path
}

function New-HiveCollection([string]$Root, [string]$Drive = 'C', [string[]]$Hive = @('SYSTEM', 'SOFTWARE', 'SAM')) {
    $config = Join-TestPath $Root $Drive 'Windows' 'System32' 'config'
    foreach ($h in $Hive) { New-FakeHive -Path (Join-TestPath $config $h) | Out-Null }
    New-TestDirectory -Path (Join-TestPath $Root $Drive 'Windows' 'System32' 'winevt' 'Logs') | Out-Null
    return $config
}

function Get-ArgumentValue([string[]]$Argument, [string]$Name) {
    $i = [array]::IndexOf($Argument, $Name)
    if ($i -lt 0) { return $null }
    return $Argument[$i + 1]
}

function Copy-FixtureOutput([string[]]$Argument) {
    # What RECmd writes for one hive: <hive>.csv in the --csv folder and
    # the plugin CSVs in a folder named for the run's start time.
    $csvDir = Get-ArgumentValue $Argument '--csv'
    $hive = [System.IO.Path]::GetFileNameWithoutExtension((Get-ArgumentValue $Argument '--csvf'))
    Copy-Item -LiteralPath (Join-TestPath $IdentityFixture "$hive.csv") -Destination (Join-TestPath $csvDir "$hive.csv")
    $stampDir = Join-TestPath $csvDir $FixtureStamp
    foreach ($f in @(Get-ChildItem -LiteralPath (Join-TestPath $IdentityFixture $FixtureStamp) -File | Where-Object { $_.Name -like "$($hive)_*" })) {
        New-TestDirectory -Path $stampDir | Out-Null
        Copy-Item -LiteralPath $f.FullName -Destination (Join-TestPath $stampDir $f.Name)
    }
}
