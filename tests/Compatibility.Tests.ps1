# The compatibility self-test. The verdict logic is driven by fixture CSVs,
# logs and the fake Hayabusa, so it runs everywhere. Running the entry
# script needs Windows. Running it against a real hayabusa.exe also needs
# HAYABUSA_COMPAT_PATH set to one, and is tagged Compatibility:
#
#     $env:HAYABUSA_COMPAT_PATH = 'D:\Tools\hayabusa\hayabusa.exe'
#     Invoke-Pester -Path tests -TagFilter Compatibility

BeforeDiscovery {
    $script:onWindows = ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
    $script:realHayabusa = $env:HAYABUSA_COMPAT_PATH
    $script:canRunReal = $onWindows -and -not [string]::IsNullOrEmpty($realHayabusa) -and (Test-Path -LiteralPath $realHayabusa -PathType Leaf)
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers/TestHelpers.ps1')
    $script:hb = New-FakeHayabusa -Directory (Join-TestPath $TestDrive 'tool')
    $script:rules = Join-TestPath $TestDrive 'tool' 'rules'

    function script:New-RunLog([string]$Path, [string[]]$Stderr = @(), [int]$Exit = 0) {
        $lines = @('Started (UTC): 2026-10-13T00:00:00Z', 'Binary: hayabusa.exe', 'Arguments:', '  dfir-timeline', '--- output ---', 'Results Summary:')
        $lines += @($Stderr | ForEach-Object { "[stderr] $_" })
        $lines += @('--- end ---', "Exit code: $Exit")
        Write-TestText -Path $Path -Line $lines
    }
    function script:Get-Check([object[]]$Checks, [string]$Name) {
        @($Checks | Where-Object { $_.Name -eq $Name })
    }
}

Describe 'Sample event log' {
    BeforeAll {
        $script:evtx = New-CompatibilitySampleEvtx -Path (Join-TestPath $TestDrive 'sample1.evtx')
        $script:bytes = [System.IO.File]::ReadAllBytes($evtx)
    }

    It 'computes CRC-32 like the EVTX format does' {
        '{0:X8}' -f (Get-Crc32 -Bytes ([System.Text.Encoding]::ASCII.GetBytes('123456789'))) | Should -Be 'CBF43926'
    }
    It 'is a file header and one chunk, with the record at the start of the chunk' {
        $bytes.Length | Should -Be (4096 + 65536)
        [System.Text.Encoding]::ASCII.GetString($bytes, 0, 7) | Should -Be 'ElfFile'
        [System.Text.Encoding]::ASCII.GetString($bytes, 4096, 7) | Should -Be 'ElfChnk'
        [BitConverter]::ToUInt32($bytes, 4096 + 512) | Should -Be 0x00002A2A
    }
    It 'carries correct checksums for the file header, chunk header and record data' {
        [BitConverter]::ToUInt32($bytes, 124) | Should -Be (Get-Crc32 -Bytes $bytes -Offset 0 -Count 120)
        $chunk = New-Object byte[] 65536
        [System.Array]::Copy($bytes, 4096, $chunk, 0, 65536)
        $free = [BitConverter]::ToUInt32($chunk, 48)
        [BitConverter]::ToUInt32($chunk, 52) | Should -Be (Get-Crc32 -Bytes $chunk -Offset 512 -Count ($free - 512))
        $header = New-Object byte[] 504
        [System.Array]::Copy($chunk, 0, $header, 0, 120)
        [System.Array]::Copy($chunk, 128, $header, 120, 384)
        [BitConverter]::ToUInt32($chunk, 124) | Should -Be (Get-Crc32 -Bytes $header)
    }
    It 'holds the Security 1102 event from COMPAT-TEST' {
        # Strings are UTF-16 but can start at an odd offset, so search bytes.
        $hex = [BitConverter]::ToString($bytes, 4096 + 512, 2048)
        foreach ($s in 'Security', '1102', 'COMPAT-TEST', '2026-01-15T12:00:00') {
            $hex.Contains([BitConverter]::ToString([System.Text.Encoding]::Unicode.GetBytes($s))) | Should -BeTrue -Because "the record holds $s"
        }
    }
    It 'comes out the same every time' {
        $again = New-CompatibilitySampleEvtx -Path (Join-TestPath $TestDrive 'sample2.evtx')
        (Get-FileHash -LiteralPath $again).Hash | Should -Be (Get-FileHash -LiteralPath $evtx).Hash
    }
    It 'never overwrites a file' {
        { New-CompatibilitySampleEvtx -Path $evtx } | Should -Throw
    }
}

