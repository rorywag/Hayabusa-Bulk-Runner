BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers/TestHelpers.ps1')
    $script:out = New-RollupFixture -OutputRoot (Join-TestPath $TestDrive 'out')
    $script:mp = Join-TestPath $out 'run_manifest.csv'
    $script:before = Get-FileHashMap -Path $out
    $w = $null
    $script:res = Invoke-Rollup -OutputRoot $out -WarningVariable w -WarningAction SilentlyContinue
    $script:warns = @($w | ForEach-Object { "$_" })
    $script:hostsCsv = @(Import-Csv -LiteralPath (Join-TestPath $out 'triage_hosts.csv'))
    $script:rulesCsv = @(Import-Csv -LiteralPath (Join-TestPath $out 'triage_rules.csv'))
    $script:byC = @{}
    foreach ($r in $hostsCsv) { $byC[$r.Collection] = $r }
    function script:Get-Header([string]$Path) { (Get-Content -LiteralPath $Path -TotalCount 1).TrimStart([char]0xFEFF) }
}

Describe 'triage_hosts.csv' {
    It 'has the expected columns' {
        Get-Header (Join-TestPath $out 'triage_hosts.csv') | Should -BeExactly '"Host","Collection","Status","Emergency","Critical","High","Medium","Low","Total","TopRule"'
    }
    It 'has one row per manifest row' {
        $hostsCsv.Count | Should -Be 11
        $res.HostCount | Should -Be 11
    }
    It 'sorts worst first, problem statuses before clean among ties' {
        ($hostsCsv.Collection -join ',') | Should -BeExactly "WS01,MULTI,'-HOST,WS02,CWE,FAILCSV,FAILNOCSV,RUN,PEND,BADCSV,C"
    }
    It 'aggregates counts by level from the per-host CSV' {
        $r = $byC.WS01
        $r.Critical | Should -Be '2'
        $r.High | Should -Be '4'
        $r.Medium | Should -Be '1'
        $r.Low | Should -Be '1'
        $r.Total | Should -Be '8'
    }
    It 'counts full and short level names alike' {
        $byC.WS02.Critical | Should -Be '1'
        $byC.WS02.High | Should -Be '1'
        $byC.WS02.Medium | Should -Be '1'
    }
    It 'picks TopRule by highest severity, then most hits' {
        $byC.WS01.TopRule | Should -Be 'RuleA'
        $byC.CWE.TopRule | Should -Be 'RuleB'
        $byC.WS02.TopRule | Should -Be 'RuleA'
    }
    It 'shows a clean host as [unknown] with zero counts and no TopRule' {
        $byC.C.Host | Should -BeExactly '[unknown]'
        $byC.C.Total | Should -Be '0'
        $byC.C.Critical | Should -Be '0'
        $byC.C.TopRule | Should -Be ''
        $byC.C.Status | Should -Be 'Completed'
    }
    It 'leaves counts blank, not zero, for a Failed row without a CSV' {
        $byC.FAILNOCSV.Status | Should -Be 'Failed'
        $byC.FAILNOCSV.Host | Should -BeExactly '[unknown]'
        $byC.FAILNOCSV.Critical | Should -Be ''
        $byC.FAILNOCSV.Total | Should -Be ''
    }
    It 'leaves counts blank for a Failed row, even with a CSV on disk' {
        $byC.FAILCSV.Status | Should -Be 'Failed'
        $byC.FAILCSV.Host | Should -Be 'WS04'
        $byC.FAILCSV.High | Should -Be ''
        $byC.FAILCSV.Total | Should -Be ''
        $byC.FAILCSV.TopRule | Should -Be ''
        $rulesCsv.RuleTitle | Should -Not -Contain 'RuleE'
    }
    It 'counts CompletedWithErrors' {
        $byC.CWE.Status | Should -Be 'CompletedWithErrors'
        $byC.CWE.High | Should -Be '2'
    }
    It 'does not read the CSV of a Pending or Running row' {
        $byC.PEND.Total | Should -Be ''
        $byC.RUN.Total | Should -Be ''
        $rulesCsv.RuleTitle | Should -Not -Contain 'StaleRule'
        $rulesCsv.RuleTitle | Should -Not -Contain 'HalfRule'
    }
    It 'shows a multi-Computer host by its computer names' {
        $byC.MULTI.Host | Should -BeExactly 'DC01, DC01.corp.local'
        $byC.MULTI.Critical | Should -Be '2'
    }
    It 'leaves the [multiple] marker in the manifest' {
        (Get-RunManifest -Path $mp)['MULTI'].Host | Should -BeExactly '[multiple]'
    }
    It 'leaves an unreadable CSV blank and warns' {
        $byC.BADCSV.Total | Should -Be ''
        @($warns | Where-Object { $_ -like 'Rollup: BADCSV: *missing column(s) RuleTitle*' }).Count | Should -Be 1
    }
}

