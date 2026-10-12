BeforeDiscovery {
    $script:onWindows = ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers/TestHelpers.ps1')
    $script:hb = New-FakeHayabusa -Directory (Join-TestPath $TestDrive 'tool')
    $script:rules = Join-TestPath $TestDrive 'tool' 'rules'
    $script:cfgDir = New-TestDirectory (Join-TestPath $TestDrive 'cfg')
    New-TestDirectory (Join-TestPath $cfgDir 'myrules') | Out-Null
    function script:New-Config([string]$Name, [string]$Body) { Write-TestText -Path (Join-TestPath $cfgDir $Name) -Line @($Body) }
    function script:Read-RunMeta([string]$Path) { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
    function script:New-Input([string]$Name) {
        $in = New-TestDirectory (Join-TestPath $TestDrive $Name)
        New-FakeHost -InputRoot $in -Name 'HOST01' -Files @{ 'r.csv' = (@($TimelineHeader) + @(New-TimelineRowSet 'WS01' 'crit' 'RuleA' 2) + @(New-TimelineRow 'WS01' 'high' 'RuleB')) } | Out-Null
        New-FakeHost -InputRoot $in -Name 'HOST 02' -Files @{ 'r.csv' = (@($TimelineHeader) + @(New-TimelineRow 'WS02' 'high' 'RuleB')) } | Out-Null
        $in
    }
    $script:in = New-Input 'in'
}

Describe 'Checks before anything is written' {
    It 'refuses an OutputRoot inside InputRoot' {
        Get-ThrownMessage { & $MainScript -InputRoot $in -OutputRoot (Join-TestPath $in 'results') -HayabusaPath $hb } | Should -BeLike '*must not be inside InputRoot*'
        Test-Path -LiteralPath (Join-TestPath $in 'results') | Should -BeFalse
    }
    It 'stops on a missing rules folder and writes nothing' {
        $tool2 = New-TestDirectory (Join-TestPath $TestDrive 'tool2')
        $hb2 = Write-TestText -Path (Join-TestPath $tool2 'hayabusa.exe') -Line @('x')
        $o = Join-TestPath $TestDrive 'out-norules'
        Get-ThrownMessage { & $MainScript -InputRoot $in -OutputRoot $o -HayabusaPath $hb2 } | Should -BeLike '*RulesPath not found*update-rules*'
        Test-Path -LiteralPath $o | Should -BeFalse
    }
    It 'stops on reserved collection names and writes nothing' {
        $inR = New-TestDirectory (Join-TestPath $TestDrive 'in-reserved')
        foreach ($n in '_runs', 'Triage_Dashboard.HTML', 'fine') { New-TestDirectory (Join-TestPath $inR $n) | Out-Null }
        $o = Join-TestPath $TestDrive 'out-reserved'
        Get-ThrownMessage { & $MainScript -InputRoot $inR -OutputRoot $o -HayabusaPath $hb } | Should -BeLike '*2 InputRoot entr(ies)*_runs -> _runs*Triage_Dashboard.HTML -> Triage_Dashboard.HTML*'
        Test-Path -LiteralPath $o | Should -BeFalse
    }
    It 'stops on a collection name collision and writes nothing' {
        $inC = New-TestDirectory (Join-TestPath $TestDrive 'in-collide')
        New-TestDirectory (Join-TestPath $inC 'HOST01') | Out-Null
        New-TestZip -Path (Join-TestPath $inC 'host01.zip') -Entries ([ordered]@{ 'a.evtx' = (New-TestByteArray 10 -Random) }) | Out-Null
        $o = Join-TestPath $TestDrive 'out-collide'
        Get-ThrownMessage { & $MainScript -InputRoot $inC -OutputRoot $o -HayabusaPath $hb } | Should -BeLike '*used by more than one*'
        Test-Path -LiteralPath $o | Should -BeFalse
    }
    It 'stops on a bad config and never runs code from it' {
        $marker = Join-TestPath $TestDrive 'pwned.txt'
        $o = Join-TestPath $TestDrive 'out-badcfg'
        Get-ThrownMessage { & $MainScript -InputRoot $in -OutputRoot $o -HayabusaPath $hb -ConfigPath (New-Config 'both.psd1' "@{ MinLevel='high'; ExactLevel='low' }") } | Should -BeLike '*both MinLevel and ExactLevel*'
        Get-ThrownMessage { & $MainScript -InputRoot $in -OutputRoot $o -HayabusaPath $hb -ConfigPath (New-Config 'code.psd1' "@{ MinLevel = `$(Set-Content '$marker' 'x'; 'high') }") } | Should -BeLike '*could not be read as data*'
        Get-ThrownMessage { & $MainScript -InputRoot $in -OutputRoot $o -HayabusaPath $hb -ConfigPath (New-Config 'lim.psd1' '@{ ZipMaxRatio = 0.5 }') } | Should -BeLike '*is not valid. Use a number*'
        Test-Path -LiteralPath $marker | Should -BeFalse
        Test-Path -LiteralPath $o | Should -BeFalse
    }
    It 'stops on disk images that cannot be mounted here and writes nothing' {
        if ($TestOnWindows -and (Test-TestElevated)) {
            Set-ItResult -Skipped -Because 'this session is elevated on Windows, so the images would be mounted'
            return
        }
        $inV = New-TestDirectory (Join-TestPath $TestDrive 'in-vhdx')
        Write-TestText -Path (Join-TestPath $inV 'HOST02.VHDX') -Line @('x') | Out-Null
        New-TestZip -Path (Join-TestPath $inV 'H1.zip') -Entries ([ordered]@{ 'disk.vhdx' = (New-TestByteArray 10) }) | Out-Null
        $o = Join-TestPath $TestDrive 'out-vhdx'
        $m = Get-ThrownMessage { & $MainScript -InputRoot $inV -OutputRoot $o -HayabusaPath $hb }
        $m | Should -BeLike '*HOST02.VHDX*'
        $m | Should -BeLike '*H1.zip (contains disk.vhdx)*'
        if ($TestOnWindows) { $m | Should -BeLike '*elevated session*' } else { $m | Should -BeLike '*requires Windows*' }
        Test-Path -LiteralPath $o | Should -BeFalse
    }
    It 'accepts emergency for -MinLevel' {
        $p = (Get-Command $MainScript).Parameters['MinLevel']
        ($p.Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }).ValidValues | Should -Contain 'emergency'
    }
}

