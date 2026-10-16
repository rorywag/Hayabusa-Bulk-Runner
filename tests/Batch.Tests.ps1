BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers/TestHelpers.ps1')
    $script:hb = New-FakeHayabusa -Directory (Join-TestPath $TestDrive 'tool')
    $script:resolved = Get-TestRunSetting -HayabusaPath $hb
    $script:good = @($TimelineHeader) + @(New-TimelineRow 'WS01' 'crit' 'RuleA') + @(New-TimelineRow 'WS01' 'high' 'RuleB') + @(New-TimelineRow 'WS01' 'med' 'RuleC')

    function script:New-BatchRoot([string]$Name) {
        $root = New-TestDirectory (Join-TestPath $TestDrive $Name)
        $o = New-TestDirectory (Join-TestPath $root 'out')
        $m = Join-TestPath $o 'run_manifest.csv'
        Initialize-RunManifest -Path $m | Out-Null
        [pscustomobject]@{ In = (New-TestDirectory (Join-TestPath $root 'in')); Out = $o; Manifest = $m; Calls = (Join-TestPath $root 'calls.log') }
    }
    function script:Invoke-TestBatch($Root, [string]$RunId, [switch]$Force, $Threads = $null) {
        if (Test-Path -LiteralPath $Root.Calls) { Remove-Item -LiteralPath $Root.Calls }
        $env:FAKE_CALLS = $Root.Calls
        try {
            $cols = @(Get-InputCollection -InputRoot $Root.In -WarningAction SilentlyContinue)
            Invoke-CollectionBatch -Collections $cols -ManifestPath $Root.Manifest -OutputRoot $Root.Out -HayabusaPath $hb -Resolved $resolved -Threads $Threads -RunId $RunId -Force:$Force -WarningAction SilentlyContinue
        }
        finally { Remove-Item Env:\FAKE_CALLS -ErrorAction SilentlyContinue }
    }
    function script:Get-FakeCall($Root) {
        if (-not (Test-Path -LiteralPath $Root.Calls)) { return @() }
        @(Get-Content -LiteralPath $Root.Calls | ForEach-Object { Split-Path -Leaf $_ })
    }
    function script:Get-ManifestRowMap($Root) {
        $rows = @{}
        foreach ($k in (Get-RunManifest -Path $Root.Manifest).Keys) { $rows[$k] = (Get-RunManifest -Path $Root.Manifest)[$k] }
        $rows
    }
}