Describe 'A Failed row with files left from an earlier run' {
    BeforeAll {
        # A rerun that failed while its input was prepared, before Hayabusa
        # ran, so the previous run's timeline, report and log are still there.
        $script:fo = New-TestDirectory (Join-TestPath $TestDrive 'failed-leftover')
        $fm = Join-TestPath $fo 'run_manifest.csv'
        Initialize-RunManifest -Path $fm | Out-Null
        Set-RunManifestEntry -Path $fm -Collection 'H1' -Source 'H1' -RunId 'run2' -InputType Loose -Status Failed -ErrorMessage @('Resolve: could not attach the disk image')
        $p = Get-CollectionOutputPath -OutputRoot $fo -Collection 'H1'
        Write-TestText -Path $p.Csv -Line @($TimelineHeader, (New-TimelineRow -Computer 'WS07' -Level 'crit' -Title 'OldRule')) | Out-Null
        Write-TestText -Path $p.Html -Line @('<html></html>') | Out-Null
        Write-TestText -Path $p.Log -Line @('log') | Out-Null
        $script:fHost = @((Get-RollupData -OutputRoot $fo).Hosts)[0]
        Invoke-Rollup -OutputRoot $fo -WarningAction SilentlyContinue | Out-Null
        $script:fRow = @(Import-Csv -LiteralPath (Join-TestPath $fo 'triage_hosts.csv'))[0]
        $script:fRules = @(Import-Csv -LiteralPath (Join-TestPath $fo 'triage_rules.csv'))
        $script:fHtml = [System.IO.File]::ReadAllText((Join-TestPath $fo 'triage_dashboard.html'))
    }

    It 'shows no counts or top rule from the leftover timeline' {
        $fRow.Status | Should -Be 'Failed'
        foreach ($level in @('Emergency', 'Critical', 'High', 'Medium', 'Low', 'Total', 'TopRule')) {
            $fRow.$level | Should -Be '' -Because "$level comes from the earlier run"
        }
        @($fRules | Where-Object { $_.RuleTitle -eq 'OldRule' }).Count | Should -Be 0
        $fHtml.Contains('OldRule') | Should -BeFalse
    }
    It 'links the log, but not the leftover report or timeline' {
        (@($fHost.Links.Keys) -join ',') | Should -BeExactly 'Log'
        $fHtml.Contains('H1/H1_hayabusa.log') | Should -BeTrue
        $fHtml.Contains('H1/H1_report.html') | Should -BeFalse
        $fHtml.Contains('H1/H1_timeline.csv') | Should -BeFalse
    }
    It 'keeps the row''s error' {
        $fHtml.Contains('Resolve: could not attach the disk image') | Should -BeTrue
    }
}

Describe 'Multiple-computer label' {
    It 'joins up to three names, most rows first' {
        $c = [ordered]@{ 'WS01' = 5; 'WS01.corp.local' = 2 }
        Get-MultipleHostLabel -Computers $c | Should -BeExactly 'WS01, WS01.corp.local'
    }
    It 'adds +N past three names' {
        $c = [ordered]@{ 'WS01' = 9; 'WS02' = 5; 'WS03' = 4; 'WS04' = 2; 'WS05' = 1 }
        Get-MultipleHostLabel -Computers $c | Should -BeExactly 'WS01, WS02, WS03 +2'
    }
    It 'falls back to [multiple] when the CSV cannot be read' {
        $o = New-TestDirectory (Join-TestPath $TestDrive 'multi-unread')
        $m = Join-TestPath $o 'run_manifest.csv'
        Initialize-RunManifest -Path $m | Out-Null
        Set-RunManifestEntry -Path $m -Collection 'M2' -Source 'M2' -RunId 'r' -InputType Loose -Status Pending -HostName '[multiple]'
        @((Get-RollupData -OutputRoot $o).Hosts)[0].Host | Should -BeExactly '[multiple]'
    }
}