Describe 'Run plan and flag coverage' {
    BeforeAll {
        $script:plan = @(Get-CompatibilityRunPlan -RulesPath $rules)
        $script:emittable = Get-HayabusaArgumentFlag
        $script:planArgs = @{}
        foreach ($r in $plan) {
            $planArgs[$r.Name] = New-HayabusaArgument -InputPath 'X:\sample' -CsvPath 'c.csv' -HtmlPath 'h.html' -Selection $r.Selection -Threads $r.Threads
        }
    }

    It 'reads every flag New-HayabusaArgument can emit from its code' {
        $expected = @('-d', '-w', '-K', '-p', '-U', '-t', '-o', '-H', '-s', '-X', '-C', '-r', '-m', '-e', '--threads', '--include-tag', '--exclude-tag', '--timeline-start', '--timeline-end')
        @($emittable | Sort-Object) | Should -Be @($expected | Sort-Object)
    }
    It 'sends every one of them across its runs, through New-HayabusaArgument' {
        $sent = @($planArgs.Values | ForEach-Object { $_ } | Where-Object { $emittable -ccontains $_ } | Select-Object -Unique)
        @($emittable | Where-Object { $sent -cnotcontains $_ }) | Should -BeNullOrEmpty
        foreach ($a in $planArgs.Values) { $a[0] | Should -Be 'dfir-timeline' }
    }
    It 'uses both output profiles, and the time window around the sample event' {
        @($plan | ForEach-Object { $_.Selection.Profile } | Sort-Object -Unique) | Should -Be @('standard', 'verbose')
        $base = $planArgs['baseline']
        $base[$base.IndexOf('--timeline-start') + 1] | Should -Be '2026-01-01 00:00:00 +00:00'
        $base[$base.IndexOf('--timeline-end') + 1] | Should -Be '2026-12-31 23:59:59 +00:00'
    }
    It 'expects the sample detected except where --exclude-tag drops it' {
        foreach ($r in $plan) { $r.ExpectDetection | Should -Be ($r.Name -ne 'exclude-tag') }
        $planArgs['exclude-tag'] | Should -Contain '--exclude-tag'
    }
    It 'fails coverage naming a flag that was never sent' {
        $c = Test-CompatibilityFlagCoverage -SentFlag @('-d', '-m') -EmittableFlag @('-d', '-m', '--threads')
        $c.Passed | Should -BeFalse
        $c.Detail | Should -BeLike 'never sent: --threads.*'
        (Test-CompatibilityFlagCoverage -SentFlag @('-d', '-m') -EmittableFlag @('-d', '-m')).Passed | Should -BeTrue
    }
}

