BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers/TestHelpers.ps1')
    $script:out = New-RollupFixture -OutputRoot (Join-TestPath $TestDrive 'out')
    Invoke-Rollup -OutputRoot $out -WarningAction SilentlyContinue | Out-Null
    $script:html = [System.IO.File]::ReadAllText((Join-TestPath $out 'triage_dashboard.html'))
}

Describe 'Evidence values in the dashboard' {
    It 'contains no script, img or iframe tag from the evidence' {
        $html | Should -Not -Match '(?i)<script'
        $html | Should -Not -Match '(?i)<img'
        $html | Should -Not -Match '(?i)<iframe'
    }
    It 'shows the malicious values only in encoded form' {
        $html.Contains('&lt;script&gt;alert(1)&lt;/script&gt;') | Should -BeTrue
        $html.Contains('&quot;&gt;&lt;img src=x onerror=alert(1)&gt;') | Should -BeTrue
        $html.Contains('&#39; onmouseover=&#39;x') | Should -BeTrue
        $html.Contains('&lt;/td&gt;&lt;/tr&gt;&lt;/table&gt;&lt;iframe src=//evil.example&gt;') | Should -BeTrue
        $html.Contains("' onmouseover='x") | Should -BeFalse
        $html.Contains('"><img') | Should -BeFalse
    }
    It 'keeps the table structure intact' {
        [regex]::Matches($html, '<table>').Count | Should -Be 3
        [regex]::Matches($html, '</table>').Count | Should -Be 3
        ([regex]::Match($html, '(?s)<h2 id="rules">.*?</tbody>').Value -split '<tr>').Count | Should -Be 15
    }
    It 'has a CSP that forbids script, and no external references' {
        $html.Contains("<meta http-equiv=""Content-Security-Policy"" content=""default-src &#39;none&#39;; style-src &#39;unsafe-inline&#39;"">") | Should -BeTrue
        $html | Should -Not -Match '(?i)<[a-z][^>]*\s(src|href)="(https?:|//|javascript:)'
        $html | Should -Not -Match '(?i)<[a-z][^>]*\ssrc='
        $html | Should -Not -Match '(?i)<link'
    }
    It 'only uses badge classes from known values' {
        $known = @('emergency', 'critical', 'high', 'medium', 'low', 'informational', 'other', 'Completed', 'CompletedWithErrors', 'Failed', 'Pending', 'Running', 'Skipped')
        $classes = @([regex]::Matches($html, 'class="badge (lv|st)-([^"]+)"') | ForEach-Object { $_.Groups[2].Value } | Sort-Object -Unique)
        @($classes | Where-Object { $known -notcontains $_ }).Count | Should -Be 0
    }
}

Describe 'Encoders' {
    It 'HTML-encodes all five characters' {
        ConvertTo-HtmlText -Text "&<>`"'" | Should -BeExactly '&amp;&lt;&gt;&quot;&#39;'
    }
    It 'URL-encodes then HTML-encodes an href' {
        ConvertTo-RelativeHref -Segment @('a b&c', 'x"y.html') | Should -BeExactly 'a%20b%26c/x%22y.html'
    }
}

