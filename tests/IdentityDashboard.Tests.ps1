# The host identity dashboard, built from synthetic identity files saved
# the way the engine saves them. No hive is read.

BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers/TestHelpers.ps1')

    function script:New-TestUser([string]$Name, [int]$Rid, [string]$Type, [switch]$Disabled) {
        [ordered]@{
            UserName          = $Name
            FullName          = $null
            Rid               = $Rid
            AccountType       = $Type
            AccountTypeReason = 'test'
            CreatedUtc        = '2024-01-01T00:00:00Z'
            LastLoginUtc      = $null
            Groups            = [string[]]@()
            Flags             = [ordered]@{ AccountDisabled = $Disabled.IsPresent; NormalUserAccount = $true }
        }
    }

    function script:New-TestInterface([string]$Address, [string]$Network, [string]$Lease, [switch]$Active) {
        [ordered]@{
            Guid             = '{' + [guid]::NewGuid().ToString().ToUpperInvariant() + '}'
            Address          = $Address
            AddressSource    = 'DHCP'
            NetworkName      = $Network
            LeaseObtainedUtc = $Lease
            LikelyActive     = $Active.IsPresent
        }
    }

    function script:New-TestIdentity {
        # A Complete identity with every hive read. Set and Read change it.
        param([string]$Collection, [hashtable]$Set = @{}, [string[]]$NotRead = @())
        $id = New-HostIdentityRecord -Collection $Collection -RECmdPath 'C:\Tools\RECmd\RECmd.exe' -Status 'Complete'
        foreach ($h in @('SYSTEM', 'SOFTWARE', 'SAM')) {
            $id.Source.Hives[$h] = [ordered]@{ Path = "C\Windows\System32\config\$h"; Read = ($NotRead -notcontains $h) }
        }
        $id.Hostname = 'FAKE-HOST-01'
        $id.Os = [ordered]@{ ProductName = 'Windows 11 Pro'; Build = '26100' }
        $id.Domain = [ordered]@{ Membership = 'Domain'; DnsDomain = 'corp.example'; CachePrimaryDomain = 'FAKECORP' }
        $id.TimeZone = [ordered]@{ KeyName = 'AUS Eastern Standard Time'; ActiveUtcOffset = '+11:00' }
        $id.Users = @(
            (New-TestUser 'Administrator' 500 'BuiltIn' -Disabled)
            (New-TestUser 'Guest' 501 'BuiltIn' -Disabled)
            (New-TestUser 'WsiAccount' 1004 'System' -Disabled)
            (New-TestUser 'alice.fake' 1001 'Interactive')
            (New-TestUser 'bob.fake' 1002 'Interactive' -Disabled)
        )
        $id.Interfaces = @(
            (New-TestInterface '198.51.100.23' 'FAKE-WIFI' '2026-09-15T19:20:00Z' -Active)
            (New-TestInterface '192.0.2.50' 'FAKE-LAN' '2026-08-29T10:40:00Z')
            (New-TestInterface '172.31.0.1' $null $null)
            (New-TestInterface $null $null $null)
        )
        foreach ($k in $Set.Keys) { $id[$k] = $Set[$k] }
        return $id
    }

    function script:Get-HostRow([string]$Html, [string]$Collection) {
        # The table row for one collection.
        $m = [regex]::Match($Html, '<tr><td[^>]*>(?:(?!</tr>).)*?<td>' + [regex]::Escape($Collection) + '</td>.*?</tr>', 'Singleline')
        if (-not $m.Success) { throw "No row for $Collection" }
        return $m.Value
    }

    $script:out = New-TestDirectory (Join-TestPath $TestDrive 'out')
    Save-HostIdentity -OutputRoot $out -Identity (New-TestIdentity 'HOST01') | Out-Null
    Save-HostIdentity -OutputRoot $out -Identity (New-HostIdentityRecord -Collection 'EVTXONLY' -Status 'NoRegistryHives' -Note @('No SYSTEM, SOFTWARE or SAM hive was found.')) | Out-Null
    Save-HostIdentity -OutputRoot $out -Identity (New-TestIdentity 'PARTIAL' -NotRead @('SAM', 'SOFTWARE') -Set @{ Status = 'Partial'; Users = @(); Os = $null; Domain = [ordered]@{ Membership = 'NoDomainEvidence'; DnsDomain = 'corp.example' }; Hostname = 'FAKE-HOST-02'; Notes = [string[]]@('No SAM hive was found.') }) | Out-Null
    Save-HostIdentity -OutputRoot $out -Identity (New-TestIdentity 'NOUSERS' -Set @{ Hostname = 'FAKE-HOST-03'; Users = @((New-TestUser 'Administrator' 500 'BuiltIn'), (New-TestUser 'defaultuser0' 1000 'System')) }) | Out-Null
    Save-HostIdentity -OutputRoot $out -Identity (New-HostIdentityRecord -Collection 'FAILED' -Status 'Failed' -Note @('Running RECmd requires Windows.')) | Out-Null
    Write-TestText -Path (Join-TestPath $out 'BROKEN' 'BROKEN_identity.json') -Line @('{ not json') | Out-Null
    # A working folder is never a collection.
    Save-HostIdentity -OutputRoot $out -Identity (New-TestIdentity '_work') | Out-Null
    $mp = Join-TestPath $out 'run_manifest.csv'
    Initialize-RunManifest -Path $mp | Out-Null
    Set-RunManifestEntry -Path $mp -Collection 'NEVER' -Source 'NEVER' -RunId 'r1' -InputType Loose -Status 'Completed' -HostName 'WS09'

    $script:result = Invoke-IdentityRollup -OutputRoot $out -WarningAction SilentlyContinue
    $script:html = [System.IO.File]::ReadAllText($result.Dashboard)
}