Describe 'Run verdicts' {
    BeforeAll {
        $script:vd = New-TestDirectory (Join-TestPath $TestDrive 'verdicts')
        $script:okLog = New-RunLog (Join-TestPath $vd 'ok.log')
        $script:rowsCsv = Write-TestText -Path (Join-TestPath $vd 'rows.csv') -Line @($TimelineHeader, (New-TimelineRow 'COMPAT-TEST' 'high' 'Log Cleared'))
        $script:emptyCsv = Join-TestPath $vd 'empty.csv'
        [System.IO.File]::WriteAllBytes($emptyCsv, (New-Object byte[] 0))
        $script:headerCsv = Write-TestText -Path (Join-TestPath $vd 'header.csv') -Line @($TimelineHeader)
        $script:noTitleCsv = Write-TestText -Path (Join-TestPath $vd 'notitle.csv') -Line @('"Timestamp","Computer","Level"', '"t","COMPAT-TEST","high"')
        $script:flags = @('dfir-timeline', '-d', '-m')
    }

    It 'passes a run with detections and the needed columns' {
        $c = @(Test-CompatibilityRun -Name 'baseline' -ExitCode 0 -CsvPath $rowsCsv -LogPath $okLog -Flag $flags -ExpectDetection $true)
        $c.Count | Should -Be 2
        $c[0].Name | Should -Be 'run baseline'
        $c[0].Passed | Should -BeTrue
        $c[0].Detail | Should -Be 'accepted, 1 detection(s). Flags sent: dfir-timeline -d -m'
        $c[1].Name | Should -Be 'columns baseline'
        $c[1].Passed | Should -BeTrue
    }
    It 'passes a clean zero-detection run on the empty CSV Hayabusa writes, with no columns to check' {
        $c = @(Test-CompatibilityRun -Name 'exclude-tag' -ExitCode 0 -CsvPath $emptyCsv -LogPath $okLog -Flag $flags)
        $c.Count | Should -Be 1
        $c[0].Passed | Should -BeTrue
        $c[0].Detail | Should -BeLike 'accepted, no detections (empty CSV).*'
    }
    It 'checks the columns of a header-only CSV' {
        $c = @(Test-CompatibilityRun -Name 'x' -ExitCode 0 -CsvPath $headerCsv -LogPath $okLog -Flag $flags)
        $c[0].Passed | Should -BeTrue
        (Get-Check $c 'columns x').Passed | Should -BeTrue
    }
    It 'fails a run that should have detected the sample but did not' {
        $c = @(Test-CompatibilityRun -Name 'baseline' -ExitCode 0 -CsvPath $emptyCsv -LogPath $okLog -Flag $flags -ExpectDetection $true)
        $c[0].Passed | Should -BeFalse
        $c[0].Detail | Should -BeLike "*'Log Cleared' detection did not fire*"
    }
    It 'fails exit 0 with no CSV at all' {
        $c = @(Test-CompatibilityRun -Name 'x' -ExitCode 0 -CsvPath (Join-TestPath $vd 'missing.csv') -LogPath $okLog -Flag $flags)
        $c.Count | Should -Be 1
        $c[0].Passed | Should -BeFalse
        $c[0].Detail | Should -BeLike 'exit code 0 but no CSV was written*'
    }
    It 'names a missing column' {
        $c = Get-Check @(Test-CompatibilityRun -Name 'x' -ExitCode 0 -CsvPath $noTitleCsv -LogPath $okLog -Flag $flags) 'columns x'
        $c.Passed | Should -BeFalse
        $c.Detail | Should -BeLike 'missing column(s) RuleTitle. The CSV has: Timestamp, Computer, Level'
    }
    It 'reads a header behind a byte order mark' {
        $bom = Join-TestPath $vd 'bom.csv'
        [System.IO.File]::WriteAllText($bom, $TimelineHeader + "`r`n" + (New-TimelineRow 'C' 'high' 'R') + "`r`n", (New-Object System.Text.UTF8Encoding($true)))
        (Get-Check @(Test-CompatibilityRun -Name 'x' -ExitCode 0 -CsvPath $bom -LogPath $okLog -Flag $flags) 'columns x').Passed | Should -BeTrue
    }
    It 'names what Hayabusa refused on a non-zero exit: <Case>' -ForEach @(
        @{ Case = 'a flag'; Stderr = @("error: unexpected argument '--threadz' found", 'System.Management.Automation.RemoteException', "  tip: a similar argument exists: '--threads'"); Exit = 2; Like = "exit code 2, possible compatibility break. Hayabusa rejected the flag --threadz (it suggests --threads). Flags sent:*" }
        @{ Case = 'the subcommand'; Stderr = @("error: unrecognized subcommand 'dfir-timeline'"); Exit = 2; Like = '*Hayabusa rejected the subcommand dfir-timeline. Flags sent:*' }
        @{ Case = 'a value'; Stderr = @("error: invalid value 'abc' for '--threads <NUMBER>'"); Exit = 2; Like = "*Hayabusa rejected the value 'abc' for --threads <NUMBER>. Flags sent:*" }
        @{ Case = 'a pair of flags'; Stderr = @("error: the argument '--include-tag <TAG...>' cannot be used with '--exclude-tag <TAG...>'"); Exit = 2; Like = '*Hayabusa refused --include-tag <TAG...> together with --exclude-tag <TAG...>.*' }
        @{ Case = 'its own error'; Stderr = @('[ERROR]  You specified an invalid level.'); Exit = 1; Like = 'exit code 1, possible compatibility break. `[ERROR`]  You specified an invalid level. Flags sent:*' }
        @{ Case = 'nothing on stderr'; Stderr = @(); Exit = 3; Like = 'exit code 3, possible compatibility break. Hayabusa wrote nothing to stderr. Flags sent:*' }
    ) {
        $log = New-RunLog (Join-TestPath $vd "rej-$($Case -replace '\W', '_').log") -Stderr $Stderr -Exit $Exit
        $c = @(Test-CompatibilityRun -Name 'x' -ExitCode $Exit -CsvPath (Join-TestPath $vd 'none.csv') -LogPath $log -Flag $flags -ExpectDetection $true)
        $c.Count | Should -Be 1
        $c[0].Passed | Should -BeFalse
        $c[0].Detail | Should -BeLike $Like
        $c[0].Detail | Should -BeLike "*Log: $log"
    }
    It 'still checks the columns of a CSV written before a non-zero exit' {
        $log = New-RunLog (Join-TestPath $vd 'late.log') -Stderr @('[ERROR] late failure') -Exit 1
        $c = @(Test-CompatibilityRun -Name 'x' -ExitCode 1 -CsvPath $rowsCsv -LogPath $log -Flag $flags)
        $c[0].Passed | Should -BeFalse
        (Get-Check $c 'columns x').Passed | Should -BeTrue
    }
}