Describe 'triage_rules.csv' {
    It 'has the expected columns' {
        Get-Header (Join-TestPath $out 'triage_rules.csv') | Should -BeExactly '"RuleTitle","Level","HostsAffected","TotalHits"'
    }
    It 'aggregates a rule across hosts, counting a [multiple] collection once' {
        $a = @($rulesCsv | Where-Object { $_.RuleTitle -eq 'RuleA' })
        $a.Count | Should -Be 1
        $a[0].Level | Should -Be 'critical'
        $a[0].HostsAffected | Should -Be '3'
        $a[0].TotalHits | Should -Be '5'
    }
    It 'gives the same title at two levels two rows' {
        ((@($rulesCsv | Where-Object { $_.RuleTitle -eq 'RuleF' }).Level | Sort-Object) -join ',') | Should -Be 'high,medium'
    }
    It 'sorts by severity, then hosts affected, then hits' {
        $rank = @{ emergency = 6; critical = 5; high = 4; medium = 3; low = 2; informational = 1 }
        for ($i = 1; $i -lt $rulesCsv.Count; $i++) {
            $rank[$rulesCsv[$i].Level] | Should -Not -BeGreaterThan $rank[$rulesCsv[$i - 1].Level]
        }
        $rulesCsv[0].RuleTitle | Should -Be 'RuleA'
        @($rulesCsv | Where-Object { $_.Level -eq 'high' })[0].RuleTitle | Should -Be 'RuleB'
    }
    It 'has one row per rule and level' {
        $rulesCsv.Count | Should -Be 13
        $res.RuleCount | Should -Be 13
    }
}

Describe 'CSV injection in the triage files' {
    It 'neutralises formula-like rule titles' {
        $t = @($rulesCsv.RuleTitle)
        $t | Should -Contain "'=HYPERLINK(""http://x"",""click"")"
        $t | Should -Contain "'@SUM(1+1)"
        $t | Should -Contain "'-2+3"
        $t | Should -Contain "'+cmd|'/c calc'!A1"
    }
    It 'neutralises a formula-like collection name read back from the manifest' {
        $hostsCsv.Collection | Should -Contain "'-HOST"
        $hostsCsv.Collection | Should -Not -Contain "''-HOST"
    }
    It 'leaves ordinary values and HTML-ish text unchanged' {
        $byC.WS01.Host | Should -BeExactly 'WS01'
        $byC["'-HOST"].Host | Should -BeExactly '"><img src=x onerror=alert(1)>'
        $byC["'-HOST"].TopRule | Should -BeExactly '<script>alert(1)</script>'
    }
    It 'has no cell anywhere starting with a formula character' {
        $cells = foreach ($r in @($hostsCsv) + @($rulesCsv)) { foreach ($p in $r.PSObject.Properties) { [string]$p.Value } }
        @($cells | Where-Object { $_ -match '^[=+\-@\t\r]' }).Count | Should -Be 0
    }
    It 'writes the triage CSVs with a BOM and the manifest without' {
        Test-Utf8Bom -Path (Join-TestPath $out 'triage_hosts.csv') | Should -BeTrue
        Test-Utf8Bom -Path (Join-TestPath $out 'triage_rules.csv') | Should -BeTrue
        Test-Utf8Bom -Path $mp | Should -BeFalse
    }
    It 'encodes values with ConvertTo-SafeCsvValue' -ForEach @(
        @{ In = '=1+1'; Out = "'=1+1" }, @{ In = '+1'; Out = "'+1" }, @{ In = '-1'; Out = "'-1" }, @{ In = '@x'; Out = "'@x" }
        @{ In = "`tx"; Out = "'`tx" }, @{ In = "`rx"; Out = "'`rx" }, @{ In = 'plain'; Out = 'plain' }, @{ In = ''; Out = '' }
    ) {
        ConvertTo-SafeCsvValue -Value $In | Should -BeExactly $Out
    }
}