Describe 'Identity dashboard file' {
    It 'is written atomically as identity_dashboard.html in OutputRoot, static and without a BOM' {
        $result.Dashboard | Should -Be (Join-TestPath $out 'identity_dashboard.html')
        Test-Utf8Bom -Path $result.Dashboard | Should -BeFalse
        @(Get-ChildItem -LiteralPath $out -Filter '*.tmp').Count | Should -Be 0
        $html | Should -Match '<meta http-equiv="Content-Security-Policy" content="default-src &#39;none&#39;; style-src &#39;unsafe-inline&#39;">'
        $html | Should -Not -Match '<script'
        $html | Should -Match '<title>Host identity</title>'
    }

    It 'has one row per collection: the identity files, the manifest, and none for a working folder' {
        $result.HostCount | Should -Be 7
        foreach ($c in 'HOST01', 'EVTXONLY', 'PARTIAL', 'NOUSERS', 'FAILED', 'BROKEN', 'NEVER') {
            { Get-HostRow $html $c } | Should -Not -Throw
        }
        $html | Should -Not -Match '<td>_work</td>'
        $result.Counts.Complete | Should -Be 2
        $result.Counts.Partial | Should -Be 1
        $result.Counts.NotRead | Should -Be 1
        $result.Counts.Unreadable | Should -Be 1
    }

    It 'lists hosts with a registry name first, by that name' {
        $html.IndexOf('<td>HOST01</td>') | Should -BeLessThan $html.IndexOf('<td>PARTIAL</td>')
        $html.IndexOf('<td>PARTIAL</td>') | Should -BeLessThan $html.IndexOf('<td>NOUSERS</td>')
        $html.IndexOf('<td>NOUSERS</td>') | Should -BeLessThan $html.IndexOf('<td>BROKEN</td>')
    }
}