Describe 'Level values' {
    BeforeAll {
        $script:ld = New-TestDirectory (Join-TestPath $TestDrive 'levels')
    }

    It 'passes every short and full form of the six severities' {
        $rows = @('emer', 'emergency', 'crit', 'critical', 'high', 'med', 'medium', 'low', 'info', 'informational', 'High') | ForEach-Object { New-TimelineRow 'C' $_ 'R' }
        $p = Write-TestText -Path (Join-TestPath $ld 'all.csv') -Line (@($TimelineHeader) + @($rows))
        $c = Test-CompatibilityLevel -CsvPath @($p)
        $c.Passed | Should -BeTrue
        $c.Detail | Should -BeLike 'all map to a known severity: emer -> emergency, *, info -> informational, *'
    }
    It 'names a value that maps to none of them' {
        $p = Write-TestText -Path (Join-TestPath $ld 'new.csv') -Line @($TimelineHeader, (New-TimelineRow 'C' 'high' 'R'), (New-TimelineRow 'C' 'severe' 'R'))
        $c = Test-CompatibilityLevel -CsvPath @($p)
        $c.Passed | Should -BeFalse
        $c.Detail | Should -BeLike "Level value(s) 'severe' do not map to one of *. Renamed or new level"
    }
    It 'fails when no run produced a Level value, skipping missing and empty files' {
        $empty = Join-TestPath $ld 'empty.csv'
        [System.IO.File]::WriteAllBytes($empty, (New-Object byte[] 0))
        $c = Test-CompatibilityLevel -CsvPath @($empty, (Join-TestPath $ld 'missing.csv'))
        $c.Passed | Should -BeFalse
        $c.Detail | Should -BeLike 'no Level values to check*'
    }
}

