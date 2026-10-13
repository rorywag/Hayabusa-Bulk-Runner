# Stand-in for hayabusa.exe 4.1.0, used by the tests. It runs as its own
# process through a small launcher (hayabusa.cmd on Windows, a shell script
# elsewhere) so the tool calls it exactly as it calls the real binary.
#
# help        prints a logo and the version banner. FAKE_NO_BANNER drops the
#             banner, FAKE_HELP_MODE=silent prints no version line at all,
#             FAKE_HELP_MODE=indented indents the banner, FAKE_VERSION_FAIL
#             writes to stderr and exits 1.
# --version   is rejected, as 4.1.0 does.
# --include-tag with --exclude-tag is rejected with 4.1.0's error, exit 2.
# otherwise   reads fake.behavior from the -d folder (EXIT=, CSV=, HTML=,
#             STDERR=), copies the named CSV to -o, writes a stub report to -H
#             unless HTML=none, records
#             its arguments beside -o and appends -d to FAKE_CALLS if set.

$argv = @($args | ForEach-Object { [string]$_ })
$esc = [char]27

if ($argv.Count -gt 0 -and $argv[0] -eq '--version') {
    [Console]::Error.WriteLine("error: unexpected argument '--version' found")
    exit 2
}

if ($argv.Count -gt 0 -and $argv[0] -eq 'help') {
    if ($env:FAKE_HELP_MODE -eq 'silent') {
        [Console]::Out.WriteLine('usage only')
        exit 0
    }
    if ($env:FAKE_HELP_MODE -eq 'indented') {
        [Console]::Out.WriteLine('   Hayabusa v4.1.0 - Suzumushi Release')
        exit 0
    }
    [Console]::Out.WriteLine('')
    [Console]::Out.WriteLine('  _   _                 _                     ')
    [Console]::Out.WriteLine(' | | | | __ _ _   _  __| |__  _   _ ___  __ _ ')
    [Console]::Out.WriteLine('')
    if ([string]::IsNullOrEmpty($env:FAKE_NO_BANNER)) {
        [Console]::Out.WriteLine("$esc[1;32mHayabusa v4.1.0 - Suzumushi Release   $esc[0m")
    }
    [Console]::Out.WriteLine('Usage:')
    [Console]::Out.WriteLine('  hayabusa.exe <COMMAND> [OPTIONS]')
    [Console]::Out.WriteLine('  Hayabusa v9 is mentioned later in help text')
    if (-not [string]::IsNullOrEmpty($env:FAKE_VERSION_FAIL)) {
        [Console]::Error.WriteLine('boom')
        exit 1
    }
    exit 0
}

# Hayabusa 4.1.0 refuses the two tag filters together, before doing any work.
if ($argv -ccontains '--include-tag' -and $argv -ccontains '--exclude-tag') {
    [Console]::Error.WriteLine("error: the argument '--include-tag <TAG...>' cannot be used with '--exclude-tag <TAG...>'")
    exit 2
}

$inputPath = $null
$csvPath = $null
$htmlPath = $null
for ($i = 0; $i -lt $argv.Count - 1; $i++) {
    switch -CaseSensitive ($argv[$i]) {
        '-d' { $inputPath = $argv[$i + 1] }
        '-o' { $csvPath = $argv[$i + 1] }
        '-H' { $htmlPath = $argv[$i + 1] }
    }
}

if ($null -ne $csvPath) {
    $argsFile = [System.IO.Path]::ChangeExtension($csvPath, '.args')
    [System.IO.File]::WriteAllLines($argsFile, [string[]]$argv)
}
if (-not [string]::IsNullOrEmpty($env:FAKE_CALLS) -and $null -ne $inputPath) {
    [System.IO.File]::AppendAllText($env:FAKE_CALLS, $inputPath + [Environment]::NewLine)
}

$behavior = @{ EXIT = '0'; CSV = 'none'; HTML = 'stub'; STDERR = '' }
if ($null -ne $inputPath) {
    $behaviorFile = Join-Path -Path $inputPath -ChildPath 'fake.behavior'
    if (Test-Path -LiteralPath $behaviorFile) {
        foreach ($line in [System.IO.File]::ReadAllLines($behaviorFile)) {
            $pair = $line.Split('=', 2)
            if ($pair.Count -eq 2) {
                $behavior[$pair[0].Trim()] = $pair[1].Trim().Trim("'").Trim('"')
            }
        }
    }
}

[Console]::Out.WriteLine("$esc[33mResults Summary:$esc[0m fake run over $inputPath")
if (-not [string]::IsNullOrEmpty($behavior.STDERR)) {
    [Console]::Error.WriteLine($behavior.STDERR)
}
if ($behavior.CSV -ne 'none' -and $null -ne $csvPath) {
    Copy-Item -LiteralPath (Join-Path -Path $inputPath -ChildPath $behavior.CSV) -Destination $csvPath -Force
}
if ($behavior.HTML -ne 'none' -and $null -ne $htmlPath) {
    [System.IO.File]::WriteAllText($htmlPath, '<html></html>')
}
$code = 0
if (-not [int]::TryParse([string]$behavior.EXIT, [ref]$code)) {
    [Console]::Error.WriteLine("fake.behavior has a bad EXIT value: $($behavior.EXIT)")
    exit 99
}
exit $code