Describe 'A run' {
    BeforeAll {
        $script:out = Join-TestPath $TestDrive 'out'
        $iv = $null
        $w = $null
        $script:r1 = & $MainScript -InputRoot $in -OutputRoot ($out + '/') -HayabusaPath $hb -WarningVariable w -WarningAction SilentlyContinue -InformationVariable iv -InformationAction SilentlyContinue
        $script:info1 = @($iv | ForEach-Object { "$_" })
        $script:warn1 = @($w | ForEach-Object { "$_" })
        $script:raw1 = Get-Content -LiteralPath $r1.RunMetaPath -Raw
        $script:m1 = $raw1 | ConvertFrom-Json
        $script:rows1 = @(Import-Csv -LiteralPath $r1.ManifestPath)
    }

    It 'creates OutputRoot, the manifest and run-meta named by time and RunId' {
        Test-Path -LiteralPath $r1.ManifestPath | Should -BeTrue
        $r1.RunMetaPath | Should -Match ('_runs[\\/]run_meta_\d{8}T\d{6}Z_' + $r1.RunId + '\.json$')
    }
    It 'writes the manifest header with RunId and Emergency, and no BOM' {
        Get-Content -LiteralPath $r1.ManifestPath -TotalCount 1 | Should -BeExactly '"Host","Collection","Source","RunId","InputType","Status","Detections","Emergency","Critical","High","Warning","Error","DurationSec","Timestamp"'
        Test-Utf8Bom -Path $r1.ManifestPath | Should -BeFalse
    }
    It 'records defaults and provenance in run-meta' {
        $m1.RunId | Should -Be $r1.RunId
        $m1.SchemaVersion | Should -Be 6
        $m1.Tool.Version | Should -Be '0.6.1'
        $m1.Selection.MinLevel | Should -Be 'high'
        $m1.Selection.ExactLevel | Should -BeNullOrEmpty
        $m1.SettingSource.MinLevel | Should -Be 'Default'
        $m1.Selection.Profile | Should -Be 'standard'
        $m1.OutputUtc | Should -BeTrue
        $m1.Selection.RulesPath | Should -Be $rules
        $m1.Config | Should -BeNullOrEmpty
        $m1.Options.Threads | Should -BeNullOrEmpty
        $m1.OutputRoot | Should -Be $out
        $m1.Limits.ZipMaxUncompressedGB | Should -Be 100
        $m1.Limits.ZipMaxRatio | Should -Be 250
        $m1.SettingSource.ZipMaxRatio | Should -Be 'Default'
        $m1.Hayabusa.RuleFileCount | Should -Be 1
        $raw1 | Should -Match '"StartedUtc":\s*"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ"'
        $raw1 | Should -Match '"CompletedUtc":\s*"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ"'
        $raw1 | Should -Match '"IncludeTags":\s*\[\s*\]'
    }
    It 'records both collections, keeping the raw Source' {
        ($rows1.Collection -join ',') | Should -Be 'HOST_02,HOST01'
        $rows1[0].Source | Should -BeExactly 'HOST 02'
        $m1.Summary.Discovered | Should -Be 2
        @($m1.Collections).Count | Should -Be 2
    }
    It 'builds the rollup and records it in run-meta' {
        Test-Path -LiteralPath (Join-TestPath $out 'triage_dashboard.html') | Should -BeTrue
        Test-Path -LiteralPath (Join-TestPath $out 'index.html') | Should -BeFalse
        Test-Path -LiteralPath (Join-TestPath $out 'triage_hosts.csv') | Should -BeTrue
        $m1.Rollup.HostCount | Should -Be 2
        $m1.Rollup.Dashboard | Should -Be (Join-TestPath $out 'triage_dashboard.html')
        $m1.Rollup.Error | Should -BeNullOrEmpty
    }
    It 'prints one progress line per collection without -Verbose' {
        if ($TestOnWindows) {
            $info1 | Should -Contain '[1/2] HOST_02 ... Completed, 1 detection'
            $info1 | Should -Contain '[2/2] HOST01 ... Completed, 3 detections'
        }
        else {
            # Every collection fails off Windows, so each line is a warning.
            $warn1 | Should -Contain '[1/2] HOST_02 ... Failed: Running Hayabusa requires Windows.'
            $warn1 | Should -Contain '[2/2] HOST01 ... Failed: Running Hayabusa requires Windows.'
        }
    }
    It 'ends with a summary and a pointer to the dashboard' {
        if ($TestOnWindows) {
            $info1 | Should -Contain 'Done: 2 processed, 2 completed, 0 completed with errors, 0 failed, 0 skipped.'
        }
        else {
            $info1 | Should -Contain 'Done: 2 processed, 0 completed, 0 completed with errors, 2 failed, 0 skipped.'
        }
        $info1[-1] | Should -BeExactly "Output is in $out. Open triage_dashboard.html there to start triage."
    }
    It 'writes a separate run-meta on a second run and keeps the manifest' {
        $r = & $MainScript -InputRoot $in -OutputRoot $out -HayabusaPath $hb -Threads 8 -MinLevel critical -WarningAction SilentlyContinue
        $m = Read-RunMeta $r.RunMetaPath
        @(Get-ChildItem -LiteralPath (Join-TestPath $out '_runs')).Count | Should -Be 2
        @(Import-Csv -LiteralPath $r.ManifestPath).Count | Should -Be 2
        $m.Options.Threads | Should -Be 8
        $m.Selection.MinLevel | Should -Be 'critical'
        $m.SettingSource.MinLevel | Should -Be 'CommandLine'
    }
}