Describe 'A host with users and several interfaces' {
    BeforeAll { $script:row = Get-HostRow $html 'HOST01' }

    It 'shows the registry name, OS with its build, domain and time zone' {
        $row | Should -Match '<span class="chip ">FAKE-HOST-01</span>'
        $row | Should -Match 'Windows 11 Pro<div class="sub">build 26100</div>'
        $row | Should -Match 'FAKECORP<div class="sub">corp.example</div>'
        $row | Should -Match 'AUS Eastern Standard Time<div class="sub">UTC\+11:00</div>'
        $row | Should -Match '<span class="badge st-Completed">Complete</span>'
    }

    It 'shows the likely active address with its network name, and folds the others newest lease first' {
        $row | Should -Match '<span class="chip ">198.51.100.23</span><div class="sub">FAKE-WIFI</div><details><summary>3 more</summary>'
        $lan = $row.IndexOf('192.0.2.50 FAKE-LAN <span class="dim">2026-08-29T10:40:00Z</span>')
        $lan | Should -BeGreaterThan 0 -Because 'a lease time stays in UTC, whatever the culture'
        $row.IndexOf('172.31.0.1') | Should -BeGreaterThan $lan
        $row | Should -Match '<li><span class="dim">no address</span></li>'
    }

    It 'shows the interactive users and folds the built-in and system accounts' {
        $row | Should -Match '<span class="chip ">alice.fake</span>'
        $row | Should -Match '<span class="chip off">bob.fake</span><span class="tag">disabled</span>'
        $row | Should -Match '<details><summary>3 built-in or system</summary><ul><li>Administrator <span class="dim">BuiltIn</span></li><li>Guest <span class="dim">BuiltIn</span></li><li>WsiAccount <span class="dim">System</span></li></ul></details>'
        $row | Should -Not -Match '<span class="chip[^"]*">(Administrator|Guest|WsiAccount)</span>'
    }

    It 'keeps every cell short, with no parenthetical asides' {
        $row | Should -Not -Match '[()]'
    }

    It 'tags a Windows 11 build whose product name says Windows 10' {
        $o2 = New-TestDirectory (Join-TestPath $TestDrive 'out-win11')
        Save-HostIdentity -OutputRoot $o2 -Identity (New-TestIdentity 'W11' -Set @{ Os = [ordered]@{ ProductName = 'Windows 10 Pro'; Build = '22631' } }) | Out-Null
        $h = [System.IO.File]::ReadAllText((Invoke-IdentityRollup -OutputRoot $o2).Dashboard)
        Get-HostRow $h 'W11' | Should -Match 'Windows 10 Pro<div class="sub">build 22631<span class="tag">Windows 11</span></div>'
    }
}

Describe 'Hosts without full identity' {
    It 'shows NoRegistryHives across the row, not blank cells' {
        $row = Get-HostRow $html 'EVTXONLY'
        $row | Should -Match '<span class="badge st-other">No registry hives</span>'
        $row | Should -Match '<td colspan="5" class="dim">No registry hives in this collection, as in one of event logs only.</td>'
        $row | Should -Not -Match '<td></td>'
    }

    It 'shows a Partial host''s values, and not read for the hives that were not read' {
        $row = Get-HostRow $html 'PARTIAL'
        $row | Should -Match '<span class="badge st-CompletedWithErrors">Partial</span>'
        $row | Should -Match 'FAKE-HOST-02'
        $row | Should -Match '198.51.100.23'
        # SOFTWARE and SAM weren't read, so the OS, domain and users aren't known.
        ([regex]::Matches($row, '<span class="dim">not read</span>')).Count | Should -Be 3
        $row | Should -Match '<div class="sub">corp.example</div>'
        $row | Should -Match '<summary>1 note</summary><ul class="notes"><li>No SAM hive was found.</li></ul>'
        $row | Should -Not -Match '<td></td>'
    }

    It 'says so when a host has no interactive users' {
        $row = Get-HostRow $html 'NOUSERS'
        $row | Should -Match '<span class="dim">no interactive users</span><details><summary>2 built-in or system</summary>'
    }

    It 'shows a Failed host with its reason' {
        $row = Get-HostRow $html 'FAILED'
        $row | Should -Match '<span class="badge st-Failed">Failed</span>'
        $row | Should -Match 'Host identity could not be read. See the notes.'
        $row | Should -Match '<li>Running RECmd requires Windows.</li>'
    }

    It 'shows Not read for a collection with no identity file, and Unreadable for one it cannot use' {
        Get-HostRow $html 'NEVER' | Should -Match '<span class="badge st-other">Not read</span>.*Host identity has not been read for this collection.'
        Get-HostRow $html 'BROKEN' | Should -Match '<span class="badge st-Failed">Unreadable</span>.*Its identity file could not be read'
    }

    It 'never shows the triage host name as the identity name' {
        Get-HostRow $html 'NEVER' | Should -Not -Match 'WS09'
    }
}

