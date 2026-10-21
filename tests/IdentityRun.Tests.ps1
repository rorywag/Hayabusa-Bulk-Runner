# Host identity as part of a run: read during a normal batch only when
# RECmdPath is set, and on its own with -IdentityOnly. RECmd is mocked in
# the batch tests, and the hives are fakes that only start like one.

BeforeDiscovery {
    $script:onWindows = ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers/TestHelpers.ps1')
    . (Join-Path $PSScriptRoot 'Helpers/IdentityHelpers.ps1')
    $script:hb = New-FakeHayabusa -Directory (Join-TestPath $TestDrive 'tool')
    $script:resolved = Get-TestRunSetting -HayabusaPath $hb
    $script:csv = @($TimelineHeader) + @(New-TimelineRow 'WS01' 'crit' 'RuleA')
    $script:limits = Resolve-ZipLimit -Config $null

    function script:New-HiveByte {
        # Random after the signature, so the ZIP isn't refused as a zip bomb.
        $b = New-TestByteArray -Count 8192 -Random
        [System.Text.Encoding]::ASCII.GetBytes('regf').CopyTo($b, 0)
        return , $b
    }

    function script:New-RunRoot([string]$Name) {
        $root = New-TestDirectory (Join-TestPath $TestDrive $Name)
        $o = New-TestDirectory (Join-TestPath $root 'out')
        $m = Join-TestPath $o 'run_manifest.csv'
        Initialize-RunManifest -Path $m | Out-Null
        [pscustomobject]@{ In = (New-TestDirectory (Join-TestPath $root 'in')); Out = $o; Manifest = $m }
    }

    function script:New-HiveHost([string]$InputRoot, [string]$Name) {
        $d = New-FakeHost -InputRoot $InputRoot -Name $Name -Files @{ 'r.csv' = $csv }
        New-HiveCollection -Root $d | Out-Null
        return $d
    }

    function script:Get-IdentityStatus([string]$Out, [string]$Collection) {
        $r = Read-HostIdentity -OutputRoot $Out -Collection $Collection
        if ($null -eq $r.Identity) { return $null }
        return $r.Identity.Status
    }
}

Describe 'A normal batch without RECmdPath' {
    BeforeAll {
        Mock Assert-HayabusaHost { }
        Mock Invoke-RECmd { throw 'RECmd should not run' }
        $script:R0 = New-RunRoot 'plain'
        New-HiveHost -InputRoot $R0.In -Name 'H1' | Out-Null
        $cols = @(Get-InputCollection -InputRoot $R0.In -WarningAction SilentlyContinue)
        $iv = $null
        $script:sum0 = Invoke-CollectionBatch -Collections $cols -ManifestPath $R0.Manifest -OutputRoot $R0.Out -HayabusaPath $hb -Resolved $resolved -RunId 'r0' -InformationVariable iv -InformationAction SilentlyContinue
        $script:info0 = @($iv | ForEach-Object { "$_" })
    }

    It 'runs Hayabusa as before and reads no host identity' {
        $sum0.Completed | Should -Be 1
        (Get-RunManifest -Path $R0.Manifest)['H1'].Host | Should -BeExactly 'WS01'
        Test-Path -LiteralPath (Get-HostIdentityPath -OutputRoot $R0.Out -Collection 'H1') | Should -BeFalse
        Should -Invoke Invoke-RECmd -Times 0 -Exactly -Scope Describe
        $info0 | Should -Contain '[1/1] H1 ... Completed, 1 detection'
    }
}

