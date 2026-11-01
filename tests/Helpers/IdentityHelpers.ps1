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

function New-TestPattern([int]$Count, [int]$Seed) {
    # Bytes that are never zero, so a hole left as zeros is told apart.
    $b = New-Object byte[] $Count
    for ($i = 0; $i -lt $Count; $i++) { $b[$i] = [byte]((($i * 31) + $Seed) % 251 + 1) }
    return , $b
}

function New-SparseTestFile {
    <#
    Writes a file the way a Velociraptor offline collector stores one sparse:
    the data segments back to back at Path, and Path.idx mapping them to
    their original offsets, holes between. Segment is a list of byte arrays
    for data and numbers for holes. A range at offset 0 is written without
    file_offset or original_offset, as the collector does. Returns the
    original file's bytes.
    #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][object[]]$Segment, [string]$IndexPath = ($Path + '.idx'))
    New-TestDirectory -Path (Split-Path -Parent $Path) | Out-Null
    $stored = New-Object System.IO.MemoryStream
    $original = New-Object System.IO.MemoryStream
    $ranges = New-Object System.Collections.Generic.List[string]
    foreach ($s in $Segment) {
        $fo = $stored.Length
        $oo = $original.Length
        $at = ''
        if ($fo -ne 0 -or $oo -ne 0) { $at = "`"file_offset`":$fo,`"original_offset`":$oo," }
        if ($s -is [byte[]]) {
            $stored.Write($s, 0, $s.Length)
            $original.Write($s, 0, $s.Length)
            $ranges.Add("{$at`"file_length`":$($s.Length),`"length`":$($s.Length)}")
        }
        else {
            $original.Write((New-Object byte[] ([int]$s)), 0, [int]$s)
            $ranges.Add("{$at`"length`":$([int]$s)}")
        }
    }
    [System.IO.File]::WriteAllBytes($Path, $stored.ToArray())
    Write-TestText -Path $IndexPath -Line @('{"ranges":[', ($ranges -join ",`n"), ']}') | Out-Null
    return , $original.ToArray()
}