Describe 'Layout and content' {
    It 'puts the summary first, then rules, hosts and provenance' {
        $iSum = $html.IndexOf('Top emergency, critical and high rules')
        $iRules = $html.IndexOf('<h2 id="rules">')
        $iHosts = $html.IndexOf('<h2 id="hosts">')
        $iProv = $html.IndexOf('<h2 id="provenance">')
        $iSum | Should -BeGreaterThan 0
        $iRules | Should -BeGreaterThan $iSum
        $iHosts | Should -BeGreaterThan $iRules
        $iProv | Should -BeGreaterThan $iHosts
    }
    It 'leads the summary with the top critical and high rules' {
        $panel = [regex]::Match($html, '(?s)Top emergency, critical and high rules</h3>(.*?)</div>').Groups[1].Value
        $panel.IndexOf('RuleA') | Should -BeGreaterOrEqual 0
        $panel.IndexOf('RuleA') | Should -BeLessThan $panel.IndexOf('RuleB')
        $panel | Should -Not -Match 'RuleC'
    }
    It 'shows totals and health counts' {
        $html | Should -Match '<div class="n">6</div><div class="l">critical detections</div>'
        $html | Should -Match '<b>11</b> hosts'
        $html | Should -Match '<b>2</b> Failed'
        $html | Should -Match '<b>1</b> CompletedWithErrors'
        $html | Should -Match '<b>2</b> not yet run'
    }
    It 'links relatively, and only to files that exist' {
        $html.Contains('<a href="WS01/WS01_report.html">Report</a><a href="WS01/WS01_timeline.csv">Timeline</a><a href="WS01/WS01_hayabusa.log">Log</a>') | Should -BeTrue
        $html.Contains('<a href="C/C_timeline.csv">Timeline</a>') | Should -BeTrue
        $html.Contains('C/C_report.html') | Should -BeFalse
        $html.Contains('FAILNOCSV/') | Should -BeFalse
        $html.Contains('PEND/PEND_timeline.csv') | Should -BeFalse
        $html.Contains('RUN/RUN_timeline.csv') | Should -BeFalse
    }
    It 'tags a clean host as host unknown' {
        $html.Contains('<td><span class="chip">C</span><span class="tag">host unknown</span></td>') | Should -BeTrue
    }
    It 'explains a Failed row' {
        $html.Contains('<span class="err">Resolve: archive refused</span>') | Should -BeTrue
    }
    It 'shows paths under OutputRoot relative to it' {
        $html.Contains('missing column(s) RuleTitle: ' + (Join-Path 'BADCSV' 'BADCSV_timeline.csv')) | Should -BeTrue
        $html.Contains('See ' + (Join-Path 'CWE' 'CWE_hayabusa.log')) | Should -BeTrue
        $html.Contains($out) | Should -BeFalse
    }
}