Describe 'Settings from a config file' {
    It 'uses ExactLevel, a relative RulesPath and ZIP limits from the config' {
        $c = New-Config 'exact.psd1' "@{ ExactLevel = 'Critical'; RulesPath = 'myrules'; IncludeTags = 'attack.credential_access'; Profile = 'Verbose'; ZipMaxUncompressedGB = 2.5; ZipMaxRatio = 400 }"
        $r = & $MainScript -InputRoot $in -OutputRoot (Join-TestPath $TestDrive 'out-cfg') -HayabusaPath $hb -ConfigPath $c -WarningAction SilentlyContinue
        $m = Read-RunMeta $r.RunMetaPath
        $m.Selection.ExactLevel | Should -Be 'critical'
        $m.Selection.MinLevel | Should -BeNullOrEmpty
        $m.SettingSource.MinLevel | Should -Be 'NotUsed'
        $m.Selection.RulesPath | Should -Be (Join-TestPath $cfgDir 'myrules')
        @($m.Selection.IncludeTags) | Should -Be @('attack.credential_access')
        $m.Selection.Profile | Should -Be 'verbose'
        $m.Config.Sha256 | Should -Be (Get-FileHash -LiteralPath $c -Algorithm SHA256).Hash
        $m.Limits.ZipMaxUncompressedGB | Should -Be 2.5
        $m.Limits.ZipMaxUncompressedBytes | Should -Be ([long](2.5 * 1GB))
        $m.Limits.ZipMaxRatio | Should -Be 400
        $m.SettingSource.ZipMaxRatio | Should -Be 'Config'
    }
    It 'lets the command line MinLevel override the config ExactLevel' {
        $r = & $MainScript -InputRoot $in -OutputRoot (Join-TestPath $TestDrive 'out-cfg2') -HayabusaPath $hb -ConfigPath (Join-TestPath $cfgDir 'exact.psd1') -MinLevel medium -WarningAction SilentlyContinue
        $m = Read-RunMeta $r.RunMetaPath
        $m.Selection.MinLevel | Should -Be 'medium'
        $m.Selection.ExactLevel | Should -BeNullOrEmpty
        $m.SettingSource.ExactLevel | Should -Be 'OverriddenByCommandLine'
    }
}