Describe 'Batch outcomes' {
    BeforeAll {
        Mock Assert-HayabusaHost { }
        $script:R = New-BatchRoot 'outcomes'
        New-FakeHost -InputRoot $R.In -Name 'H1' -Files @{ 'r.csv' = $good } | Out-Null
        New-FakeHost -InputRoot $R.In -Name 'H2' -Behavior "EXIT=3`nCSV=r.csv`nSTDERR=[ERROR] some rules failed to load" -Files @{ 'r.csv' = @($TimelineHeader, (New-TimelineRow 'WS02' 'high' 'RuleB')) } | Out-Null
        New-FakeHost -InputRoot $R.In -Name 'H3' -Behavior "EXIT=2`nCSV=none`nSTDERR=fatal: cannot open" | Out-Null
        # Hayabusa 4.2.0 does this for a --timeline-start it can't parse.
        New-FakeHost -InputRoot $R.In -Name 'H4' -Behavior "EXIT=0`nCSV=none`nSTDERR=[ERROR] start-timeline field: the timestamp format is not correct." | Out-Null
        New-FakeHost -InputRoot $R.In -Name 'H6' -Files @{ 'r.csv' = @($TimelineHeader) } | Out-Null
        # What Hayabusa writes when nothing matches: an empty file, no header.
        New-FakeHost -InputRoot $R.In -Name 'H9' -Files @{ 'r.csv' = @() } | Out-Null
        New-FakeHost -InputRoot $R.In -Name 'H7' -Files @{ 'r.csv' = @('"Timestamp","RuleTitle"', '"a","b"') } | Out-Null
        New-FakeHost -InputRoot $R.In -Name 'HOST 08' -Files @{ 'r.csv' = @($TimelineHeader, (New-TimelineRow 'WS08' 'low' 'R')) } | Out-Null
        New-TestZip -Path (Join-TestPath $R.In 'H5.zip') -Entries ([ordered]@{
                'fake.behavior' = "EXIT=0`nCSV=r.csv"
                'r.csv' = ((@($TimelineHeader, (New-TimelineRow 'DC01' 'crit' 'RuleA'), (New-TimelineRow 'DC01.corp.local' 'high' 'RuleB'))) -join "`n")
                'C/Windows/System32/winevt/Logs/Security.evtx' = 'evtx'
            }) | Out-Null
        $script:sum1 = Invoke-TestBatch $R 'run1' -Threads 4
        $script:calls1 = Get-FakeCall $R
        $script:rows = Get-ManifestRowMap $R
    }

    It 'runs all nine, so one bad host does not stop the rest' {
        $sum1.Processed | Should -Be 9
        $calls1.Count | Should -Be 9
    }
    It 'counts outcomes' {
        $sum1.Completed | Should -Be 5
        $sum1.CompletedWithErrors | Should -Be 1
        $sum1.Failed | Should -Be 3
        $sum1.Skipped | Should -Be 0
    }
    It 'exit 0 with a CSV: Completed with counts and Host from Computer' {
        $rows.H1.Status | Should -Be 'Completed'
        $rows.H1.Detections | Should -Be '3'
        $rows.H1.Critical | Should -Be '1'
        $rows.H1.High | Should -Be '1'
        $rows.H1.Host | Should -Be 'WS01'
        $rows.H1.Error | Should -Be ''
        $rows.H1.RunId | Should -Be 'run1'
    }
    It 'non-zero exit with a CSV: CompletedWithErrors, counts kept' {
        $rows.H2.Status | Should -Be 'CompletedWithErrors'
        $rows.H2.Detections | Should -Be '1'
        $rows.H2.Error | Should -BeLike 'Hayabusa exited with code 3.*'
    }
    It 'non-zero exit without a CSV: Failed' {
        $rows.H3.Status | Should -Be 'Failed'
        $rows.H3.Error | Should -BeLike '*exited with code 2*No CSV was written.'
    }
    It 'exit 0 without a CSV: Failed, with Hayabusa''s error from stderr' {
        $rows.H4.Status | Should -Be 'Failed'
        $rows.H4.Error | Should -BeExactly "Hayabusa exited 0 but wrote no CSV: start-timeline field: the timestamp format is not correct. See $(Join-TestPath $R.Out 'H4' 'H4_hayabusa.log')."
        $rows.H4.Warning | Should -Be ''
    }
    It 'exit 0 with an empty CSV: Completed with zero counts, no warning or error' {
        $rows.H9.Status | Should -Be 'Completed'
        $rows.H9.Detections | Should -Be '0'
        $rows.H9.Warning | Should -Be ''
        $rows.H9.Error | Should -Be ''
    }
    It 'no detections: Completed, zeros, Host blank' {
        $rows.H6.Status | Should -Be 'Completed'
        $rows.H6.Host | Should -Be ''
        $rows.H6.Warning | Should -Be ''
    }
    It 'an unparseable CSV: Failed with the parse error' {
        $rows.H7.Status | Should -Be 'Failed'
        $rows.H7.Error | Should -BeLike '*missing column(s)*'
    }
    It 'a zip is extracted, run, marked [multiple] and torn down' {
        $rows.H5.Status | Should -Be 'Completed'
        $rows.H5.Host | Should -BeExactly '[multiple]'
        $rows.H5.Warning | Should -BeLike '*Multiple Computer values: DC01 (1), DC01.corp.local (1)*'
        Test-Path -LiteralPath (Join-TestPath $R.Out '_work' 'H5') | Should -BeFalse
    }
    It 'writes the per-host output files' {
        foreach ($f in 'H1_timeline.csv', 'H1_report.html', 'H1_hayabusa.log') { Test-Path -LiteralPath (Join-TestPath $R.Out 'H1' $f) | Should -BeTrue }
    }
    It 'passes the argument array intact, including a path with a space' {
        $got = @(Get-Content -LiteralPath (Join-TestPath $R.Out 'H1' 'H1_timeline.args'))
        $want = @(New-HayabusaArgument -InputPath (Join-TestPath $R.In 'H1') -CsvPath (Join-TestPath $R.Out 'H1' 'H1_timeline.csv') -HtmlPath (Join-TestPath $R.Out 'H1' 'H1_report.html') -Selection $resolved.Selection -Threads 4)
        $got | Should -Be $want
        (@(Get-Content -LiteralPath (Join-TestPath $R.Out 'HOST_08' 'HOST_08_timeline.args')))[2] | Should -Be (Join-TestPath $R.In 'HOST 08')
    }
    It 'logs the arguments, stdout without colour codes, stderr and the exit code' {
        $log = Get-Content -LiteralPath (Join-TestPath $R.Out 'H2' 'H2_hayabusa.log') -Raw
        $log | Should -Match 'Arguments:\r?\n  dfir-timeline\r?\n  -d'
        $log | Should -Match 'Results Summary: fake run over'
        $log | Should -Not -Match "$([char]27)"
        $log | Should -Match '\[stderr\] \[ERROR\] some rules failed to load'
        $log | Should -Match 'Exit code: 3'
    }
    It 'reruns skip Completed and CompletedWithErrors but retry Failed, keeping RunIds' {
        $sum2 = Invoke-TestBatch $R 'run2'
        $sum2.Skipped | Should -Be 6
        $sum2.Processed | Should -Be 3
        ((Get-FakeCall $R | Sort-Object) -join ',') | Should -Be 'H3,H4,H7'
        $rows2 = Get-ManifestRowMap $R
        $rows2.H1.RunId | Should -Be 'run1'
        $rows2.H3.RunId | Should -Be 'run2'
    }
    It 'picks up a row left Running by an interrupted run' {
        Set-RunManifestEntry -Path $R.Manifest -Collection 'H1' -Source 'H1' -RunId 'crashed' -InputType Loose -Status Running
        Invoke-TestBatch $R 'run3' | Out-Null
        Get-FakeCall $R | Should -Contain 'H1'
        (Get-ManifestRowMap $R).H1.Status | Should -Be 'Completed'
    }
    It '-Force reruns everything and clobbers the log' {
        $sum4 = Invoke-TestBatch $R 'run4' -Force
        $sum4.Processed | Should -Be 9
        (Get-FakeCall $R).Count | Should -Be 9
        @(Get-Content -LiteralPath (Join-TestPath $R.Out 'H1' 'H1_hayabusa.log') | Where-Object { $_ -like 'Exit code:*' }).Count | Should -Be 1
    }
}