Describe 'A normal batch with RECmdPath' {
    BeforeAll {
        Mock Assert-HayabusaHost { }
        Mock Invoke-RECmd {
            Copy-FixtureOutput -Argument $Argument
            [pscustomobject]@{ ExitCode = 0; Output = @("RECmd version $TestedRECmdVersion") }
        }
        Mock Clear-StaleExtract { }
        $script:R1 = New-RunRoot 'wired'
        New-HiveHost -InputRoot $R1.In -Name 'H1' | Out-Null
        New-FakeHost -InputRoot $R1.In -Name 'H2' -Files @{ 'r.csv' = $csv } | Out-Null
        $hive = New-HiveByte
        New-TestZip -Path (Join-TestPath $R1.In 'H3.zip') -Entries ([ordered]@{
                'fake.behavior'                   = "EXIT=0`nCSV=r.csv"
                'r.csv'                           = ($csv -join "`n")
                'C/Windows/System32/config/SYSTEM'   = $hive
                'C/Windows/System32/config/SOFTWARE' = $hive
                'C/Windows/System32/config/SAM'      = $hive
                'C/Windows/System32/winevt/Logs/Security.evtx' = 'evtx'
            }) | Out-Null
        $cols = @(Get-InputCollection -InputRoot $R1.In -WarningAction SilentlyContinue)
        $iv = $null
        $script:sum1 = Invoke-CollectionBatch -Collections $cols -ManifestPath $R1.Manifest -OutputRoot $R1.Out -HayabusaPath $hb -Resolved $resolved -RunId 'r1' -RECmdPath $fakeRECmd -InformationVariable iv -InformationAction SilentlyContinue
        $script:info1 = @($iv | ForEach-Object { "$_" })
        $script:rows1 = Get-RunManifest -Path $R1.Manifest
    }

    It 'still runs Hayabusa for every collection, with the same manifest rows' {
        $sum1.Completed | Should -Be 3
        foreach ($c in 'H1', 'H2', 'H3') {
            $rows1[$c].Status | Should -BeExactly 'Completed'
            $rows1[$c].Host | Should -BeExactly 'WS01'
            $rows1[$c].Warning | Should -Not -Match 'identity'
        }
    }

    It 'reads and saves each collection''s identity while it is processed' {
        Get-IdentityStatus $R1.Out 'H1' | Should -BeExactly 'Complete'
        (Read-HostIdentity -OutputRoot $R1.Out -Collection 'H1').Identity.Hostname | Should -BeExactly 'FAKE-HOST-01'
        Get-IdentityStatus $R1.Out 'H2' | Should -BeExactly 'NoRegistryHives'
        Should -Invoke Invoke-RECmd -Times 6 -Exactly -Scope Describe
    }

    It 'reads a ZIP from the one extract Hayabusa used, and leaves nothing behind' {
        Get-IdentityStatus $R1.Out 'H3' | Should -BeExactly 'Complete'
        (Read-HostIdentity -OutputRoot $R1.Out -Collection 'H3').Identity.Source.ConfigDirectory | Should -Be (Join-TestPath 'C' 'Windows' 'System32' 'config')
        Should -Invoke Clear-StaleExtract -Times 1 -Exactly -Scope Describe
        @(Get-ChildItem -LiteralPath (Join-TestPath $R1.Out '_work') -Force -ErrorAction SilentlyContinue).Count | Should -Be 0
    }

    It 'ends each progress line with the identity status' {
        $info1 | Should -Contain '[1/3] H1 ... Completed, 1 detection, identity Complete'
        $info1 | Should -Contain '[2/3] H2 ... Completed, 1 detection, identity NoRegistryHives'
    }

    It 'keeps the triage result when reading identity fails' {
        Mock Get-HostIdentity { throw 'disk went away' }
        $R = New-RunRoot 'wired-fail'
        New-HiveHost -InputRoot $R.In -Name 'H1' | Out-Null
        $cols = @(Get-InputCollection -InputRoot $R.In -WarningAction SilentlyContinue)
        $s = Invoke-CollectionBatch -Collections $cols -ManifestPath $R.Manifest -OutputRoot $R.Out -HayabusaPath $hb -Resolved $resolved -RunId 'rf' -RECmdPath $fakeRECmd -InformationAction SilentlyContinue
        $s.Completed | Should -Be 1
        $row = (Get-RunManifest -Path $R.Manifest)['H1']
        $row.Status | Should -BeExactly 'Completed'
        $row.Error | Should -BeNullOrEmpty
        $id = (Read-HostIdentity -OutputRoot $R.Out -Collection 'H1').Identity
        $id.Status | Should -BeExactly 'Failed'
        @($id.Notes) | Should -Contain 'Host identity could not be read: disk went away'
    }
}