Describe 'Unreadable ZIPs at startup' {
    BeforeAll {
        $inZ = New-TestDirectory (Join-TestPath $TestDrive 'in-zip')
        New-TestDirectory (Join-TestPath $inZ 'OK') | Out-Null
        $d64 = New-TestZip -Path (Join-TestPath $inZ 'D64.zip') -Entries ([ordered]@{ 'C/Windows/System32/winevt/Logs/x.evtx' = (New-TestByteArray 50 -Random) })
        Edit-ZipHeader -Path $d64 -Method 9
        $img = New-TestZip -Path (Join-TestPath $inZ 'IMG.zip') -Entries ([ordered]@{ 'Container/IMG.vhdx' = (New-TestByteArray 50 -Random) })
        Edit-ZipHeader -Path $img -Method 9
        $w = $null
        $iv = $null
        $script:zr = & $MainScript -InputRoot $inZ -OutputRoot (Join-TestPath $TestDrive 'out-zip') -HayabusaPath $hb -WarningVariable w -WarningAction SilentlyContinue -InformationVariable iv -InformationAction SilentlyContinue
        $script:zw = @($w | ForEach-Object { "$_" })
        $script:zi = @($iv | ForEach-Object { "$_" })
        $script:zrows = Get-RunManifest -Path $zr.ManifestPath
    }

    It 'warns once per zip, in one short line' {
        $sw = @($zw | Where-Object { $_ -like "*can't be extracted*" })
        $sw.Count | Should -Be 2
        $sw | Should -Contain "D64.zip can't be extracted by this tool (unsupported compression or encryption)."
        $sw | Should -Contain "IMG.zip can't be extracted by this tool (unsupported compression or encryption)."
        @($sw | Where-Object { $_ -match "`n" }).Count | Should -Be 0
    }
    It 'gives the advice once, in normal output' {
        @($zi | Where-Object { $_ -like '*extract each one yourself, put the extracted folder in InputRoot, and rerun*' }).Count | Should -Be 1
        $zi | Should -Contain '  IMG.zip holds a disk image: put the extracted IMG.vhdx directly in InputRoot.'
    }
    It 'never shows the entry name or method on the console' {
        @($zw + $zi | Where-Object { $_ -like '*x.evtx*' -or $_ -like '*Deflate64*' }).Count | Should -Be 0
    }
    It 'refers back to the warning on the run line instead of warning again' {
        if (-not $TestOnWindows) {
            Set-ItResult -Skipped -Because 'off Windows the run stops at the Windows check first'
            return
        }
        $zi | Should -Contain '[1/3] D64 ... Failed: ZIP not extracted, see the warning at the start'
        @($zw | Where-Object { $_ -like '*D64*' }).Count | Should -Be 1
    }
    It 'stores the guidance once in the manifest' {
        $guide = "D64.zip can't be extracted by this tool (unsupported compression or encryption). Extract it yourself, put the extracted folder in InputRoot, and rerun."
        $zrows.D64.Status | Should -Be 'Failed'
        if ($TestOnWindows) {
            $zrows.D64.Error | Should -BeExactly $guide
            $zrows.D64.Warning | Should -BeExactly ''
        }
        else {
            $zrows.D64.Error | Should -BeExactly 'Running Hayabusa requires Windows.'
            $zrows.D64.Warning | Should -BeExactly $guide
        }
    }
    It 'never creates a working folder for it' {
        Test-Path -LiteralPath (Join-TestPath $TestDrive 'out-zip' '_work' 'D64') | Should -BeFalse
    }
}