Describe 'Display refinements' {
    It 'shows a multiple-computer host by its names, with a tag' {
        $html.Contains('<td><span class="chip">DC01</span> <span class="chip">DC01.corp.local</span><span class="tag">multiple</span></td>') | Should -BeTrue
    }
    It 'heads the host table''s first column Hostname' {
        $html.Contains('<thead><tr><th>Hostname</th><th>Collection</th>') | Should -BeTrue
    }
    It 'shows a single host name as a chip' {
        $html.Contains('<tr><td><span class="chip">WS01</span></td><td>WS01</td>') | Should -BeTrue
    }
    It 'shows each collection a rule was seen on as a chip' {
        $html.Contains('<td>RuleA</td><td class="n">3</td><td class="n">5</td><td><span class="chip">MULTI</span> <span class="chip">WS01</span> <span class="chip">WS02</span></td></tr>') | Should -BeTrue
    }
    It 'styles chips grey, wrapping, with no fixed width' {
        $css = [regex]::Match($html, '\.chip \{[^}]*\}').Value
        $css | Should -Match 'color: var\(--info\); background: var\(--info-bg\);'
        $css | Should -Match 'overflow-wrap: anywhere;'
        $css | Should -Not -Match 'white-space: nowrap'
        $css | Should -Not -Match '(^|[ ;{])width:'
    }
    It 'dims a zero tile and leaves a non-zero tile alone' {
        $html.Contains('<div class="tile emer zero"><div class="n">0</div>') | Should -BeTrue
        $html.Contains('<div class="tile crit"><div class="n">6</div>') | Should -BeTrue
        $html | Should -Match '\.tile\.zero \.n \{ color: var\(--muted\); font-weight: 400; \}'
    }
    It 'names itself in the footer, with the files beside it' {
        $html | Should -Match '<footer>Files beside triage_dashboard\.html: triage_rules\.csv, triage_hosts\.csv, run_manifest\.csv, _runs, and one folder per collection\.</footer>'
    }
    It 'shows a note once when it is stored as both a warning and an error' {
        $o = New-TestDirectory (Join-TestPath $TestDrive 'dup')
        $m = Join-TestPath $o 'run_manifest.csv'
        Initialize-RunManifest -Path $m | Out-Null
        $msg = "DUP.zip can't be extracted by this tool (unsupported compression or encryption). Extract it yourself, put the extracted folder in InputRoot, and rerun."
        Set-RunManifestEntry -Path $m -Collection 'DUP' -Source 'DUP.zip' -RunId 'r' -InputType Zip -Status Failed -WarningMessage @($msg, 'Second note') -ErrorMessage @($msg)
        Invoke-Rollup -OutputRoot $o -WarningAction SilentlyContinue | Out-Null
        $d = [System.IO.File]::ReadAllText((Join-TestPath $o 'triage_dashboard.html'))
        $encoded = ConvertTo-HtmlText -Text $msg
        ([regex]::Matches($d, [regex]::Escape($encoded))).Count | Should -Be 1
        $d.Contains("<span class=`"err`">$encoded</span><br>Second note</td>") | Should -BeTrue
    }
}

Describe 'Provenance' {
    It 'notes mixed severity floors' {
        $html | Should -Match 'Rows come from runs with different severity floors \(exact critical, min high, min medium\)'
    }
    It 'finds an old-style run-meta by RunId and lists a missing one' {
        $html | Should -Match '<td>run3</td><td>2026-10-10T03:00:00Z</td><td>min medium</td><td>verbose</td>'
        $html | Should -Match '<td>ghost</td><td colspan="5" class="dim">run-meta not found in _runs</td>'
    }
    It 'counts rows per run' {
        $html | Should -Match '<td>run1</td>[^\n]*<td class="n">5</td></tr>'
        $html | Should -Match '<td>run2</td>[^\n]*<td class="n">3</td></tr>'
    }
}

Describe 'Host chips for many computers' {
    BeforeAll {
        $o = New-TestDirectory (Join-TestPath $TestDrive 'chips')
        $m = Join-TestPath $o 'run_manifest.csv'
        Initialize-RunManifest -Path $m | Out-Null
        $rows = @($TimelineHeader)
        foreach ($n in @('WS01', 'WS02', 'WS03', 'WS04', 'WS05')) { $rows += @(New-TimelineRow $n 'high' 'RuleX') }
        Set-RunManifestEntry -Path $m -Collection 'MANY' -Source 'MANY' -RunId 'c1' -InputType Loose -Status Completed -HostName '[multiple]'
        Write-TestText -Path (Get-CollectionOutputPath -OutputRoot $o -Collection 'MANY').Csv -Line ([string[]]$rows) | Out-Null
        Set-RunManifestEntry -Path $m -Collection 'UNREAD' -Source 'UNREAD' -RunId 'c1' -InputType Loose -Status Pending -HostName '[multiple]'
        Invoke-Rollup -OutputRoot $o -WarningAction SilentlyContinue | Out-Null
        $script:ch = [System.IO.File]::ReadAllText((Join-TestPath $o 'triage_dashboard.html'))
    }

    It 'shows up to three names as chips, then +N, then the tag' {
        $ch.Contains('<td><span class="chip">WS01</span> <span class="chip">WS02</span> <span class="chip">WS03</span> <span class="dim">+2</span><span class="tag">multiple</span></td>') | Should -BeTrue
    }
    It 'shows [multiple] as a chip when the names cannot be read' {
        $ch.Contains('<td><span class="chip">[multiple]</span><span class="tag">multiple</span></td><td>UNREAD</td>') | Should -BeTrue
    }
}

Describe 'Informational in the dashboard' {
    BeforeAll {
        $o = New-TestDirectory (Join-TestPath $TestDrive 'info')
        $m = Join-TestPath $o 'run_manifest.csv'
        Initialize-RunManifest -Path $m | Out-Null
        Set-RunManifestEntry -Path $m -Collection 'INFO' -Source 'INFO' -RunId 'i1' -InputType Loose -Status Completed -HostName 'IN01'
        Write-TestText -Path (Get-CollectionOutputPath -OutputRoot $o -Collection 'INFO').Csv -Line @(@($TimelineHeader) + @(New-TimelineRowSet 'IN01' 'info' 'Logon' 2)) | Out-Null
        Invoke-Rollup -OutputRoot $o -WarningAction SilentlyContinue | Out-Null
        $script:ih = [System.IO.File]::ReadAllText((Join-TestPath $o 'triage_dashboard.html'))
    }

    It 'has an informational tile with its count, coloured, after the low tile' {
        $ih | Should -Match '<div class="tile info"><div class="n">2</div><div class="l">informational detections</div></div>'
        $ih.IndexOf('tile low') | Should -BeLessThan $ih.IndexOf('tile info')
        $ih | Should -Match '\.tile\.info \.n \{ color: var\(--info\); \}'
    }
}

Describe 'Emergency in the dashboard' {
    BeforeAll {
        $o = New-TestDirectory (Join-TestPath $TestDrive 'emer')
        $m = Join-TestPath $o 'run_manifest.csv'
        Initialize-RunManifest -Path $m | Out-Null
        $spec = @(
            @{ C = 'EMERONLY'; Csv = (@($TimelineHeader) + @(New-TimelineRow 'EM01' 'emer' 'Ransom note dropped')) }
            @{ C = 'CRITMANY'; Csv = (@($TimelineHeader) + @(New-TimelineRowSet 'CR01' 'crit' 'Mimikatz use' 9) + @(New-TimelineRowSet 'CR01' 'high' 'PsExec' 3)) }
            @{ C = 'BOTH'; Csv = (@($TimelineHeader) + @(New-TimelineRowSet 'BO01' 'emergency' 'Ransom note dropped' 2) + @(New-TimelineRowSet 'BO01' 'crit' 'Mimikatz use' 5)) }
        )
        foreach ($e in $spec) {
            $hostName = ($e.Csv[1] -split '","')[1]
            Set-RunManifestEntry -Path $m -Collection $e.C -Source $e.C -RunId 'e1' -InputType Loose -Status Completed -HostName $hostName
            Write-TestText -Path (Get-CollectionOutputPath -OutputRoot $o -Collection $e.C).Csv -Line ([string[]]$e.Csv) | Out-Null
        }
        Invoke-Rollup -OutputRoot $o -WarningAction SilentlyContinue | Out-Null
        $script:eh = [System.IO.File]::ReadAllText((Join-TestPath $o 'triage_dashboard.html'))
    }

    It 'has an emergency tile with its count' {
        $eh | Should -Match '<div class="tile emer"><div class="n">3</div><div class="l">emergency detections</div></div>'
    }
    It 'dims the informational tile when there are none' {
        $eh | Should -Match '<div class="tile info zero"><div class="n">0</div><div class="l">informational detections</div></div>'
    }
    It 'puts the emergency tile before critical' {
        $eh.IndexOf('tile emer') | Should -BeLessThan $eh.IndexOf('tile crit')
    }
    It 'lists emergency rules first in the summary' {
        $panel = [regex]::Match($eh, '(?s)Top emergency, critical and high rules</h3>(.*?)</div>').Groups[1].Value
        $panel.IndexOf('Ransom note dropped') | Should -BeGreaterOrEqual 0
        $panel.IndexOf('Ransom note dropped') | Should -BeLessThan $panel.IndexOf('Mimikatz use')
        $panel | Should -Match 'badge lv-emergency'
    }
    It 'gives the emergency badge its own colour in both themes' {
        $eh | Should -Match '\.lv-emergency \{ color: var\(--emer\); background: var\(--emer-bg\); \}'
        [regex]::Matches($eh, '--emer: #').Count | Should -Be 2
        $eh | Should -Not -Match 'lv-other">emergency'
    }
    It 'has an Emer column before Crit in the host table' {
        $eh | Should -Match '<th class="n">Emer</th><th class="n">Crit</th>'
        $eh | Should -Match '<td><span class="chip">BO01</span></td><td>BOTH</td><td><span class="badge st-Completed">Completed</span></td><td class="n">2</td><td class="n">5</td>'
    }
}