Describe 'Warnings and levels in the manifest' {
    BeforeAll { Mock Assert-HayabusaHost { } }

    It 'merges discovery and parse warnings in order without duplicates' {
        $R = New-BatchRoot 'warn'
        $d = New-FakeHost -InputRoot $R.In -Name 'C' -Files @{ 'r.csv' = @($TimelineHeader, (New-TimelineRow 'A' 'high' 'R'), (New-TimelineRow 'B' 'high' 'R')) }
        New-TestDirectory (Join-TestPath $d 'Windows' 'System32' 'winevt' 'Logs') | Out-Null
        Invoke-TestBatch $R 'w' | Out-Null
        $warn = (Get-ManifestRowMap $R).C.Warning
        $warn | Should -BeLike 'Folder directly contains Windows*| Multiple Computer values: A (1), B (1)'
        ($warn -split '\|').Count | Should -Be 2
    }
    It 'writes the Emergency count' {
        $R = New-BatchRoot 'emer'
        New-FakeHost -InputRoot $R.In -Name 'EM' -Files @{ 'r.csv' = (@($TimelineHeader) + @(New-TimelineRowSet 'EM01' 'emer' 'Ransom note dropped' 2) + @(New-TimelineRow 'EM01' 'crit' 'Mimikatz use')) } | Out-Null
        Invoke-TestBatch $R 'e1' | Out-Null
        $row = (Get-ManifestRowMap $R).EM
        $row.Emergency | Should -Be '2'
        $row.Critical | Should -Be '1'
    }
}

Describe 'Resumability with formula-like names' {
    BeforeAll {
        Mock Assert-HayabusaHost { }
        $script:F = New-BatchRoot 'formula'
        New-FakeHost -InputRoot $F.In -Name '-HOST' -Files @{ 'r.csv' = @($TimelineHeader, (New-TimelineRow '=WS01' 'high' 'R')) } | Out-Null
        New-FakeHost -InputRoot $F.In -Name '@HOST1' -Files @{ 'r.csv' = @($TimelineHeader, (New-TimelineRow '@WS02' 'high' 'R')) } | Out-Null
        New-FakeHost -InputRoot $F.In -Name '+HOST2' -Files @{ 'r.csv' = @($TimelineHeader, (New-TimelineRow '+WS03' 'high' 'R')) } | Out-Null
        $script:first = Invoke-TestBatch $F 'first'
    }

    It 'completes them all on the first run' {
        $first.Completed | Should -Be 3
    }
    It 'writes formula-like cells escaped in the raw file' {
        $raw = @{}; Import-Csv -LiteralPath $F.Manifest | ForEach-Object { $raw[$_.Source] = $_ }
        $raw["'-HOST"].Collection | Should -BeExactly "'-HOST"
        $raw["'-HOST"].Host | Should -BeExactly "'=WS01"
        $raw["'@HOST1"].Collection | Should -BeExactly '_HOST1'
        $raw["'@HOST1"].Host | Should -BeExactly "'@WS02"
        $raw["'+HOST2"].Collection | Should -BeExactly '_HOST2'
        $raw["'+HOST2"].Host | Should -BeExactly "'+WS03"
        $cells = foreach ($r in $raw.Values) { foreach ($p in $r.PSObject.Properties) { [string]$p.Value } }
        @($cells | Where-Object { $_ -match '^[=+\-@\t\r]' }).Count | Should -Be 0
    }
    It 'reads them back unescaped' {
        $m = Get-RunManifest -Path $F.Manifest
        $m.Contains('-HOST') | Should -BeTrue
        $m['-HOST'].Collection | Should -BeExactly '-HOST'
        $m['-HOST'].Source | Should -BeExactly '-HOST'
        $m['-HOST'].Host | Should -BeExactly '=WS01'
        $m['_HOST1'].Source | Should -BeExactly '@HOST1'
        $m['_HOST1'].Host | Should -BeExactly '@WS02'
        $m['_HOST2'].Source | Should -BeExactly '+HOST2'
        $m['_HOST2'].Host | Should -BeExactly '+WS03'
    }
    It 'skips them as already done on a second run, keeping the first RunId' {
        $second = Invoke-TestBatch $F 'second'
        $second.Skipped | Should -Be 3
        $second.Processed | Should -Be 0
        @(Get-FakeCall $F).Count | Should -Be 0
        (Get-RunManifest -Path $F.Manifest)['-HOST'].RunId | Should -Be 'first'
    }
    It 'runs them again with -Force' {
        $third = Invoke-TestBatch $F 'third' -Force
        $third.Processed | Should -Be 3
        Get-FakeCall $F | Should -Contain '-HOST'
        (Get-RunManifest -Path $F.Manifest)['-HOST'].RunId | Should -Be 'third'
    }
}