Describe 'The identity-only batch' {
    BeforeAll {
        Mock Assert-RECmdHost { }
        Mock Invoke-RECmd {
            Copy-FixtureOutput -Argument $Argument
            [pscustomobject]@{ ExitCode = 0; Output = @("RECmd version $TestedRECmdVersion") }
        }
        $script:RI = New-RunRoot 'idonly'
        Remove-Item -LiteralPath $RI.Manifest
        New-HiveHost -InputRoot $RI.In -Name 'H1' | Out-Null
        New-FakeHost -InputRoot $RI.In -Name 'H2' | Out-Null
        $zp = New-TestZip -Path (Join-TestPath $RI.In 'H3.zip') -Entries ([ordered]@{ 'C/Windows/System32/winevt/Logs/a.evtx' = 'x'; 'b.txt' = 'y' })
        Edit-ZipHeader -Path $zp -Method 9
        $hive = New-HiveByte
        New-TestZip -Path (Join-TestPath $RI.In 'H4.zip') -Entries ([ordered]@{
                'C/Windows/System32/config/SYSTEM'   = $hive
                'C/Windows/System32/config/SOFTWARE' = $hive
                'C/Windows/System32/config/SAM'      = $hive
            }) | Out-Null
        $script:colsI = @(Get-InputCollection -InputRoot $RI.In -WarningAction SilentlyContinue)
        $iv = $null
        $w = $null
        $script:sumI = Invoke-IdentityBatch -Collections $colsI -OutputRoot $RI.Out -RECmdPath $fakeRECmd -Limits $limits -InformationVariable iv -InformationAction SilentlyContinue -WarningVariable w -WarningAction SilentlyContinue
        $script:infoI = @($iv | ForEach-Object { "$_" })
        $script:warnI = @($w | ForEach-Object { "$_" })
    }

    It 'reads every collection''s identity, extracting a ZIP once and removing the extract' {
        $sumI.Processed | Should -Be 4
        $sumI.Complete | Should -Be 2
        $sumI.NoRegistryHives | Should -Be 1
        $sumI.Failed | Should -Be 1
        Get-IdentityStatus $RI.Out 'H1' | Should -BeExactly 'Complete'
        Get-IdentityStatus $RI.Out 'H2' | Should -BeExactly 'NoRegistryHives'
        Get-IdentityStatus $RI.Out 'H4' | Should -BeExactly 'Complete'
        @(Get-ChildItem -LiteralPath (Join-TestPath $RI.Out '_work') -Force -ErrorAction SilentlyContinue).Count | Should -Be 0
        $infoI | Should -Contain '[1/4] H1 ... identity Complete, FAKE-HOST-01'
    }

    It 'saves a ZIP it can''t extract as Failed with the guidance, without warning twice' {
        $id = (Read-HostIdentity -OutputRoot $RI.Out -Collection 'H3').Identity
        $id.Status | Should -BeExactly 'Failed'
        @($id.Notes)[0] | Should -BeLike "H3.zip can't be extracted by this tool*"
        $infoI | Should -Contain '[3/4] H3 ... identity Failed: ZIP not extracted, see the warning at the start'
        @($warnI | Where-Object { $_ -like '*H3*' }).Count | Should -Be 0
    }

    It 'never runs Hayabusa, and writes no manifest, run-meta or timeline' {
        Test-Path -LiteralPath (Join-TestPath $RI.Out 'run_manifest.csv') | Should -BeFalse
        Test-Path -LiteralPath (Join-TestPath $RI.Out '_runs') | Should -BeFalse
        @(Get-ChildItem -LiteralPath $RI.Out -Recurse -Filter '*_timeline.csv').Count | Should -Be 0
        @(Get-ChildItem -LiteralPath $RI.Out -Recurse -Filter '*_hayabusa.log').Count | Should -Be 0
    }

    It 'skips a Complete or NoRegistryHives identity on a rerun, unless -Force is given' {
        $iv = $null
        $again = Invoke-IdentityBatch -Collections $colsI -OutputRoot $RI.Out -RECmdPath $fakeRECmd -Limits $limits -InformationVariable iv -InformationAction SilentlyContinue -WarningAction SilentlyContinue
        $again.Skipped | Should -Be 3
        $again.Processed | Should -Be 1
        @($iv | ForEach-Object { "$_" }) | Should -Contain '[2/4] H2 ... skipped, identity already NoRegistryHives'
        $forced = Invoke-IdentityBatch -Collections $colsI -OutputRoot $RI.Out -RECmdPath $fakeRECmd -Limits $limits -Force -InformationAction SilentlyContinue -WarningAction SilentlyContinue
        $forced.Processed | Should -Be 4
    }

    It 'puts a changed image hash first in the identity''s notes and warns' {
        $R = New-RunRoot 'idonly-hash'
        $d = New-HiveHost -InputRoot $R.In -Name 'IMG'
        Mock Resolve-CollectionInput {
            $ImageHashRecord.Add([pscustomobject]@{ ImagePath = 'D:\x\IMG.vhdx'; Before = 'AAAA'; After = 'BBBB'; Match = $false })
            [pscustomobject]@{ Path = $d; Teardown = @() }
        }
        Mock Invoke-CollectionCleanup { }
        $cols = @(Get-InputCollection -InputRoot $R.In -WarningAction SilentlyContinue)
        $w = $null
        Invoke-IdentityBatch -Collections $cols -OutputRoot $R.Out -RECmdPath $fakeRECmd -Limits $limits -InformationAction SilentlyContinue -WarningVariable w -WarningAction SilentlyContinue | Out-Null
        $id = (Read-HostIdentity -OutputRoot $R.Out -Collection 'IMG').Identity
        @($id.Notes)[0] | Should -BeLike "$EvidenceChangedPrefix*AAAA*BBBB*"
        $id.Hostname | Should -BeExactly 'FAKE-HOST-01'
        @($w | Where-Object { "$_" -like "*IMG ... identity Complete, FAKE-HOST-01: $EvidenceChangedPrefix*" }).Count | Should -Be 1
    }
}