Describe 'Version check and the startup notice' {
    It 'reads the version number from the banner' {
        Get-HayabusaVersionNumber -VersionLine 'Hayabusa v4.1.0 - Suzumushi Release' | Should -Be '4.1.0'
        Get-HayabusaVersionNumber -VersionLine 'Hayabusa v4.2.10-dev' | Should -Be '4.2.10'
        Get-HayabusaVersionNumber -VersionLine $null | Should -BeNullOrEmpty
    }
    It 'gives no notice for the tested version or an unreadable one' {
        Get-HayabusaVersionNotice -VersionLine "Hayabusa v$TestedHayabusaVersion - Suzumushi Release" | Should -BeNullOrEmpty
        Get-HayabusaVersionNotice -VersionLine $null | Should -BeNullOrEmpty
    }
    It 'names both versions and the self-test when they differ' {
        Get-HayabusaVersionNotice -VersionLine 'Hayabusa v4.2.0 - Next Release' | Should -BeExactly "Hayabusa 4.2.0 is not the version this tool was tested with ($TestedHayabusaVersion). Run Test-HayabusaCompatibility.ps1 against it to check the flags, output columns and severity levels this tool relies on."
    }
    It 'passes the version check with a note, and fails it when nothing was read' {
        (Test-CompatibilityVersion -HayabusaVersion ([pscustomobject]@{ Version = 'Hayabusa v4.1.0 - Suzumushi Release'; Error = $null })).Detail | Should -Be 'Hayabusa v4.1.0 - Suzumushi Release (the tested version)'
        $other = Test-CompatibilityVersion -HayabusaVersion ([pscustomobject]@{ Version = 'Hayabusa v4.2.0'; Error = $null })
        $other.Passed | Should -BeTrue
        $other.Detail | Should -Be "Hayabusa v4.2.0 (tested version is $TestedHayabusaVersion)"
        $none = Test-CompatibilityVersion -HayabusaVersion ([pscustomobject]@{ Version = $null; Error = 'No line matching' })
        $none.Passed | Should -BeFalse
        $none.Detail | Should -Be 'could not read the version: No line matching'
    }
}

Describe 'Report' {
    It 'prints one plain line per check and the overall result' {
        $lines = Format-CompatibilityReport -Check @(
            (New-CompatibilityCheck -Name 'version' -Passed $true -Detail 'v'),
            (New-CompatibilityCheck -Name 'columns baseline' -Passed $false -Detail 'missing column(s) Level')
        )
        $lines[0] | Should -BeExactly 'PASS  version           v'
        $lines[1] | Should -BeExactly 'FAIL  columns baseline  missing column(s) Level'
        $lines[2] | Should -BeExactly 'Result: FAIL, 1 of 2 checks failed.'
        (Format-CompatibilityReport -Check @((New-CompatibilityCheck -Name 'a' -Passed $true -Detail 'd')))[-1] | Should -BeExactly 'Result: PASS, all 1 checks passed.'
    }
}