Describe 'Rollup leaves its inputs alone' {
    It 'never modifies the manifest or per-host files' {
        foreach ($k in $before.Keys) { (Get-FileHash -LiteralPath $k -Algorithm SHA256).Hash | Should -Be $before[$k] -Because $k }
    }
    It 'leaves no temp files behind' {
        @(Get-ChildItem -LiteralPath $out -Filter '*.tmp' -Recurse).Count | Should -Be 0
    }
}

Describe 'Standalone regeneration' {
    BeforeAll {
        $script:copyHosts = [System.IO.File]::ReadAllBytes((Join-TestPath $out 'triage_hosts.csv'))
        $script:copyRules = [System.IO.File]::ReadAllBytes((Join-TestPath $out 'triage_rules.csv'))
        $script:copyHtml = [System.IO.File]::ReadAllText((Join-TestPath $out 'triage_dashboard.html'))
        foreach ($f in 'triage_hosts.csv', 'triage_rules.csv', 'triage_dashboard.html') { Remove-Item -LiteralPath (Join-TestPath $out $f) }
        Start-Sleep -Milliseconds 1100
        $script:regen = & $RollupScript -OutputRoot $out -WarningAction SilentlyContinue
    }

    It 'rebuilds identical CSVs and the same dashboard apart from the build time' {
        $regen.HostCount | Should -Be 11
        $regen.RuleCount | Should -Be 13
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes((Join-TestPath $out 'triage_hosts.csv'))) | Should -BeExactly ([Convert]::ToBase64String($copyHosts))
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes((Join-TestPath $out 'triage_rules.csv'))) | Should -BeExactly ([Convert]::ToBase64String($copyRules))
        $h2 = [System.IO.File]::ReadAllText((Join-TestPath $out 'triage_dashboard.html'))
        $h2 | Should -Not -BeExactly $copyHtml
        ($h2 -replace 'Built [0-9TZ:-]+ from', 'Built X from') | Should -BeExactly ($copyHtml -replace 'Built [0-9TZ:-]+ from', 'Built X from')
    }
    It 'also leaves the manifest and per-host files untouched' {
        foreach ($k in $before.Keys) { (Get-FileHash -LiteralPath $k -Algorithm SHA256).Hash | Should -Be $before[$k] -Because $k }
    }
    It 'refuses an OutputRoot without a manifest and writes nothing there' {
        $empty = New-TestDirectory (Join-TestPath $TestDrive 'no-manifest')
        Get-ThrownMessage { & $RollupScript -OutputRoot $empty } | Should -BeLike '*No run_manifest.csv*'
        @(Get-ChildItem -LiteralPath $empty).Count | Should -Be 0
    }
    It 'refuses a manifest with the wrong columns and does not rewrite it' {
        $bad = New-TestDirectory (Join-TestPath $TestDrive 'bad-manifest')
        Write-TestText -Path (Join-TestPath $bad 'run_manifest.csv') -Line @('"Host","RunId","Status"') | Out-Null
        Get-ThrownMessage { & $RollupScript -OutputRoot $bad } | Should -BeLike '*unexpected columns*'
        (Get-Content -LiteralPath (Join-TestPath $bad 'run_manifest.csv')) -join '' | Should -BeExactly '"Host","RunId","Status"'
        Test-Path -LiteralPath (Join-TestPath $bad 'triage_dashboard.html') | Should -BeFalse
    }
    It 'gives empty but valid outputs for an empty manifest' {
        $o = New-TestDirectory (Join-TestPath $TestDrive 'empty-manifest')
        Initialize-RunManifest -Path (Join-TestPath $o 'run_manifest.csv') | Out-Null
        $r = Invoke-Rollup -OutputRoot $o
        $h = [System.IO.File]::ReadAllText((Join-TestPath $o 'triage_dashboard.html'))
        $r.HostCount | Should -Be 0
        $h | Should -Match 'No detections at the severity floor'
        $h | Should -Match 'No collections in the manifest'
        @(Import-Csv -LiteralPath (Join-TestPath $o 'triage_hosts.csv')).Count | Should -Be 0
    }
}