Describe 'The entry script and host identity' {
    BeforeAll {
        $script:in = New-TestDirectory (Join-TestPath $TestDrive 'main-in')
        New-FakeHost -InputRoot $in -Name 'HOST01' -Files @{ 'r.csv' = $csv } | Out-Null
        New-FakeHost -InputRoot $in -Name 'HOST02' -Files @{ 'r.csv' = $csv } | Out-Null
        $cfgDir = New-TestDirectory (Join-TestPath $TestDrive 'main-cfg')
        $script:cfgWith = Write-TestText -Path (Join-TestPath $cfgDir 'with.psd1') -Line @("@{ RECmdPath = '$fakeRECmd' }")
        $script:cfgWithout = Write-TestText -Path (Join-TestPath $cfgDir 'without.psd1') -Line @("@{ MinLevel = 'high' }")
        # Off Windows, RECmd is refused before a hive is looked for. On
        # Windows these fake hosts have no hives, so RECmd isn't run.
        $script:expected = 'Failed'
        if ($TestOnWindows) { $script:expected = 'NoRegistryHives' }
    }

    It 'lists -IdentityOnly in the quick help' {
        @(& $MainScript -Help | Where-Object { $_ -like '  -IdentityOnly *' }).Count | Should -Be 1
    }

    It 'reads no identity and writes no identity dashboard when RECmdPath is not set' {
        $o = Join-TestPath $TestDrive 'main-noid'
        $r = & $MainScript -InputRoot $in -OutputRoot $o -HayabusaPath $hb -ConfigPath $cfgWithout -WarningAction SilentlyContinue -InformationAction SilentlyContinue
        $r.Identity | Should -BeNullOrEmpty
        Test-Path -LiteralPath (Join-TestPath $o 'identity_dashboard.html') | Should -BeFalse
        @(Get-ChildItem -LiteralPath $o -Recurse -Filter '*_identity.json').Count | Should -Be 0
        Test-Path -LiteralPath (Join-TestPath $o 'triage_dashboard.html') | Should -BeTrue
    }

    It 'writes the identity dashboard beside the triage dashboard when RECmdPath is set, leaving run-meta as it was' {
        $o = Join-TestPath $TestDrive 'main-id'
        $iv = $null
        $r = & $MainScript -InputRoot $in -OutputRoot $o -HayabusaPath $hb -ConfigPath $cfgWith -WarningAction SilentlyContinue -InformationVariable iv -InformationAction SilentlyContinue
        $info = @($iv | ForEach-Object { "$_" })
        $r.Identity.Error | Should -BeNullOrEmpty
        $r.Identity.Dashboard | Should -Be (Join-TestPath $o 'identity_dashboard.html')
        Test-Path -LiteralPath (Join-TestPath $o 'triage_dashboard.html') | Should -BeTrue
        $info[-1] | Should -BeExactly 'Open identity_dashboard.html there for host identity.'
        @($info | Where-Object { $_ -like 'Host identity will also be read*' }).Count | Should -Be 1
        $raw = Get-Content -LiteralPath $r.RunMetaPath -Raw
        ($raw | ConvertFrom-Json).SchemaVersion | Should -Be 7
        $raw | Should -Not -Match 'identity|RECmd'
        $html = [System.IO.File]::ReadAllText($r.Identity.Dashboard)
        $html | Should -Match '<td>HOST01</td>'
        $html | Should -Match '<td>HOST02</td>'
        if ($TestOnWindows) {
            Get-IdentityStatus $o 'HOST01' | Should -BeExactly 'NoRegistryHives'
        }
        else {
            # Hayabusa can't run here, so the collections are never resolved.
            Test-Path -LiteralPath (Get-HostIdentityPath -OutputRoot $o -Collection 'HOST01') | Should -BeFalse
            $html | Should -Match 'Not read'
        }
    }

    It 'refuses -IdentityOnly without RECmdPath, before anything is written' {
        $o = Join-TestPath $TestDrive 'main-idonly-none'
        $want = '-IdentityOnly needs RECmdPath, the full path of RECmd.exe, set in the engagement config given with -ConfigPath.'
        Get-ThrownMessage { & $MainScript -InputRoot $in -OutputRoot $o -IdentityOnly } | Should -BeExactly $want
        Get-ThrownMessage { & $MainScript -InputRoot $in -OutputRoot $o -ConfigPath $cfgWithout -IdentityOnly } | Should -BeExactly $want
        Test-Path -LiteralPath $o | Should -BeFalse
    }

    It 'does not take -HayabusaPath with -IdentityOnly' {
        Get-ThrownMessage { & $MainScript -InputRoot $in -OutputRoot (Join-TestPath $TestDrive 'main-both') -HayabusaPath $hb -ConfigPath $cfgWith -IdentityOnly } | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath (Join-TestPath $TestDrive 'main-both') | Should -BeFalse
    }

    It 'reads identity only, skipping Hayabusa and the triage rollup, and still writes the identity dashboard' {
        $o = Join-TestPath $TestDrive 'main-idonly'
        $iv = $null
        $r = & $MainScript -InputRoot $in -OutputRoot $o -ConfigPath $cfgWith -IdentityOnly -WarningAction SilentlyContinue -InformationVariable iv -InformationAction SilentlyContinue
        $info = @($iv | ForEach-Object { "$_" })
        $r.Summary.Processed | Should -Be 2
        $r.Identity.Dashboard | Should -Be (Join-TestPath $o 'identity_dashboard.html')
        Test-Path -LiteralPath $r.Identity.Dashboard | Should -BeTrue
        foreach ($f in 'run_manifest.csv', 'triage_dashboard.html', 'triage_hosts.csv', 'triage_rules.csv', '_runs') {
            Test-Path -LiteralPath (Join-TestPath $o $f) | Should -BeFalse -Because "$f is from a Hayabusa run"
        }
        @(Get-ChildItem -LiteralPath $o -Recurse -Filter '*_timeline.csv').Count | Should -Be 0
        Get-IdentityStatus $o 'HOST01' | Should -BeExactly $expected
        $info[0] | Should -BeExactly "Reading host identity only, with RECmd at $fakeRECmd. Hayabusa is not run."
        $info[-1] | Should -BeExactly "Output is in $o. Open identity_dashboard.html there for host identity."
    }
}