Describe 'One collection can never abort the batch' {
    BeforeAll { Mock Assert-HayabusaHost { } }

    It 'records a failure computing the host and carries on' {
        Mock Resolve-HostName { throw 'host lookup exploded' }
        $R = New-BatchRoot 'hostfail'
        foreach ($n in 'A1', 'A2', 'A3') { New-FakeHost -InputRoot $R.In -Name $n -Files @{ 'r.csv' = $good } | Out-Null }
        $s = Invoke-TestBatch $R 'h'
        $s.Processed | Should -Be 3
        $s.Failed | Should -Be 3
        $rows = Get-ManifestRowMap $R
        foreach ($n in 'A1', 'A2', 'A3') {
            $rows[$n].Status | Should -Be 'Failed'
            $rows[$n].Error | Should -BeLike '*Recording the result failed: host lookup exploded*'
        }
    }
    It 'survives a manifest write failure on one collection' {
        Mock Set-RunManifestEntry { throw 'disk full' } -ParameterFilter { $Collection -eq 'B2' }
        $R = New-BatchRoot 'writefail'
        foreach ($n in 'B1', 'B2', 'B3') { New-FakeHost -InputRoot $R.In -Name $n -Files @{ 'r.csv' = $good } | Out-Null }
        $s = Invoke-TestBatch $R 'w'
        $s.Processed | Should -Be 3
        $s.Completed | Should -Be 2
        $s.Failed | Should -Be 1
        ((Get-FakeCall $R | Sort-Object) -join ',') | Should -Be 'B1,B2,B3'
        $rows = Get-ManifestRowMap $R
        $rows.B1.Status | Should -Be 'Completed'
        $rows.B3.Status | Should -Be 'Completed'
    }
    It 'counts an unexpected exception from a whole collection run as Failed and continues' {
        Mock Invoke-CollectionRun { throw 'something unforeseen' } -ParameterFilter { $Collection.Collection -eq 'C2' }
        $R = New-BatchRoot 'runfail'
        foreach ($n in 'C1', 'C2', 'C3') { New-FakeHost -InputRoot $R.In -Name $n -Files @{ 'r.csv' = $good } | Out-Null }
        $s = Invoke-TestBatch $R 'r'
        $s.Processed | Should -Be 3
        $s.Completed | Should -Be 2
        $s.Failed | Should -Be 1
    }
}