Describe 'What the dashboard never shows' {
    It 'leaves out PasswordHint, ResetData, InternetUserName and every field it does not list, even when a file holds them' {
        $o = New-TestDirectory (Join-TestPath $TestDrive 'out-sensitive')
        $id = New-TestIdentity 'SENS'
        $u = $id.Users[3]
        $u['PasswordHint'] = 'FAKE-HINT-DROP-ME'
        $u['ResetData'] = '{"answer":"FAKE-ANSWER-DROP-ME"}'
        $u['InternetUserName'] = 'alice.fake@example.invalid'
        $u['HomeDirectory'] = 'C:\FAKE-HOME-DROP-ME'
        $u['UserComment'] = 'FAKE-COMMENT-DROP-ME'
        $u['Comment'] = 'FAKE-SAM-COMMENT-DROP-ME'
        $id['PasswordHint'] = 'FAKE-TOP-HINT-DROP-ME'
        $id.Source['RECmdPath'] = 'C:\FAKE-TOOL-PATH-DROP-ME\RECmd.exe'
        $id.Interfaces[0]['DhcpServer'] = '203.0.113.250'
        Save-HostIdentity -OutputRoot $o -Identity $id | Out-Null
        $h = [System.IO.File]::ReadAllText((Invoke-IdentityRollup -OutputRoot $o).Dashboard)
        Get-HostRow $h 'SENS' | Should -Match 'alice.fake'
        foreach ($s in @('PasswordHint', 'ResetData', 'InternetUserName', 'FAKE-HINT-DROP-ME', 'FAKE-ANSWER-DROP-ME', 'example.invalid', 'FAKE-HOME-DROP-ME', 'FAKE-COMMENT-DROP-ME', 'FAKE-SAM-COMMENT-DROP-ME', 'FAKE-TOP-HINT-DROP-ME', 'FAKE-TOOL-PATH-DROP-ME', '203.0.113.250')) {
            $h | Should -Not -Match ([regex]::Escape($s))
        }
    }

    It 'encodes every value, so a name crafted in the evidence cannot add markup' {
        $o = New-TestDirectory (Join-TestPath $TestDrive 'out-evil')
        $evil = '"><img src=x onerror=alert(1)>'
        $id = New-TestIdentity 'EVIL' -Set @{ Hostname = $evil; Notes = [string[]]@("<b>$evil</b>") }
        $id.Users[3]['UserName'] = $evil
        $id.Interfaces[0]['NetworkName'] = $evil
        $id.Os['ProductName'] = $evil
        Save-HostIdentity -OutputRoot $o -Identity $id | Out-Null
        $h = [System.IO.File]::ReadAllText((Invoke-IdentityRollup -OutputRoot $o).Dashboard)
        $h | Should -Not -Match '<img'
        $h | Should -Not -Match '<b>"'
        $h | Should -Match '<li>&lt;b&gt;&quot;&gt;&lt;img'
        $h | Should -Match '&quot;&gt;&lt;img src=x onerror=alert\(1\)&gt;'
    }
}

Describe 'Evidence integrity on the identity dashboard' {
    It 'heads the page with a host whose image changed' {
        $o = New-TestDirectory (Join-TestPath $TestDrive 'out-evidence')
        $note = "$EvidenceChangedPrefix`: the SHA-256 of x changed."
        Save-HostIdentity -OutputRoot $o -Identity (New-TestIdentity 'IMG' -Set @{ Notes = [string[]]@($note) }) | Out-Null
        $h = [System.IO.File]::ReadAllText((Invoke-IdentityRollup -OutputRoot $o).Dashboard)
        $h | Should -Match "<div class=`"warnbox evidence`">$([regex]::Escape($EvidenceChangedPrefix)) for 1 collection\(s\): IMG\."
        Get-HostRow $h 'IMG' | Should -Match '<li><span class="err">'
    }
}