Describe 'A rollup failure' {
    It 'is recorded, warned about, and run-meta still completes' {
        $o = New-TestDirectory (Join-TestPath $TestDrive 'out-rollfail')
        New-TestDirectory (Join-TestPath $o 'triage_dashboard.html') | Out-Null
        $w = $null
        $iv = $null
        $r = & $MainScript -InputRoot $in -OutputRoot $o -HayabusaPath $hb -WarningVariable w -WarningAction SilentlyContinue -InformationVariable iv -InformationAction SilentlyContinue
        $m = Read-RunMeta $r.RunMetaPath
        @($iv | ForEach-Object { "$_" })[-1] | Should -BeExactly "Output is in $o. The dashboard could not be built, see the warning above."
        $m.Rollup.Error | Should -Not -BeNullOrEmpty
        $m.CompletedUtc | Should -Not -BeNullOrEmpty
        $m.Summary.Discovered | Should -Be 2
        @($w | Where-Object { "$_" -like 'Rollup failed:*Invoke-HayabusaRollup.ps1*' }).Count | Should -Be 1
    }
}

Describe 'Off Windows' -Skip:$onWindows {
    It 'records each collection Failed with the reason, and the version error' {
        $r = & $MainScript -InputRoot $in -OutputRoot (Join-TestPath $TestDrive 'out-linux') -HayabusaPath $hb -WarningAction SilentlyContinue
        $rows = @(Import-Csv -LiteralPath $r.ManifestPath)
        @($rows | Where-Object { $_.Status -ne 'Failed' -or $_.Error -ne 'Running Hayabusa requires Windows.' }).Count | Should -Be 0
        $m = Read-RunMeta $r.RunMetaPath
        $m.Summary.Failed | Should -Be 2
        $m.Hayabusa.VersionError | Should -Be 'Running Hayabusa requires Windows.'
        Test-Path -LiteralPath (Join-TestPath $TestDrive 'out-linux' '_work') | Should -BeFalse
    }
}

Describe 'End to end on Windows with the fake Hayabusa' -Skip:(-not $onWindows) {
    BeforeAll {
        $script:eo = Join-TestPath $TestDrive 'out-e2e'
        $script:er = & $MainScript -InputRoot $in -OutputRoot $eo -HayabusaPath $hb -WarningAction SilentlyContinue
        $script:em = Read-RunMeta $er.RunMetaPath
        $script:erows = Get-RunManifest -Path $er.ManifestPath
    }

    It 'completes every collection with counts and Host from Computer' {
        $erows.HOST01.Status | Should -Be 'Completed'
        $erows.HOST01.Critical | Should -Be '2'
        $erows.HOST01.High | Should -Be '1'
        $erows.HOST01.Host | Should -Be 'WS01'
        $erows.HOST_02.Status | Should -Be 'Completed'
        $erows.HOST_02.Host | Should -Be 'WS02'
        $em.Summary.Completed | Should -Be 2
    }
    It 'reads the version from the help banner' {
        $em.Hayabusa.Version | Should -BeExactly 'Hayabusa v4.1.0 - Suzumushi Release'
        $em.Hayabusa.VersionError | Should -BeNullOrEmpty
    }
    It 'writes per-host files and a dashboard that links to them' {
        foreach ($f in 'HOST01_timeline.csv', 'HOST01_report.html', 'HOST01_hayabusa.log') { Test-Path -LiteralPath (Join-TestPath $eo 'HOST01' $f) | Should -BeTrue }
        [System.IO.File]::ReadAllText((Join-TestPath $eo 'triage_dashboard.html')).Contains('<a href="HOST01/HOST01_report.html">Report</a>') | Should -BeTrue
    }
    It 'skips everything on a rerun' {
        $iv = $null
        $r = & $MainScript -InputRoot $in -OutputRoot $eo -HayabusaPath $hb -WarningAction SilentlyContinue -InformationVariable iv -InformationAction SilentlyContinue
        @($iv | ForEach-Object { "$_" }) | Should -Contain '[2/2] HOST01 ... skipped, already Completed'
        $r.Summary.Skipped | Should -Be 2
        $r.Summary.Processed | Should -Be 0
    }
}
