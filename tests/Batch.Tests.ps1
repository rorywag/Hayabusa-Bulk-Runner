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
        New-FakeHost -InputRoot $R.In -Name 'H4' -Behavior "EXIT=0`nCSV=none" | Out-Null
        New-FakeHost -InputRoot $R.In -Name 'H6' -Files @{ 'r.csv' = @($TimelineHeader) } | Out-Null
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

    It 'runs all eight, so one bad host does not stop the rest' {
        $sum1.Processed | Should -Be 8
        $calls1.Count | Should -Be 8
    }
    It 'counts outcomes' {
        $sum1.Completed | Should -Be 5
        $sum1.CompletedWithErrors | Should -Be 1
        $sum1.Failed | Should -Be 2
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
    It 'exit 0 without a CSV: Completed with zero counts and a warning' {
        $rows.H4.Status | Should -Be 'Completed'
        $rows.H4.Detections | Should -Be '0'
        $rows.H4.Warning | Should -BeLike '*wrote no CSV*'
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
        $sum2.Processed | Should -Be 2
        ((Get-FakeCall $R | Sort-Object) -join ',') | Should -Be 'H3,H7'
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
        $sum4.Processed | Should -Be 8
        (Get-FakeCall $R).Count | Should -Be 8
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