Describe 'The whole check with the fake Hayabusa' {
    BeforeAll {
        function script:Invoke-FakeCheck([string]$Name, [string]$Behavior, [hashtable]$Files) {
            $work = New-TestDirectory (Join-TestPath $TestDrive "work-$Name")
            New-FakeHost -InputRoot $work -Name 'sample' -Behavior $Behavior -Files $Files | Out-Null
            $r = Invoke-HayabusaCompatibilityCheck -HayabusaPath $hb -RulesPath $rules -WorkingDirectory $work
            $r | Add-Member -NotePropertyName Work -NotePropertyValue $work -PassThru
        }
    }
    BeforeEach { Mock Assert-HayabusaHost { } }

    It 'passes and exits 0 when every run is accepted with the needed columns and levels' {
        $r = Invoke-FakeCheck 'pass' "EXIT=0`nCSV=r.csv" @{ 'r.csv' = @($TimelineHeader, (New-TimelineRow 'COMPAT-TEST' 'high' 'Log Cleared')) }
        @($r.Checks | Where-Object { -not $_.Passed } | ForEach-Object { "$($_.Name): $($_.Detail)" }) | Should -BeNullOrEmpty
        $r.ExitCode | Should -Be 0
        @($r.Checks.Name) | Should -Be @('version', 'flag coverage', 'run baseline', 'columns baseline', 'run exact-tag', 'columns exact-tag', 'run exclude-tag', 'columns exclude-tag', 'levels')
        $r.Version.Version | Should -Be 'Hayabusa v4.1.0 - Suzumushi Release'
        Test-Path -LiteralPath (Join-TestPath $r.Work 'sample' 'Security.evtx') | Should -BeTrue
    }
    It 'gives Hayabusa exactly the arguments New-HayabusaArgument builds, and logs each run' {
        $r = Invoke-FakeCheck 'args' "EXIT=0`nCSV=r.csv" @{ 'r.csv' = @($TimelineHeader, (New-TimelineRow 'COMPAT-TEST' 'high' 'Log Cleared')) }
        foreach ($run in @(Get-CompatibilityRunPlan -RulesPath $rules)) {
            $dir = Join-TestPath $r.Work $run.Name
            $expected = New-HayabusaArgument -InputPath (Join-TestPath $r.Work 'sample') -CsvPath (Join-TestPath $dir "$($run.Name)_timeline.csv") -HtmlPath (Join-TestPath $dir "$($run.Name)_report.html") -Selection $run.Selection -Threads $run.Threads
            @(Get-Content -LiteralPath (Join-TestPath $dir "$($run.Name)_timeline.args")) | Should -Be $expected
            Get-Content -LiteralPath (Join-TestPath $dir "$($run.Name)_hayabusa.log") | Should -Contain 'Exit code: 0'
        }
    }
    It 'fails and exits 1 naming a rejected flag, with no detections to read levels from' {
        $r = Invoke-FakeCheck 'reject' "EXIT=2`nCSV=none`nSTDERR=error: unexpected argument '--include-tag' found" @{}
        $r.ExitCode | Should -Be 1
        foreach ($n in 'run baseline', 'run exact-tag', 'run exclude-tag') {
            $c = Get-Check $r.Checks $n
            $c.Passed | Should -BeFalse
            $c.Detail | Should -BeLike '*Hayabusa rejected the flag --include-tag*'
        }
        (Get-Check $r.Checks 'levels').Passed | Should -BeFalse
        (Get-Check $r.Checks 'flag coverage').Passed | Should -BeTrue
    }
    It 'fails on a new level value and a missing column' {
        $r = Invoke-FakeCheck 'schema' "EXIT=0`nCSV=r.csv" @{ 'r.csv' = @('"Timestamp","Computer","Level"', '"t","COMPAT-TEST","severe"') }
        $r.ExitCode | Should -Be 1
        (Get-Check $r.Checks 'columns baseline').Detail | Should -BeLike 'missing column(s) RuleTitle*'
        (Get-Check $r.Checks 'levels').Detail | Should -BeLike "Level value(s) 'severe'*"
        (Get-Check $r.Checks 'run baseline').Passed | Should -BeTrue
    }
    It 'fails when the runs that should detect the sample come back empty' {
        $r = Invoke-FakeCheck 'empty' "EXIT=0`nCSV=r.csv" @{ 'r.csv' = @() }
        $r.ExitCode | Should -Be 1
        (Get-Check $r.Checks 'run baseline').Passed | Should -BeFalse
        (Get-Check $r.Checks 'run exclude-tag').Passed | Should -BeTrue
    }
}

Describe 'Entry script quick help' {
    BeforeAll {
        $script:help = @(& $CompatibilityScript -Help)
        $script:helpDir = New-TestDirectory (Join-TestPath $TestDrive 'help-cwd')
        $script:child = Invoke-ScriptInNewProcess -Path $CompatibilityScript -Argument @('-Help') -WorkingDirectory $helpDir
    }

    It 'prints the usage summary, as plain text only' {
        $help[0] | Should -BeLike 'Test-HayabusaCompatibility.ps1: checks a Hayabusa release *'
        foreach ($name in 'HayabusaPath', 'RulesPath', 'KeepArtifacts') {
            @($help | Where-Object { $_ -like "  -$name *" }).Count | Should -Be 1 -Because "-$name has one line"
        }
        $help[-1] | Should -BeExactly 'For the complete help: Get-Help .\Test-HayabusaCompatibility.ps1 -Full'
        ($help -join "`n") | Should -Not -Match '[^\x09\x0A\x0D\x20-\x7E]'
    }
    It 'gives the same summary for -h, and needs no other parameter' {
        (@(& $CompatibilityScript -h) -join "`n") | Should -BeExactly ($help -join "`n")
        $child.ExitCode | Should -Be 0
        ($child.Output -join "`n").TrimEnd() | Should -BeExactly ($help -join "`n").TrimEnd()
        @(Get-ChildItem -LiteralPath $helpDir -Force).Count | Should -Be 0
    }
}