Describe 'Rollup after a real batch' {
    BeforeAll {
        Mock Assert-HayabusaHost { }
        $hb = New-FakeHayabusa -Directory (Join-TestPath $TestDrive 'tool')
        $in = New-TestDirectory (Join-TestPath $TestDrive 'batch-in')
        New-FakeHost -InputRoot $in -Name 'HA' -Files @{ 'r.csv' = (@($TimelineHeader) + @(New-TimelineRowSet 'HA' 'crit' 'R1' 2) + @(New-TimelineRow 'HA' 'high' 'R2')) } | Out-Null
        New-FakeHost -InputRoot $in -Name 'HB' -Files @{ 'r.csv' = (@($TimelineHeader) + @(New-TimelineRowSet 'HB' 'high' 'R2' 4)) } | Out-Null
        New-FakeHost -InputRoot $in -Name 'EMERONLY' -Files @{ 'r.csv' = (@($TimelineHeader) + @(New-TimelineRow 'EM01' 'emer' 'Ransom note dropped')) } | Out-Null
        New-FakeHost -InputRoot $in -Name 'CRITMANY' -Files @{ 'r.csv' = (@($TimelineHeader) + @(New-TimelineRowSet 'CR01' 'crit' 'Mimikatz use' 9) + @(New-TimelineRowSet 'CR01' 'high' 'PsExec' 3)) } | Out-Null
        New-FakeHost -InputRoot $in -Name 'BOTH' -Files @{ 'r.csv' = (@($TimelineHeader) + @(New-TimelineRowSet 'BO01' 'emergency' 'Ransom note dropped' 2) + @(New-TimelineRowSet 'BO01' 'crit' 'Mimikatz use' 5)) } | Out-Null
        $script:bo = New-TestDirectory (Join-TestPath $TestDrive 'batch-out')
        $script:bm = Join-TestPath $bo 'run_manifest.csv'
        Initialize-RunManifest -Path $bm | Out-Null
        Invoke-CollectionBatch -Collections @(Get-InputCollection -InputRoot $in) -ManifestPath $bm -OutputRoot $bo -HayabusaPath $hb -Resolved (Get-TestRunSetting -HayabusaPath $hb) -Threads $null -RunId 'b1' | Out-Null
        Invoke-Rollup -OutputRoot $bo | Out-Null
        $script:man = Get-RunManifest -Path $bm
        $script:bHosts = @(Import-Csv -LiteralPath (Join-TestPath $bo 'triage_hosts.csv'))
        $script:bRules = @(Import-Csv -LiteralPath (Join-TestPath $bo 'triage_rules.csv'))
        $script:tri = @{}
        foreach ($r in $bHosts) { $tri[$r.Collection] = $r }
    }

    It 'agrees with the manifest counts' {
        $tri.HA.Critical | Should -Be '2'
        $tri.HB.High | Should -Be '4'
        foreach ($c in 'HA', 'HB', 'BOTH') {
            $tri[$c].Critical | Should -Be $man[$c].Critical
            $tri[$c].High | Should -Be $man[$c].High
            $tri[$c].Emergency | Should -Be $man[$c].Emergency
            $tri[$c].Total | Should -Be $man[$c].Detections
        }
    }
    It 'writes the Emergency count to the manifest' {
        $man.EMERONLY.Emergency | Should -Be '1'
        $man.BOTH.Emergency | Should -Be '2'
        $man.BOTH.Critical | Should -Be '5'
        $man.CRITMANY.Emergency | Should -Be '0'
    }
    It 'sees R2 on both hosts' {
        $r = @($bRules | Where-Object { $_.RuleTitle -eq 'R2' })
        $r[0].HostsAffected | Should -Be '2'
        $r[0].TotalHits | Should -Be '5'
    }
    It 'ranks one emergency above nine criticals' {
        ((@($bHosts | Where-Object { @('BOTH', 'EMERONLY', 'CRITMANY') -contains $_.Collection }).Collection) -join ',') | Should -BeExactly 'BOTH,EMERONLY,CRITMANY'
    }
    It 'picks an emergency rule as TopRule over a critical rule with more hits' {
        $tri.BOTH.TopRule | Should -Be 'Ransom note dropped'
    }
    It 'ranks emergency rules first' {
        $bRules[0].RuleTitle | Should -Be 'Ransom note dropped'
        $bRules[0].Level | Should -Be 'emergency'
        $bRules[0].HostsAffected | Should -Be '2'
        $bRules[1].Level | Should -Be 'critical'
    }
}