Describe 'Progress lines' {
    BeforeAll {
        Mock Assert-HayabusaHost { }
        $script:P = New-BatchRoot 'progress'
        New-FakeHost -InputRoot $P.In -Name 'P1' -Files @{ 'r.csv' = $good } | Out-Null
        New-FakeHost -InputRoot $P.In -Name 'P2' -Files @{ 'r.csv' = @($TimelineHeader, (New-TimelineRow 'WS02' 'high' 'R')) } | Out-Null
        New-FakeHost -InputRoot $P.In -Name 'P3' -Behavior "EXIT=2`nCSV=none" | Out-Null
        New-FakeHost -InputRoot $P.In -Name 'P4' -Behavior "EXIT=3`nCSV=r.csv" -Files @{ 'r.csv' = @($TimelineHeader, (New-TimelineRow 'WS04' 'high' 'R')) } | Out-Null
        function script:Invoke-Captured($Root, [string]$RunId) {
            $iv = $null
            $w = $null
            $env:FAKE_CALLS = $Root.Calls
            try {
                $cols = @(Get-InputCollection -InputRoot $Root.In -WarningAction SilentlyContinue)
                Invoke-CollectionBatch -Collections $cols -ManifestPath $Root.Manifest -OutputRoot $Root.Out -HayabusaPath $hb -Resolved $resolved -Threads $null -RunId $RunId `
                    -InformationVariable iv -WarningVariable w -WarningAction SilentlyContinue | Out-Null
            }
            finally { Remove-Item Env:\FAKE_CALLS -ErrorAction SilentlyContinue }
            [pscustomobject]@{ Info = @($iv | ForEach-Object { "$_" }); Warn = @($w | ForEach-Object { "$_" }) }
        }
        $script:first = Invoke-Captured $P 'p1'
    }

    It 'prints Completed lines with the detection count' {
        $first.Info | Should -Contain '[1/4] P1 ... Completed, 3 detections'
        $first.Info | Should -Contain '[2/4] P2 ... Completed, 1 detection'
    }
    It 'warns for Failed and CompletedWithErrors, with the reason' {
        @($first.Warn | Where-Object { $_ -like '`[3/4`] P3 ... Failed: Hayabusa exited with code 2.*No CSV was written.' }).Count | Should -Be 1
        @($first.Warn | Where-Object { $_ -like '`[4/4`] P4 ... CompletedWithErrors, 1 detection: Hayabusa exited with code 3.*' }).Count | Should -Be 1
        @($first.Info | Where-Object { $_ -like '*P3*' -or $_ -like '*P4*' }).Count | Should -Be 0
    }
    It 'prints a skipped line on a rerun' {
        $again = Invoke-Captured $P 'p2'
        $again.Info | Should -Contain '[1/4] P1 ... skipped, already Completed'
        $again.Info | Should -Contain '[4/4] P4 ... skipped, already CompletedWithErrors'
    }
}

Describe 'An unreadable zip at run time' {
    BeforeAll {
        Mock Assert-HayabusaHost { }
        $script:Z = New-BatchRoot 'zipfail'
        $zp = New-TestZip -Path (Join-TestPath $Z.In 'BADZ.zip') -Entries ([ordered]@{ 'C/Windows/System32/winevt/Logs/Security.evtx' = (New-TestByteArray 40 -Random) })
        Edit-ZipHeader -Path $zp -Method 9
        $iv = $null
        $env:FAKE_CALLS = $Z.Calls
        try {
            $cols = @(Get-InputCollection -InputRoot $Z.In -WarningAction SilentlyContinue)
            Add-PendingCollection -Path $Z.Manifest -Collections $cols -RunId 'z' | Out-Null
            $script:zipPending = (Get-RunManifest -Path $Z.Manifest)['BADZ']
            Invoke-CollectionBatch -Collections $cols -ManifestPath $Z.Manifest -OutputRoot $Z.Out -HayabusaPath $hb -Resolved $resolved -Threads $null -RunId 'z' `
                -InformationVariable iv -WarningAction SilentlyContinue | Out-Null
        }
        finally { Remove-Item Env:\FAKE_CALLS -ErrorAction SilentlyContinue }
        $script:zipInfo = @($iv | ForEach-Object { "$_" })
        $script:zipRow = (Get-RunManifest -Path $Z.Manifest)['BADZ']
        $script:guide = "BADZ.zip can't be extracted by this tool (unsupported compression or encryption). Extract it yourself, put the extracted folder in InputRoot, and rerun."
    }

    It 'holds the guidance as a warning while Pending' {
        $zipPending.Warning | Should -BeExactly $guide
    }
    It 'stores the guidance once, as the error, when it fails' {
        $zipRow.Status | Should -Be 'Failed'
        $zipRow.Error | Should -BeExactly $guide
        $zipRow.Warning | Should -BeExactly ''
    }
    It 'refers back to the startup warning on its progress line' {
        $zipInfo | Should -Contain '[1/1] BADZ ... Failed: ZIP not extracted, see the warning at the start'
    }
    It 'puts the technical detail in the per-host log and does not run Hayabusa' {
        $log = Get-Content -LiteralPath (Join-TestPath $Z.Out 'BADZ' 'BADZ_hayabusa.log') -Raw
        $log | Should -Match ([regex]::Escape($guide))
        $log | Should -Match "Detail: entry 'C/Windows/System32/winevt/Logs/Security.evtx' uses compression method 9 \(Deflate64\)"
        $log | Should -Match 'Hayabusa was not run\.'
        @(Get-FakeCall $Z).Count | Should -Be 0
    }
    It 'keeps the escaping round trip for the deduplicated row' {
        $raw = @(Import-Csv -LiteralPath $Z.Manifest)
        $raw[0].Error | Should -BeExactly $guide
        $raw[0].Warning | Should -BeExactly ''
    }
}

Describe 'Off Windows' {
    It 'records each collection Failed before any extraction' {
        Mock Test-IsWindowsHost { $false }
        $R = New-BatchRoot 'linux'
        New-FakeHost -InputRoot $R.In -Name 'L1' -Files @{ 'r.csv' = $good } | Out-Null
        New-TestZip -Path (Join-TestPath $R.In 'L2.zip') -Entries ([ordered]@{ 'x.evtx' = 'x' }) | Out-Null
        $s = Invoke-TestBatch $R 'l'
        $s.Failed | Should -Be 2
        (Get-ManifestRowMap $R).L1.Error | Should -Be 'Running Hayabusa requires Windows.'
        Test-Path -LiteralPath (Join-TestPath $R.Out '_work') | Should -BeFalse
    }
}

Describe 'A rerun where Hayabusa writes nothing' {
    BeforeAll {
        Mock Assert-HayabusaHost { }
        $script:R = New-BatchRoot 'stale'
        $h = New-FakeHost -InputRoot $R.In -Name 'H1' -Files @{ 'r.csv' = $good }
        Invoke-TestBatch $R 'run1' | Out-Null
        $script:first = (Get-ManifestRowMap $R)['H1']
        $script:p = Get-CollectionOutputPath -OutputRoot $R.Out -Collection 'H1'
        $script:hadFiles = (Test-Path -LiteralPath $p.Csv) -and (Test-Path -LiteralPath $p.Html)
        Write-TestText -Path (Join-TestPath $h 'fake.behavior') -Line @('EXIT=2', 'CSV=none', 'HTML=none') | Out-Null
        Invoke-TestBatch $R 'run2' -Force | Out-Null
        $script:second = (Get-ManifestRowMap $R)['H1']
        Invoke-Rollup -OutputRoot $R.Out -WarningAction SilentlyContinue | Out-Null
        $script:hostRow = @(Import-Csv -LiteralPath (Join-TestPath $R.Out 'triage_hosts.csv') | Where-Object { $_.Collection -eq 'H1' })[0]
        $script:html = [System.IO.File]::ReadAllText((Join-TestPath $R.Out 'triage_dashboard.html'))
    }

    It 'starts from a finished first run with a report and timeline' {
        $first.Status | Should -Be 'Completed'
        $first.Detections | Should -Be '3'
        $hadFiles | Should -BeTrue
    }
    It 'records the -Force rerun Failed, with none of the first run''s counts' {
        $second.RunId | Should -Be 'run2'
        $second.Status | Should -Be 'Failed'
        $second.Host | Should -Be ''
        $second.Detections | Should -Be '0'
        $second.Critical | Should -Be '0'
        $second.Error | Should -BeLike 'Hayabusa exited with code 2.*No CSV was written.'
    }
    It 'removes the first run''s report and timeline before Hayabusa runs again' {
        Test-Path -LiteralPath $p.Csv | Should -BeFalse
        Test-Path -LiteralPath $p.Html | Should -BeFalse
    }
    It 'leaves no stale counts or report link in the rollup' {
        $hostRow.Status | Should -Be 'Failed'
        $hostRow.Total | Should -Be ''
        $html.Contains('H1/H1_report.html') | Should -BeFalse
        $html.Contains('H1/H1_timeline.csv') | Should -BeFalse
    }
}

Describe 'A Running mark that fails when the final write succeeds' {
    BeforeAll {
        Mock Assert-HayabusaHost { }
        $script:R = New-BatchRoot 'runmark'
        New-FakeHost -InputRoot $R.In -Name 'H1' -Files @{ 'r.csv' = $good } | Out-Null
        Mock Set-RunManifestEntry { throw 'manifest locked' } -ParameterFilter { $Status -eq 'Running' }
        Invoke-TestBatch $R 'run1' | Out-Null
        $script:row = (Get-ManifestRowMap $R)['H1']
    }

    It 'records Completed with no leftover error' {
        $row.Status | Should -Be 'Completed'
        $row.Error | Should -Be ''
    }
}

Describe 'A rerun that fails before Hayabusa starts' {
    BeforeAll {
        Mock Assert-HayabusaHost { }
        $script:R = New-BatchRoot 'prepfail'
        New-FakeHost -InputRoot $R.In -Name 'H1' -Files @{ 'r.csv' = $good } | Out-Null
        Invoke-TestBatch $R 'run1' | Out-Null
        $script:first = (Get-ManifestRowMap $R)['H1']
        $script:p = Get-CollectionOutputPath -OutputRoot $R.Out -Collection 'H1'
        $script:hadLog = Test-Path -LiteralPath $p.Log -PathType Leaf
        $script:callsRun1 = @(Get-FakeCall $R).Count
        Mock Resolve-CollectionInput { throw 'The image would not mount.' }
        Invoke-TestBatch $R 'run2' -Force | Out-Null
        $script:second = (Get-ManifestRowMap $R)['H1']
        $script:callsRun2 = @(Get-FakeCall $R).Count
        Invoke-Rollup -OutputRoot $R.Out -WarningAction SilentlyContinue | Out-Null
        $script:html = [System.IO.File]::ReadAllText((Join-TestPath $R.Out 'triage_dashboard.html'))
    }

    It 'starts from a finished first run with a log' {
        $first.Status | Should -Be 'Completed'
        $hadLog | Should -BeTrue
    }
    It 'records the rerun Failed with its own error, without running Hayabusa' {
        $second.RunId | Should -Be 'run2'
        $second.Status | Should -Be 'Failed'
        $second.Error | Should -BeLike '*The image would not mount.*'
        $callsRun1 | Should -Be 1
        $callsRun2 | Should -Be 0 -Because 'the fake Hayabusa records every call, and this run must not reach it'
    }
    It 'removes the earlier run''s log, so the Failed row links none' {
        Test-Path -LiteralPath $p.Log | Should -BeFalse
        $html.Contains('H1/H1_hayabusa.log') | Should -BeFalse
    }
}

Describe 'Evidence image hash' {
    BeforeAll {
        Mock Assert-HayabusaHost { }
        $script:R = New-BatchRoot 'image-hash'
        # IMGOK and IMGBAD stand in for disk image collections. The mount is
        # simulated: resolve records a hash pair as Mount-CollectionImage and
        # teardown would, then hands Hayabusa the collection folder.
        New-FakeHost -InputRoot $R.In -Name 'IMGOK' -Files @{ 'r.csv' = @($TimelineHeader, (New-TimelineRow 'WS01' 'high' 'RuleA')) } | Out-Null
        New-FakeHost -InputRoot $R.In -Name 'IMGBAD' -Files @{ 'r.csv' = @($TimelineHeader, (New-TimelineRow 'WS02' 'high' 'RuleA')) } | Out-Null
        New-FakeHost -InputRoot $R.In -Name 'LOOSE' -Files @{ 'r.csv' = @($TimelineHeader) } | Out-Null
        $script:goodHash = 'A' * 64
        $script:badHash = 'B' * 64
        Mock Resolve-CollectionInput {
            $after = $script:goodHash
            if ($Collection.Collection -eq 'IMGBAD') { $after = $script:badHash }
            $record = [pscustomobject]@{ ImagePath = "D:\Evidence\$($Collection.Collection).vhdx"; Before = $script:goodHash; After = $after; Match = ($after -eq $script:goodHash) }
            $ImageHashRecord.Add($record)
            [pscustomobject]@{
                Collection = $Collection.Collection; Source = $Collection.Source; InputType = 'Vhdx'; SourcePath = $Collection.SourcePath
                Path = $Collection.SourcePath; ImagePath = $record.ImagePath; ChildPath = $null; ExtractPath = $null; MountPath = $null
                ImageHash = $record; Warnings = (New-Object System.Collections.Generic.List[string]); Teardown = (New-Object System.Collections.Generic.List[object]); KeepArtifacts = $false
            }
        } -ParameterFilter { $Collection.Collection -like 'IMG*' }
        $script:hashes = [ordered]@{}
        $cols = @(Get-InputCollection -InputRoot $R.In -WarningAction SilentlyContinue)
        $w = $null
        $script:sum = Invoke-CollectionBatch -Collections $cols -ManifestPath $R.Manifest -OutputRoot $R.Out -HayabusaPath $hb -Resolved $resolved -Threads $null -RunId 'run1' -ImageHash $hashes -WarningVariable w -WarningAction SilentlyContinue
        $script:warns = @($w | ForEach-Object { "$_" })
        $script:rows = Get-ManifestRowMap $R
        Invoke-Rollup -OutputRoot $R.Out -WarningAction SilentlyContinue | Out-Null
        $script:html = [System.IO.File]::ReadAllText((Join-TestPath $R.Out 'triage_dashboard.html'))
    }

    It 'keeps a host whose image hashes the same Completed, and returns its record' {
        $rows.IMGOK.Status | Should -Be 'Completed'
        $rows.IMGOK.Error | Should -Be ''
        $hashes['IMGOK'].Before | Should -BeExactly $goodHash
        $hashes['IMGOK'].After | Should -BeExactly $goodHash
        $hashes['IMGOK'].Match | Should -BeTrue
    }
    It 'fails a host whose image hashed differently, the integrity error first, even though Hayabusa succeeded' {
        $rows.IMGBAD.Status | Should -Be 'Failed'
        $rows.IMGBAD.Error | Should -BeLike "Evidence integrity check failed: the SHA-256 of D:\Evidence\IMGBAD.vhdx changed during this run, from $goodHash before it was mounted to $badHash after teardown.*"
        $rows.IMGBAD.Detections | Should -Be '1'
        $hashes['IMGBAD'].Match | Should -BeFalse
        $sum.Failed | Should -Be 1
        @($warns | Where-Object { $_ -like '*IMGBAD ... Failed: Evidence integrity check failed*' }).Count | Should -Be 1
    }
    It 'returns no record for a loose collection' {
        $hashes.Contains('LOOSE') | Should -BeTrue
        $hashes['LOOSE'] | Should -BeNullOrEmpty
    }
    It 'heads the dashboard with the failure and shows it in the host''s notes' {
        $html | Should -Match '<div class="warnbox evidence">Evidence integrity check failed for 1 collection\(s\): IMGBAD\.'
        $html | Should -Match '<span class="err">Evidence integrity check failed: the SHA-256 of '
        $box = [regex]::Match($html, '<div class="warnbox evidence">[^<]*</div>').Value
        $box.Contains('IMGOK') | Should -BeFalse
    }
}

Describe 'Run-meta after each host' {
    BeforeAll {
        Mock Assert-HayabusaHost { }
        $script:R = New-BatchRoot 'runmeta-per-host'
        foreach ($n in 'IMG1', 'IMG2') {
            New-FakeHost -InputRoot $R.In -Name $n -Files @{ 'r.csv' = @($TimelineHeader, (New-TimelineRow 'WS01' 'high' 'RuleA')) } | Out-Null
        }
        $script:hash1 = 'C' * 64
        $script:metaPath = Get-RunMetaPath -OutputRoot $R.Out -StartedUtc (Get-Date).ToUniversalTime() -RunId 'run1'
        $cols = @(Get-InputCollection -InputRoot $R.In -WarningAction SilentlyContinue)
        $script:meta = [ordered]@{
            SchemaVersion = 7
            RunId         = 'run1'
            StartedUtc    = '2026-10-16T00:00:00Z'
            CompletedUtc  = $null
            Summary       = $null
            Selection     = [ordered]@{ MinLevel = 'medium'; ExactLevel = $null; Profile = 'standard' }
            Collections   = @($cols | ForEach-Object { [ordered]@{ Collection = $_.Collection; Source = $_.Source; InputType = 'Vhdx'; ImagePath = $null; ImageSha256Before = $null; ImageSha256After = $null; ImageHashMatch = $null } })
        }
        Save-RunMeta -Path $metaPath -RunMeta $meta | Out-Null

        # The mount is simulated as in the image hash tests. When IMG2 starts,
        # IMG1 has finished but the run has not: the record on disk at that
        # point is what an interrupt there would leave.
        $script:midRun = $null
        $script:midRollup = $null
        Mock Resolve-CollectionInput {
            if ($Collection.Collection -eq 'IMG2') {
                $script:midRun = Get-Content -LiteralPath $script:metaPath -Raw | ConvertFrom-Json
                $script:midRollup = Get-RollupData -OutputRoot $script:R.Out -WarningAction SilentlyContinue
            }
            $record = [pscustomobject]@{ ImagePath = "D:\Evidence\$($Collection.Collection).vhdx"; Before = $script:hash1; After = $script:hash1; Match = $true }
            $ImageHashRecord.Add($record)
            [pscustomobject]@{
                Collection = $Collection.Collection; Source = $Collection.Source; InputType = 'Vhdx'; SourcePath = $Collection.SourcePath
                Path = $Collection.SourcePath; ImagePath = $record.ImagePath; ChildPath = $null; ExtractPath = $null; MountPath = $null
                ImageHash = $record; Warnings = (New-Object System.Collections.Generic.List[string]); Teardown = (New-Object System.Collections.Generic.List[object]); KeepArtifacts = $false
            }
        }
        Invoke-CollectionBatch -Collections $cols -ManifestPath $R.Manifest -OutputRoot $R.Out -HayabusaPath $hb -Resolved $resolved -Threads $null -RunId 'run1' -RunMeta $meta -RunMetaPath $metaPath -WarningAction SilentlyContinue | Out-Null
        $script:final = Get-Content -LiteralPath $metaPath -Raw | ConvertFrom-Json
    }

    It 'has a finished host''s image hashes on disk before the run ends' {
        $midRun | Should -Not -BeNullOrEmpty
        $img1 = @($midRun.Collections | Where-Object { $_.Collection -eq 'IMG1' })[0]
        $img1.ImagePath | Should -Be 'D:\Evidence\IMG1.vhdx'
        $img1.ImageSha256Before | Should -BeExactly $hash1
        $img1.ImageSha256After | Should -BeExactly $hash1
        $img1.ImageHashMatch | Should -BeTrue
    }
    It 'marks that record as from an unfinished run, with the counts so far and nothing yet for the next host' {
        $midRun.CompletedUtc | Should -BeNullOrEmpty
        $midRun.Summary.Processed | Should -Be 1
        $midRun.Summary.Completed | Should -Be 1
        $img2 = @($midRun.Collections | Where-Object { $_.Collection -eq 'IMG2' })[0]
        $img2.ImageSha256Before | Should -BeNullOrEmpty
        $img2.ImageHashMatch | Should -BeNullOrEmpty
    }
    It 'leaves a record the rollup can read mid-run' {
        $midRollup | Should -Not -BeNullOrEmpty
        $p = @($midRollup.Provenance | Where-Object { $_.RunId -eq 'run1' })
        $p.Count | Should -Be 1
        $p[0].Found | Should -BeTrue
        $p[0].StartedUtc | Should -Be '2026-10-16T00:00:00Z'
        $p[0].Floor | Should -Be 'min medium'
    }
    It 'has both hosts once the batch ends, and no temporary file left behind' {
        foreach ($n in 'IMG1', 'IMG2') {
            @($final.Collections | Where-Object { $_.Collection -eq $n })[0].ImageHashMatch | Should -BeTrue
        }
        $final.Summary.Processed | Should -Be 2
        Test-Path -LiteralPath "$metaPath.tmp" | Should -BeFalse
    }
}