Describe 'Entry script off Windows' -Skip:$onWindows {
    It 'stops at the Windows check with a non-zero exit' {
        $r = Invoke-ScriptInNewProcess -Path $CompatibilityScript -Argument @('-HayabusaPath', $hb, '-RulesPath', $rules) -WorkingDirectory $TestDrive
        $r.ExitCode | Should -Not -Be 0
        ($r.Output -join "`n") | Should -BeLike '*Running Hayabusa requires Windows.*'
    }
}

Describe 'Entry script on Windows with the fake Hayabusa' -Skip:(-not $onWindows) {
    # The fake writes no CSV for the generated sample, which has no
    # fake.behavior file, so every run fails the same way.
    It 'prints a FAIL line per failed check, exits 1 and removes its working folder' {
        $r = Invoke-ScriptInNewProcess -Path $CompatibilityScript -Argument @('-HayabusaPath', $hb, '-RulesPath', $rules) -WorkingDirectory $TestDrive
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Contain 'Hayabusa compatibility check'
        @($r.Output | Where-Object { $_ -like 'PASS  version *Hayabusa v4.1.0 - Suzumushi Release (the tested version)' }).Count | Should -Be 1
        @($r.Output | Where-Object { $_ -like 'FAIL  run baseline *exit code 0 but no CSV was written*' }).Count | Should -Be 1
        $r.Output[-2] | Should -BeLike 'Result: FAIL, * checks failed.'
        $r.Output[-1] | Should -BeExactly 'Working folder removed. Rerun with -KeepArtifacts to keep each run''s CSV, report and log.'
        @($r.Output | Where-Object { $_ -like 'Working folder kept:*' }).Count | Should -Be 0
    }
    It 'keeps the working folder with -KeepArtifacts and says where' {
        $r = Invoke-ScriptInNewProcess -Path $CompatibilityScript -Argument @('-HayabusaPath', $hb, '-RulesPath', $rules, '-KeepArtifacts') -WorkingDirectory $TestDrive
        $kept = @($r.Output | Where-Object { $_ -like 'Working folder kept: *' })
        $kept.Count | Should -Be 1
        $dir = $kept[0].Substring('Working folder kept: '.Length)
        try {
            Test-Path -LiteralPath (Join-Path $dir 'sample\Security.evtx') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $dir 'baseline\baseline_hayabusa.log') | Should -BeTrue
        }
        finally {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Against a real Hayabusa' -Tag 'Compatibility' -Skip:(-not $canRunReal) {
    It 'passes every check and exits 0' {
        $rulesDir = $env:HAYABUSA_COMPAT_RULES
        if ([string]::IsNullOrEmpty($rulesDir)) { $rulesDir = Join-Path (Split-Path -Parent $env:HAYABUSA_COMPAT_PATH) 'rules' }
        $r = Invoke-ScriptInNewProcess -Path $CompatibilityScript -Argument @('-HayabusaPath', $env:HAYABUSA_COMPAT_PATH, '-RulesPath', $rulesDir) -WorkingDirectory $TestDrive
        @($r.Output | Where-Object { $_ -like 'FAIL  *' }) | Should -BeNullOrEmpty
        $r.ExitCode | Should -Be 0
        $r.Output[-1] | Should -BeLike 'Result: PASS, all * checks passed.'
    }
}
