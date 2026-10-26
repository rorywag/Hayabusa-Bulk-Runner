# Host identity from registry hives. The parser runs against plain-text
# CSVs in tests\fixtures\identity shaped like the output of this tool's
# RECmd batch file, with fake values, so it runs everywhere with RECmd
# mocked. No real or live hive is read.
#
# Running the real RECmd needs Windows and RECMD_COMPAT_PATH set to its
# RECmd.exe, and is tagged Compatibility:
#
#     $env:RECMD_COMPAT_PATH = 'D:\Tools\RECmd\RECmd.exe'
#     Invoke-Pester -Path tests -TagFilter Compatibility
#
# It builds throwaway SYSTEM and SOFTWARE hives from junk keys, byte by
# byte, and checks RECmd still writes the columns the parser reads. SAM is
# not covered there, since a valid SAM can't be made up. It's checked on
# real collections.

BeforeDiscovery {
    $script:onWindows = ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
    $script:realRECmd = $env:RECMD_COMPAT_PATH
    $script:canRunRECmd = $onWindows -and -not [string]::IsNullOrEmpty($realRECmd) -and (Test-Path -LiteralPath $realRECmd -PathType Leaf)
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers/TestHelpers.ps1')
    . (Join-Path $PSScriptRoot 'Helpers/RegistryHive.ps1')
    . (Join-Path $PSScriptRoot 'Helpers/IdentityHelpers.ps1')

    function script:ConvertTo-HintValue([string]$Name) {
        # The inverse of ConvertFrom-DhcpNetworkHint, the form Windows stores.
        $chars = $Name.ToCharArray(); [array]::Reverse($chars)
        $hex = -join ([System.Text.Encoding]::GetEncoding(1252).GetBytes((-join $chars)) | ForEach-Object { $_.ToString('X2') })
        $h = $hex.ToCharArray(); [array]::Reverse($h)
        return (-join $h)
    }

    $script:Parsed = ConvertFrom-RECmdOutput -OutputDirectory $IdentityFixture
}

Describe 'RECmd output fixtures' {
    It 'have every column the parser reads, and PasswordHint and ResetData in the SAM input' {
        foreach ($hive in @('SYSTEM', 'SOFTWARE', 'SAM')) {
            $header = @(Get-CsvHeader -Path (Join-TestPath $IdentityFixture "$hive.csv"))
            foreach ($c in $RECmdMainColumns) { $header | Should -Contain $c }
        }
        foreach ($p in @(@{ H = 'SYSTEM'; P = 'NetworkSettings' }, @{ H = 'SYSTEM'; P = 'DHCPNetworkHint' }, @{ H = 'SAM'; P = 'UserAccounts' })) {
            $header = @(Get-CsvHeader -Path (Join-TestPath $IdentityFixture $FixtureStamp "$($p.H)_$($p.P).csv"))
            foreach ($c in $RECmdPluginColumns[$p.P]) { $header | Should -Contain $c }
        }
        $samText = [System.IO.File]::ReadAllText((Join-TestPath $IdentityFixture $FixtureStamp 'SAM_UserAccounts.csv'))
        @(Get-CsvHeader -Path (Join-TestPath $IdentityFixture $FixtureStamp 'SAM_UserAccounts.csv')) | Should -Contain 'PasswordHint'
        @(Get-CsvHeader -Path (Join-TestPath $IdentityFixture $FixtureStamp 'SAM_UserAccounts.csv')) | Should -Contain 'ResetData'
        $samText | Should -Match 'FAKE-HINT-DROP-ME'
        $samText | Should -Match 'FAKE-ANSWER-DROP-ME'
    }

    It 'repeat interface and user rows, as RECmd batch output does' {
        $ns = @(Import-Csv -LiteralPath (Join-TestPath $IdentityFixture $FixtureStamp 'SYSTEM_NetworkSettings.csv'))
        @($ns | Group-Object -Property BatchKeyPath | Where-Object { $_.Count -gt 1 }).Count | Should -BeGreaterThan 0
        $users = @(Import-Csv -LiteralPath (Join-TestPath $IdentityFixture $FixtureStamp 'SAM_UserAccounts.csv'))
        @($users | Group-Object -Property UserId | Where-Object { $_.Count -gt 1 }).Count | Should -BeGreaterThan 0
    }
}

Describe 'ConvertFrom-RECmdOutput' {
    It 'uses the control set Select\Current names, not ControlSet001' {
        $Parsed.ControlSet | Should -BeExactly 'ControlSet002'
        $Parsed.Hostname | Should -BeExactly 'FAKE-HOST-01'
    }

    It 'reads the time zone, with the biases as signed minutes' {
        $tz = $Parsed.TimeZone
        $tz.KeyName | Should -BeExactly 'AUS Eastern Standard Time'
        $tz.BiasMinutes | Should -Be -600
        $tz.ActiveTimeBiasMinutes | Should -Be -660
        $tz.StandardUtcOffset | Should -BeExactly '+10:00'
        $tz.ActiveUtcOffset | Should -BeExactly '+11:00'
        $tz.StandardName | Should -BeExactly '@tzres.dll,-212'
        $tz.DynamicDaylightDisabled | Should -BeFalse
    }

    It 'reads the OS, with the install date in UTC, and notes a Windows 11 build named Windows 10' {
        $os = $Parsed.Os
        $os.ProductName | Should -BeExactly 'Windows 10 Pro'
        $os.EditionId | Should -BeExactly 'Professional'
        $os.Version | Should -BeExactly '23H2'
        $os.Build | Should -BeExactly '22631'
        $os.InstallDateUtc | Should -BeExactly '2024-01-01T00:00:00Z'
        $os.RegisteredOwner | Should -BeExactly 'Fake Owner'
        $os.RegisteredOrganization | Should -BeExactly 'Example Org'
        @($Parsed.Notes | Where-Object { $_ -like '*build 22631 is Windows 11*' }).Count | Should -Be 1
    }

    It 'reads the domain from the active control set and Winlogon' {
        $d = $Parsed.Domain
        $d.Membership | Should -BeExactly 'Domain'
        $d.DnsDomain | Should -BeExactly 'corp.example'
        $d.NvDomain | Should -BeExactly 'corp.example'
        $d.CachePrimaryDomain | Should -BeExactly 'FAKECORP'
        $d.DefaultDomainName | Should -BeExactly 'FAKECORP'
    }

    It 'reads each user once, ordered by RID' {
        @($Parsed.Users | ForEach-Object { $_.Rid }) | Should -Be @(500, 501, 503, 504, 1000, 1001, 1002, 1003, 1004)
    }

    It 'classifies <Name> as <Type>' -ForEach @(
        @{ Name = 'Administrator'; Type = 'BuiltIn' }
        @{ Name = 'Guest'; Type = 'BuiltIn' }
        @{ Name = 'DefaultAccount'; Type = 'BuiltIn' }
        @{ Name = 'WDAGUtilityAccount'; Type = 'BuiltIn' }
        @{ Name = 'defaultuser0'; Type = 'System' }
        @{ Name = 'alice.fake'; Type = 'Interactive' }
        @{ Name = 'bob.fake'; Type = 'Interactive' }
        @{ Name = 'HomeGroupUser$'; Type = 'System' }
        @{ Name = 'WsiAccount'; Type = 'System' }
    ) {
        $u = @($Parsed.Users | Where-Object { $_.UserName -ceq $Name })
        $u.Count | Should -Be 1
        $u[0].AccountType | Should -BeExactly $Type
        $u[0].AccountTypeReason | Should -Not -BeNullOrEmpty
    }

    It 'keeps the SAM columns, with times in UTC and groups as a list' {
        $a = @($Parsed.Users | Where-Object { $_.UserName -ceq 'alice.fake' })[0]
        $a.FullName | Should -BeExactly 'Alice Fake'
        $a.CreatedUtc | Should -BeExactly '2024-01-01T00:20:00Z'
        $a.LastLoginUtc | Should -BeExactly '2026-09-29T07:45:10Z'
        $a.LastPasswordChangeUtc | Should -BeExactly '2025-06-01T12:00:00Z'
        $a.TotalLoginCount | Should -Be 42
        $a.InvalidLoginCount | Should -Be 3
        @($a.Groups) | Should -Be @('Administrators', 'Users')
        $a.Flags.NormalUserAccount | Should -BeTrue
        $a.Flags.AccountDisabled | Should -BeFalse
        $a.Flags.PasswordDoesNotExpire | Should -BeTrue
        $b = @($Parsed.Users | Where-Object { $_.UserName -ceq 'bob.fake' })[0]
        $b.LastLoginUtc | Should -BeNullOrEmpty
        $g = @($Parsed.Users | Where-Object { $_.UserName -ceq 'Guest' })[0]
        $g.Flags.PasswordNotRequired | Should -BeTrue
        $g.Flags.AccountDisabled | Should -BeTrue
        $g.Comment | Should -BeExactly 'Built-in account for guest access to the computer/domain'
    }

    It 'drops PasswordHint, ResetData and the other columns it does not list' {
        $json = ConvertTo-Json -InputObject $Parsed -Depth 10
        foreach ($s in @('PasswordHint', 'ResetData', 'FAKE-HINT-DROP-ME', 'FAKE-ANSWER-DROP-ME', 'InternetUserName', 'example.invalid', 'LastIncorrectPassword')) {
            $json | Should -Not -Match ([regex]::Escape($s))
        }
        foreach ($u in $Parsed.Users) {
            @($u.Keys) | Should -Not -Contain 'PasswordHint'
            @($u.Keys) | Should -Not -Contain 'ResetData'
        }
    }

    It 'returns every interface in the active control set once, newest lease first' {
        @($Parsed.Interfaces | ForEach-Object { $_.Guid }) | Should -Be @(
            '{22222222-BBBB-4BBB-8BBB-222222222222}'
            '{11111111-AAAA-4AAA-8AAA-111111111111}'
            '{33333333-CCCC-4CCC-8CCC-333333333333}'
            '{44444444-DDDD-4DDD-8DDD-444444444444}'
        )
        @($Parsed.Interfaces | Where-Object { $_.Address -eq '10.99.99.99' }).Count | Should -Be 0 -Because 'that interface is only in ControlSet001'
    }

    It 'flags only the newest leased interface as likely active' {
        @($Parsed.Interfaces | Where-Object { $_.LikelyActive } | ForEach-Object { $_.Address }) | Should -Be @('198.51.100.23')
    }

    It 'falls back to DHCPIPAddress when IPAddress is blank, with the DHCP mask, gateway, DNS and lease' {
        $a = @($Parsed.Interfaces | Where-Object { $_.Guid -like '{11111111*' })[0]
        $a.Address | Should -BeExactly '192.0.2.50'
        $a.AddressSource | Should -BeExactly 'DHCP'
        $a.SubnetMask | Should -BeExactly '255.255.255.0'
        @($a.DefaultGateway) | Should -Be @('192.0.2.1')
        @($a.NameServer) | Should -Be @('192.0.2.1', '192.0.2.2')
        $a.DhcpServer | Should -BeExactly '192.0.2.1'
        $a.DhcpDomain | Should -BeExactly 'home.example'
        $a.DhcpEnabled | Should -BeTrue
        $a.LeaseObtainedUtc | Should -BeExactly '2026-08-29T10:40:00Z'
        $a.LeaseTerminatesUtc | Should -BeExactly '2026-08-30T10:40:00Z'
        @($a.StaticAddresses).Count | Should -Be 0
    }

    It 'labels each address with the network it was leased on' {
        @($Parsed.Interfaces | Where-Object { $_.Guid -like '{11111111*' })[0].NetworkName | Should -BeExactly 'FAKE-LAN'
        # This interface has no network subkeys, so the DHCPNetworkHint
        # plugin skips it and the name is decoded from its own value.
        @($Parsed.Interfaces | Where-Object { $_.Guid -like '{22222222*' })[0].NetworkName | Should -BeExactly 'FAKE-WIFI'
        @($Parsed.Interfaces | Where-Object { $_.Guid -like '{33333333*' })[0].NetworkName | Should -BeNullOrEmpty
    }

    It 'reads a static interface with all its addresses and its own gateway and DNS' {
        $c = @($Parsed.Interfaces | Where-Object { $_.Guid -like '{33333333*' })[0]
        $c.Address | Should -BeExactly '203.0.113.7'
        $c.AddressSource | Should -BeExactly 'Static'
        @($c.StaticAddresses) | Should -Be @('203.0.113.7', '203.0.113.8')
        $c.SubnetMask | Should -BeExactly '255.255.255.0'
        @($c.DefaultGateway) | Should -Be @('203.0.113.1')
        @($c.NameServer) | Should -Be @('203.0.113.53', '203.0.113.54')
        $c.DhcpEnabled | Should -BeFalse
        $c.LeaseObtainedUtc | Should -BeNullOrEmpty
    }

    It 'keeps an interface with no address, last' {
        $d = @($Parsed.Interfaces)[-1]
        $d.Guid | Should -BeLike '{44444444*'
        $d.Address | Should -BeNullOrEmpty
        $d.AddressSource | Should -BeNullOrEmpty
        $d.LikelyActive | Should -BeFalse
    }

    It 'falls back to the raw interface values when the NetworkSettings CSV is missing' {
        $dir = New-TestDirectory (Join-TestPath $TestDrive 'raw-only')
        Copy-Item -LiteralPath (Join-TestPath $IdentityFixture 'SYSTEM.csv') -Destination (Join-TestPath $dir 'SYSTEM.csv')
        $p = ConvertFrom-RECmdOutput -OutputDirectory $dir
        @($p.Interfaces | ForEach-Object { $_.Address }) | Should -Be @('198.51.100.23', '192.0.2.50', '203.0.113.7', $null)
        @($p.Interfaces)[0].LeaseObtainedUtc | Should -BeExactly '2026-09-15T19:20:00Z'
        @($p.Interfaces)[1].NetworkName | Should -BeExactly 'FAKE-LAN'
        @($p.Users).Count | Should -Be 0
        $p.Os | Should -BeNullOrEmpty
    }

    It 'returns empty parts, without an error, when there is no output' {
        $p = ConvertFrom-RECmdOutput -OutputDirectory (New-TestDirectory (Join-TestPath $TestDrive 'empty-out'))
        $p.Hostname | Should -BeNullOrEmpty
        $p.Os | Should -BeNullOrEmpty
        $p.Domain | Should -BeNullOrEmpty
        @($p.Users).Count | Should -Be 0
        @($p.Interfaces).Count | Should -Be 0
    }

    It 'parses under strict mode, as the entry scripts run' {
        $p = & {
            Set-StrictMode -Version Latest
            ConvertFrom-RECmdOutput -OutputDirectory $IdentityFixture
        }
        $p.Hostname | Should -BeExactly 'FAKE-HOST-01'
        @($p.Interfaces).Count | Should -Be 4
    }
}

Describe 'Get-UserAccountType' {
    BeforeAll {
        function script:New-UserFlag([switch]$Normal, [string]$Set) {
            $f = [ordered]@{}
            foreach ($n in $UserFlagColumns) { $f[$n] = $false }
            $f['NormalUserAccount'] = $Normal.IsPresent
            if ($Set) { $f[$Set] = $true }
            return $f
        }
    }

    It 'classes WsiAccount, RID 1004 with the normal user account flag and no trust flag, as System' {
        $t = Get-UserAccountType -Rid 1004 -UserName 'WsiAccount' -Flags (New-UserFlag -Normal)
        $t.Type | Should -BeExactly 'System'
        $t.Reason | Should -BeExactly 'An account Windows or other software manages.'
        (Get-UserAccountType -Rid 1004 -UserName 'wsiaccount' -Flags (New-UserFlag -Normal)).Type | Should -BeExactly 'System'
    }

    It 'classes HelpAssistant, the Remote Assistance account on older hosts, as System' {
        (Get-UserAccountType -Rid 1000 -UserName 'HelpAssistant' -Flags (New-UserFlag -Normal)).Type | Should -BeExactly 'System'
    }

    It 'still classes <Why>' -ForEach @(
        @{ Why = 'a normal account with a RID of 1000 or more as Interactive'; Rid = 1005; Name = 'carol.fake'; Normal = $true; Set = ''; Type = 'Interactive' }
        @{ Why = 'a name that only starts like WsiAccount as Interactive'; Rid = 1006; Name = 'WsiAccountant'; Normal = $true; Set = ''; Type = 'Interactive' }
        @{ Why = 'a RID under 1000 as BuiltIn'; Rid = 500; Name = 'Administrator'; Normal = $true; Set = ''; Type = 'BuiltIn' }
        @{ Why = 'a trust account as System'; Rid = 1007; Name = 'WS01'; Normal = $true; Set = 'WorkstationTrustAccount'; Type = 'System' }
        @{ Why = 'an account without the normal user flag as System'; Rid = 1008; Name = 'odd.fake'; Normal = $false; Set = ''; Type = 'System' }
    ) {
        (Get-UserAccountType -Rid $Rid -UserName $Name -Flags (New-UserFlag -Normal:$Normal -Set $Set)).Type | Should -BeExactly $Type
    }
}

Describe 'Likely active interface' {
    BeforeAll {
        $script:ifKey = 'controlset001\services\tcpip\parameters\interfaces'
        function script:New-InterfaceTable([hashtable[]]$Interface) {
            # Raw values as Get-RECmdValueTable gives them, keyed in lower case.
            $t = @{ 'select' = @{ current = '1' } }
            foreach ($i in $Interface) {
                $v = @{ enabledhcp = '1'; dhcpipaddress = $i.Address; leaseobtainedtime = [string]$i.Lease }
                if ($i.Name) { $v['dhcpnetworkhint'] = ConvertTo-HintValue $i.Name }
                $t["$ifKey\$($i.Guid)"] = $v
            }
            return $t
        }
        $script:vEth = @{ Guid = '{a0000000-0000-4000-8000-00000000000a}'; Address = '172.20.0.5'; Lease = 1790000000 }
        $script:wifi = @{ Guid = '{b0000000-0000-4000-8000-00000000000b}'; Address = '192.0.2.50'; Lease = 1788000000; Name = 'FAKE-WIFI' }
    }

    It 'flags the named interface over a virtual adapter with a newer lease and no network name, keeping lease order' {
        $list = @(Get-IdentityInterface -System (New-InterfaceTable @($vEth, $wifi)) -ControlSet 'ControlSet001')
        @($list | ForEach-Object { $_.Address }) | Should -Be @('172.20.0.5', '192.0.2.50') -Because 'the list stays newest lease first'
        @($list | Where-Object { $_.LikelyActive } | ForEach-Object { $_.Address }) | Should -Be @('192.0.2.50')
    }

    It 'still flags the newest leased interface with an address when none has a network name' {
        $unnamed = $wifi.Clone(); $unnamed.Remove('Name')
        $list = @(Get-IdentityInterface -System (New-InterfaceTable @($vEth, $unnamed)) -ControlSet 'ControlSet001')
        @($list | Where-Object { $_.LikelyActive } | ForEach-Object { $_.Address }) | Should -Be @('172.20.0.5')
    }

    It 'takes the newest lease among several named interfaces' {
        $lan = @{ Guid = '{c0000000-0000-4000-8000-00000000000c}'; Address = '198.51.100.23'; Lease = 1789000000; Name = 'FAKE-LAN' }
        $list = @(Get-IdentityInterface -System (New-InterfaceTable @($vEth, $wifi, $lan)) -ControlSet 'ControlSet001')
        @($list | Where-Object { $_.LikelyActive } | ForEach-Object { $_.Address }) | Should -Be @('198.51.100.23')
    }

    It 'never flags a named interface that has no address' {
        $gone = @{ Guid = '{d0000000-0000-4000-8000-00000000000d}'; Address = $null; Lease = 1795000000; Name = 'FAKE-OLD' }
        $list = @(Get-IdentityInterface -System (New-InterfaceTable @($vEth, $gone)) -ControlSet 'ControlSet001')
        @($list | Where-Object { $_.LikelyActive } | ForEach-Object { $_.Address }) | Should -Be @('172.20.0.5')
    }
}

Describe 'Active control set' {
    It 'falls back to the only control set when Select\Current is missing, and says so' {
        $cs = Get-ActiveControlSet -System @{ 'controlset003\control\computername\computername' = @{ computername = 'X' } }
        $cs.Name | Should -BeExactly 'ControlSet003'
        $cs.Note | Should -BeLike '*only control set*'
    }

    It 'gives no control set when there are several and no Select\Current' {
        $cs = Get-ActiveControlSet -System @{ 'controlset001\control' = @{}; 'controlset002\control' = @{} }
        $cs.Name | Should -BeNullOrEmpty
        $cs.Note | Should -BeLike '*not known*'
    }
}

Describe 'Value conversion' {
    It 'reads a REG_DWORD written unsigned as a signed number' -ForEach @(
        @{ In = '4294966696'; Out = -600 }
        @{ In = '60'; Out = 60 }
        @{ In = '0'; Out = 0 }
    ) {
        ConvertTo-IdentityInt32 -Value $In | Should -Be $Out
    }

    It 'gives null for a value that is not a DWORD' -ForEach @(
        @{ In = '' }, @{ In = 'abc' }, @{ In = '99999999999' }
    ) {
        ConvertTo-IdentityInt32 -Value $In | Should -BeNullOrEmpty
    }

    It 'reads RECmd times and Unix seconds as UTC, and never-set times as null' {
        ConvertTo-IdentityUtc -Value '2026-09-29 07:45:10.1234567' | Should -BeExactly '2026-09-29T07:45:10Z'
        ConvertTo-IdentityUtc -Value '1704067200' -UnixSeconds | Should -BeExactly '2024-01-01T00:00:00Z'
        ConvertTo-IdentityUtc -Value '1601-01-01 00:00:00.0000000' | Should -BeNullOrEmpty
        ConvertTo-IdentityUtc -Value '' | Should -BeNullOrEmpty
        ConvertTo-IdentityUtc -Value '0' -UnixSeconds | Should -BeNullOrEmpty
        ConvertTo-IdentityUtc -Value 'not a time' | Should -BeNullOrEmpty
    }

    It 'gives the UTC offset for a bias' -ForEach @(
        @{ Bias = -600; Offset = '+10:00' }
        @{ Bias = 300; Offset = '-05:00' }
        @{ Bias = -330; Offset = '+05:30' }
        @{ Bias = 0; Offset = '+00:00' }
    ) {
        ConvertTo-UtcOffsetText -BiasMinutes $Bias | Should -BeExactly $Offset
    }

    It 'decodes a DHCP network hint the way the RECmd plugin does' {
        ConvertFrom-DhcpNetworkHint -Value '6414B454D275946494' | Should -BeExactly 'FAKE-WIFI'
        ConvertFrom-DhcpNetworkHint -Value (ConvertTo-HintValue ('Caf' + [char]0x00E9)) | Should -BeExactly ('Caf' + [char]0x00E9)
        ConvertFrom-DhcpNetworkHint -Value 'xyz' | Should -BeNullOrEmpty
        ConvertFrom-DhcpNetworkHint -Value '' | Should -BeNullOrEmpty
    }
}

Describe 'Find-RegistryHive' {
    It 'finds the hives under a KAPE drive letter folder, in any case, with their logs' {
        $root = Join-TestPath $TestDrive 'find-kape'
        $config = Join-TestPath $root 'C' 'wInDoWs' 'SYSTEM32' 'Config'
        New-FakeHive (Join-TestPath $config 'system') | Out-Null
        New-FakeHive (Join-TestPath $config 'SOFTWARE') | Out-Null
        New-FakeHive (Join-TestPath $config 'Sam') | Out-Null
        Write-TestText -Path (Join-TestPath $config 'system.LOG1') -Line @('log') | Out-Null
        Write-TestText -Path (Join-TestPath $config 'SYSTEM.log2') -Line @('log') | Out-Null
        Write-TestText -Path (Join-TestPath $config 'SOFTWARE.LOG1') -Line @() | Out-Null
        Write-TestText -Path (Join-TestPath $config 'SYSTEM.LOG3') -Line @('not a log') | Out-Null
        $f = Find-RegistryHive -Root $root
        $f.Found | Should -BeTrue
        $f.ConfigDirectory | Should -Be $config
        $f.Hives['SYSTEM'] | Should -Be (Join-TestPath $config 'system')
        $f.Hives['SAM'] | Should -Be (Join-TestPath $config 'Sam')
        @($f.Logs['SYSTEM'] | ForEach-Object { Split-Path -Leaf $_ }) | Should -Be @('system.LOG1', 'SYSTEM.log2')
        @($f.Logs['SOFTWARE']).Count | Should -Be 0 -Because 'an empty log is left out'
        @($f.Notes).Count | Should -Be 0
    }

    It 'finds hives at the collection root and under a folder holding the drive folder' {
        $a = Join-TestPath $TestDrive 'find-root'
        New-FakeHive (Join-TestPath $a 'Windows' 'System32' 'config' 'SYSTEM') | Out-Null
        (Find-RegistryHive -Root $a).Hives['SYSTEM'] | Should -Not -BeNullOrEmpty
        $b = Join-TestPath $TestDrive 'find-nested'
        New-HiveCollection -Root (Join-TestPath $b 'HOST01') | Out-Null
        (Find-RegistryHive -Root $b).Hives['SOFTWARE'] | Should -BeLike '*HOST01*'
    }

    It 'returns Found false, without an error, for a collection of event logs only' {
        $root = Join-TestPath $TestDrive 'find-evtx'
        Write-TestText -Path (Join-TestPath $root 'C' 'Windows' 'System32' 'winevt' 'Logs' 'Security.txt') -Line @('x') | Out-Null
        $f = Find-RegistryHive -Root $root
        $f.Found | Should -BeFalse
        $f.Hives['SYSTEM'] | Should -BeNullOrEmpty
    }

    It 'skips a file with a hive name that is not a hive, and says why' {
        $root = Join-TestPath $TestDrive 'find-bad'
        $config = Join-TestPath $root 'C' 'Windows' 'System32' 'config'
        Write-TestText -Path (Join-TestPath $config 'SYSTEM') -Line @(('x' * 5000)) | Out-Null
        Write-TestText -Path (Join-TestPath $config 'SAM') -Line @('tiny') | Out-Null
        New-FakeHive (Join-TestPath $config 'SOFTWARE') | Out-Null
        $f = Find-RegistryHive -Root $root
        $f.Hives['SYSTEM'] | Should -BeNullOrEmpty
        $f.Hives['SAM'] | Should -BeNullOrEmpty
        $f.Hives['SOFTWARE'] | Should -Not -BeNullOrEmpty
        @($f.Notes | Where-Object { $_ -like '*SYSTEM: not a registry hive*' }).Count | Should -Be 1
        @($f.Notes | Where-Object { $_ -like '*SAM: too small*' }).Count | Should -Be 1
    }

    It 'uses the config folder with the most hives when there are several, and names the other' {
        $root = Join-TestPath $TestDrive 'find-two'
        New-HiveCollection -Root $root -Drive 'C' -Hive @('SYSTEM') | Out-Null
        $d = New-HiveCollection -Root $root -Drive 'D' -Hive @('SYSTEM', 'SOFTWARE', 'SAM')
        $f = Find-RegistryHive -Root $root
        $f.ConfigDirectory | Should -Be $d
        @($f.Notes | Where-Object { $_ -like '*More than one*' }).Count | Should -Be 1
    }

    It 'finds the hives in a Velociraptor offline collection, under data\uploads\auto\C%3A' {
        $root = Join-TestPath $TestDrive 'find-velociraptor' 'HOST01'
        $config = New-HiveCollection -Root (Join-TestPath $root 'data' 'uploads' 'auto') -Drive 'C%3A'
        Write-TestText -Path (Join-TestPath $root 'client_info.json') -Line @('{}') | Out-Null
        New-TestDirectory (Join-TestPath $root 'results') | Out-Null
        $f = Find-RegistryHive -Root $root
        $f.Found | Should -BeTrue
        $f.ConfigDirectory | Should -Be $config
        foreach ($h in 'SYSTEM', 'SOFTWARE', 'SAM') {
            $f.Hives[$h] | Should -Be (Join-TestPath $config $h)
        }
        Get-RelativeIdentityPath -Root $root -Path $f.ConfigDirectory | Should -Be (Join-TestPath 'data' 'uploads' 'auto' 'C%3A' 'Windows' 'System32' 'config')
    }

    It 'finds a Windows folder six folders down, the deepest it looks' {
        $root = Join-TestPath $TestDrive 'find-six'
        New-HiveCollection -Root (Join-TestPath $root 'a' 'b' 'c' 'd' 'e') | Out-Null
        (Find-RegistryHive -Root $root).Found | Should -BeTrue
    }

    It 'does not look deeper than six folders down' {
        $root = Join-TestPath $TestDrive 'find-deep'
        New-HiveCollection -Root (Join-TestPath $root 'a' 'b' 'c' 'd' 'e' 'f') | Out-Null
        (Find-RegistryHive -Root $root).Found | Should -BeFalse
    }

    It 'stops at the first level holding hives, so a deeper copy is never used' {
        $root = Join-TestPath $TestDrive 'find-first'
        $kape = New-HiveCollection -Root $root -Drive 'C'
        New-HiveCollection -Root (Join-TestPath $root 'C' 'Users' 'x' 'copy') | Out-Null
        $f = Find-RegistryHive -Root $root
        $f.ConfigDirectory | Should -Be $kape
        @($f.Notes | Where-Object { $_ -like '*More than one*' }).Count | Should -Be 0
    }
}

Describe 'RECmd path' {
    It 'returns the full path of a RECmd.exe outside the collection' {
        Assert-RECmdPath -Path $fakeRECmd -CollectionRoot (Join-TestPath $TestDrive 'coll') | Should -Be $fakeRECmd
    }

    It 'refuses <Why>' -ForEach @(
        @{ Why = 'an empty path'; P = ''; Like = '*empty*' }
        @{ Why = 'a relative path'; P = 'tools\RECmd.exe'; Like = '*full path*' }
        @{ Why = 'a double quote'; P = 'C:\a"b\RECmd.exe'; Like = '*double quote*' }
    ) {
        Get-ThrownMessage { Assert-RECmdPath -Path $P } | Should -BeLike $Like
    }

    It 'refuses a file not named RECmd.exe, a missing file, and one inside the collection' {
        $other = Write-TestText -Path (Join-TestPath $TestDrive 'tools' 'other.exe') -Line @('x')
        Get-ThrownMessage { Assert-RECmdPath -Path $other } | Should -BeLike '*must point to RECmd.exe*'
        Get-ThrownMessage { Assert-RECmdPath -Path (Join-TestPath $TestDrive 'none' 'RECmd.exe') } | Should -BeLike 'RECmd not found*'
        $coll = Join-TestPath $TestDrive 'evil'
        $planted = Write-TestText -Path (Join-TestPath $coll 'C' 'RECmd.exe') -Line @('x')
        Get-ThrownMessage { Assert-RECmdPath -Path $planted -CollectionRoot $coll } | Should -BeLike '*inside the collection*'
    }

    It 'is read from RECmdPath in the config, relative to the config file' {
        $dir = New-TestDirectory (Join-TestPath $TestDrive 'tools')
        $cfg = Import-EngagementConfig -Path (Write-TestText -Path (Join-TestPath $dir 'engagement.psd1') -Line @("@{ RECmdPath = 'RECmd\RECmd.exe'; MinLevel = 'high' }"))
        Resolve-RECmdPath -Config $cfg | Should -Be $fakeRECmd
        Resolve-RECmdPath -Config $null | Should -BeNullOrEmpty
        $none = Import-EngagementConfig -Path (Write-TestText -Path (Join-TestPath $dir 'none.psd1') -Line @("@{ MinLevel = 'high' }"))
        Resolve-RECmdPath -Config $none | Should -BeNullOrEmpty
        $empty = Import-EngagementConfig -Path (Write-TestText -Path (Join-TestPath $dir 'blank.psd1') -Line @("@{ RECmdPath = '' }"))
        Get-ThrownMessage { Resolve-RECmdPath -Config $empty } | Should -BeLike '*sets RECmdPath to an empty value*'
    }

    It 'is not a run setting, so run-meta and Hayabusa are unaffected' {
        $tool = New-TestDirectory (Join-TestPath $TestDrive 'hbtool')
        New-TestDirectory (Join-TestPath $tool 'rules') | Out-Null
        $hb = Write-TestText -Path (Join-TestPath $tool 'hayabusa.exe') -Line @('x')
        New-TestDirectory (Join-TestPath $tool 'config') | Out-Null
        Copy-Item -LiteralPath $ProfilesFixture -Destination (Join-TestPath $tool 'config' 'profiles.yaml')
        $cfg = Import-EngagementConfig -Path (Write-TestText -Path (Join-TestPath $tool 'e.psd1') -Line @("@{ RECmdPath = 'C:\Tools\RECmd\RECmd.exe' }"))
        $r = Resolve-RunSetting -CommandLine @{} -Config $cfg -HayabusaPath $hb
        @($r.Sources.Keys) | Should -Not -Contain 'RECmdPath'
        @($r.Selection.Keys) | Should -Not -Contain 'RECmdPath'
        Get-ThrownMessage { Import-EngagementConfig -Path (Write-TestText -Path (Join-TestPath $tool 'typo.psd1') -Line @("@{ RECmdPth = 'x' }")) } | Should -BeLike '*unknown key*RECmdPth*Allowed keys:*RECmdPath*'
    }
}

Describe 'New-RECmdArgument' {
    It 'passes each path as its own argument and turns off recovery of deleted data' {
        New-RECmdArgument -HivePath 'C:\w\h\SYSTEM\SYSTEM' -BatchPath 'C:\t\HostIdentity.reb' -OutputDirectory 'C:\w\out' -CsvName 'SYSTEM.csv' |
            Should -Be @('-f', 'C:\w\h\SYSTEM\SYSTEM', '--bn', 'C:\t\HostIdentity.reb', '--csv', 'C:\w\out', '--csvf', 'SYSTEM.csv', '--recover', 'false')
    }

    It 'adds --nl only when asked' {
        $a = @(New-RECmdArgument -HivePath 'h' -BatchPath 'b' -OutputDirectory 'o' -CsvName 'SAM.csv' -NoTransactionLogs)
        $a[-1] | Should -BeExactly '--nl'
        @(New-RECmdArgument -HivePath 'h' -BatchPath 'b' -OutputDirectory 'o' -CsvName 'SAM.csv') | Should -Not -Contain '--nl'
    }

    It 'refuses a path Windows PowerShell 5.1 would pass wrongly' {
        Get-ThrownMessage { New-RECmdArgument -HivePath 'C:\a b\' -BatchPath 'b' -OutputDirectory 'o' -CsvName 'x.csv' } | Should -BeLike '*ends in a backslash*'
    }

    It 'reads the version RECmd prints' {
        Get-RECmdVersionNumber -Output @('', 'RECmd version 2026.10.0', 'Author: x') | Should -BeExactly '2026.10.0'
        Get-RECmdVersionNumber -Output @('nothing here') | Should -BeNullOrEmpty
    }
}

Describe 'Host identity batch file' {
    BeforeAll {
        $script:reb = [System.IO.File]::ReadAllLines($HostIdentityBatchPath)
    }

    It 'reads only SYSTEM, SOFTWARE and SAM' {
        $types = @($reb | ForEach-Object { if ($_ -match '^\s*HiveType:\s*(\S+)') { $Matches[1] } } | Sort-Object -Unique)
        $types | Should -Be @('SAM', 'SOFTWARE', 'SYSTEM')
    }

    It 'asks for no value that holds a credential' {
        $names = @($reb | ForEach-Object { if ($_ -match '^\s*ValueName:\s*(.+)$') { $Matches[1].Trim() } })
        $names | Should -Not -Contain 'DefaultPassword'
        $names | Should -Not -Contain 'AltDefaultPassword'
        @($reb | Where-Object { $_ -match '^\s*KeyPath:.*(NTUSER|Policy\\Secrets|Secrets)' }).Count | Should -Be 0
    }

    It 'gives every entry the same category' {
        @($reb | Where-Object { $_ -match '^\s*Category:' } | ForEach-Object { ($_ -split ':', 2)[1].Trim() } | Sort-Object -Unique) | Should -Be @('Host Identity')
    }
}

Describe 'Get-HostIdentity with RECmd mocked' {
    BeforeAll {
        $script:recmdVersionLine = "RECmd version $TestedRECmdVersion"
        function script:Get-WorkFolder([string]$Out) {
            return @(Get-ChildItem -LiteralPath (Join-TestPath $Out '_work') -Directory -ErrorAction SilentlyContinue)
        }
    }

    It 'reads the hives from copies, records them, and removes its work folder' {
        $root = Join-TestPath $TestDrive 'e2e' 'HOST01'
        $config = New-HiveCollection -Root $root
        Write-TestText -Path (Join-TestPath $config 'SYSTEM.LOG1') -Line @('log') | Out-Null
        $before = Get-FileHashMap -Path $root
        $out = Join-TestPath $TestDrive 'e2e-out'
        $script:seen = New-Object System.Collections.Generic.List[object]
        Mock Invoke-RECmd {
            $hive = Get-ArgumentValue $Argument '-f'
            $script:seen.Add([pscustomobject]@{
                    Hive = $hive
                    Logs = @(Get-ChildItem -LiteralPath (Split-Path -Parent $hive) -File | Where-Object { $_.Name -like '*.LOG*' } | ForEach-Object { $_.Name })
                    Path = $RECmdPath
                })
            Copy-FixtureOutput -Argument $Argument
            [pscustomobject]@{ ExitCode = 0; Output = @($recmdVersionLine, 'Found 12 key/value pairs across 1 file') }
        }

        $id = Get-HostIdentity -Collection 'HOST01' -CollectionRoot $root -OutputRoot $out -RECmdPath $fakeRECmd

        $id.Status | Should -BeExactly 'Complete'
        $id.SchemaVersion | Should -Be $HostIdentitySchemaVersion
        $id.Collection | Should -BeExactly 'HOST01'
        $id.Hostname | Should -BeExactly 'FAKE-HOST-01'
        @($id.Users).Count | Should -Be 9
        @($id.Interfaces).Count | Should -Be 4
        $id.ExtractedUtc | Should -Match '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$'
        $id.Source.RECmdVersion | Should -BeExactly $TestedRECmdVersion
        $id.Source.TestedRECmdVersion | Should -BeExactly $TestedRECmdVersion
        $id.Source.ConfigDirectory | Should -Be (Join-TestPath 'C' 'Windows' 'System32' 'config')
        $id.Source.Hives['SYSTEM'].Path | Should -Be (Join-TestPath 'C' 'Windows' 'System32' 'config' 'SYSTEM')
        $id.Source.Hives['SYSTEM'].Sha256 | Should -BeExactly $before[(Join-TestPath $config 'SYSTEM')]
        @($id.Source.Hives['SYSTEM'].TransactionLogs) | Should -Be @('SYSTEM.LOG1')
        @($id.Notes | Where-Object { $_ -like '*not the version*' }).Count | Should -Be 0

        $seen.Count | Should -Be 3
        foreach ($call in $seen) {
            Test-PathIsWithin -Path $call.Hive -Parent (Join-TestPath $out '_work') | Should -BeTrue -Because 'RECmd is only given a copy'
            $call.Path | Should -Be $fakeRECmd
        }
        @($seen[0].Logs) | Should -Be @('SYSTEM.LOG1')
        @($seen[1].Logs).Count | Should -Be 0
        Get-WorkFolder $out | Should -BeNullOrEmpty
        $after = Get-FileHashMap -Path $root
        $after.Count | Should -Be $before.Count
        foreach ($k in $before.Keys) { $after[$k] | Should -BeExactly $before[$k] }
    }

    It 'clears ReadOnly on the copies of a read-only hive, so its work folder still comes down' {
        $root = Join-TestPath $TestDrive 'e2e-readonly' 'HOST01'
        $config = New-HiveCollection -Root $root
        Write-TestText -Path (Join-TestPath $config 'SAM.LOG1') -Line @('log') | Out-Null
        $sources = @(Get-ChildItem -LiteralPath $config -File | ForEach-Object { $_.FullName })
        foreach ($f in $sources) { [System.IO.File]::SetAttributes($f, [System.IO.FileAttributes]::ReadOnly) }
        $before = Get-FileHashMap -Path $root
        $out = Join-TestPath $TestDrive 'e2e-readonly-out'
        $script:copyReadOnly = New-Object System.Collections.Generic.List[string]
        Mock Invoke-RECmd {
            $hive = Get-ArgumentValue $Argument '-f'
            foreach ($f in @(Get-ChildItem -LiteralPath (Split-Path -Parent $hive) -File)) {
                if (([System.IO.File]::GetAttributes($f.FullName) -band [System.IO.FileAttributes]::ReadOnly) -ne 0) { $script:copyReadOnly.Add($f.Name) }
            }
            Copy-FixtureOutput -Argument $Argument
            [pscustomobject]@{ ExitCode = 0; Output = @($recmdVersionLine) }
        }
        try {
            $id = Get-HostIdentity -Collection 'HOST01' -CollectionRoot $root -OutputRoot $out -RECmdPath $fakeRECmd -WarningVariable w -WarningAction SilentlyContinue
            $id.Status | Should -BeExactly 'Complete'
            $copyReadOnly.Count | Should -Be 0 -Because 'each hive and log copy is a plain file'
            @($w | Where-Object { "$_" -like '*work folder*' }).Count | Should -Be 0
            Get-WorkFolder $out | Should -BeNullOrEmpty
            foreach ($f in $sources) {
                ([System.IO.File]::GetAttributes($f) -band [System.IO.FileAttributes]::ReadOnly) | Should -Be ([System.IO.FileAttributes]::ReadOnly) -Because 'the evidence keeps its attributes'
            }
            $after = Get-FileHashMap -Path $root
            foreach ($k in $before.Keys) { $after[$k] | Should -BeExactly $before[$k] }
        }
        finally {
            foreach ($f in $sources) { [System.IO.File]::SetAttributes($f, [System.IO.FileAttributes]::Normal) }
        }
    }

    It 'returns NoRegistryHives, without running RECmd, for a collection of event logs only' {
        $root = Join-TestPath $TestDrive 'e2e-evtx' 'HOST02'
        Write-TestText -Path (Join-TestPath $root 'C' 'Windows' 'System32' 'winevt' 'Logs' 'Security.txt') -Line @('x') | Out-Null
        Mock Invoke-RECmd { throw 'RECmd should not run' }
        $id = Get-HostIdentity -Collection 'HOST02' -CollectionRoot $root -OutputRoot (Join-TestPath $TestDrive 'e2e-evtx-out') -RECmdPath $fakeRECmd
        $id.Status | Should -BeExactly 'NoRegistryHives'
        $id.Hostname | Should -BeNullOrEmpty
        @($id.Users).Count | Should -Be 0
        @($id.Notes | Where-Object { $_ -like 'No SYSTEM, SOFTWARE or SAM hive was found*' }).Count | Should -Be 1
        Should -Invoke Invoke-RECmd -Times 0 -Exactly
    }

    It 'retries a dirty hive with no transaction logs without them, and says so' {
        $root = Join-TestPath $TestDrive 'e2e-dirty' 'HOST03'
        New-HiveCollection -Root $root -Hive @('SYSTEM') | Out-Null
        Mock Invoke-RECmd {
            if ($Argument -notcontains '--nl') {
                return [pscustomobject]@{ ExitCode = 0; Output = @($recmdVersionLine, 'Registry hive is dirty and no transaction logs were found in the same directory! LOGs should have same base name as the hive. Aborting!!') }
            }
            Copy-FixtureOutput -Argument $Argument
            [pscustomobject]@{ ExitCode = 0; Output = @($recmdVersionLine) }
        }
        $id = Get-HostIdentity -Collection 'HOST03' -CollectionRoot $root -OutputRoot (Join-TestPath $TestDrive 'e2e-dirty-out') -RECmdPath $fakeRECmd
        $id.Status | Should -BeExactly 'Partial'
        $id.Hostname | Should -BeExactly 'FAKE-HOST-01'
        $id.Source.Hives['SYSTEM'].NoTransactionLogs | Should -BeTrue
        $id.Source.Hives['SOFTWARE'].Read | Should -BeFalse
        @($id.Notes | Where-Object { $_ -like 'SYSTEM is dirty and has no transaction logs*' }).Count | Should -Be 1
        @($id.Notes | Where-Object { $_ -eq 'No SAM hive was found.' }).Count | Should -Be 1
        Should -Invoke Invoke-RECmd -Times 2 -Exactly
    }

    It 'is Failed when RECmd reads nothing, notes another RECmd version, and still removes its work folder' {
        $root = Join-TestPath $TestDrive 'e2e-fail' 'HOST04'
        New-HiveCollection -Root $root | Out-Null
        $out = Join-TestPath $TestDrive 'e2e-fail-out'
        Mock Invoke-RECmd { [pscustomobject]@{ ExitCode = 1; Output = @('RECmd version 2099.1.0', 'There was an error processing') } }
        $id = Get-HostIdentity -Collection 'HOST04' -CollectionRoot $root -OutputRoot $out -RECmdPath $fakeRECmd
        $id.Status | Should -BeExactly 'Failed'
        $id.Source.RECmdVersion | Should -BeExactly '2099.1.0'
        @($id.Notes | Where-Object { $_ -like "RECmd 2099.1.0 is not the version this tool was tested with, which is $TestedRECmdVersion.*" }).Count | Should -Be 1
        @($id.Notes | Where-Object { $_ -eq 'RECmd read nothing from SAM. It exited with code 1.' }).Count | Should -Be 1
        Get-WorkFolder $out | Should -BeNullOrEmpty
    }

    It 'notes a hive RECmd could not be run on, and carries on with the rest' {
        $root = Join-TestPath $TestDrive 'e2e-throw' 'HOST05'
        New-HiveCollection -Root $root | Out-Null
        $out = Join-TestPath $TestDrive 'e2e-throw-out'
        Mock Invoke-RECmd {
            if ((Get-ArgumentValue $Argument '--csvf') -eq 'SAM.csv') { throw 'Running RECmd requires Windows.' }
            Copy-FixtureOutput -Argument $Argument
            [pscustomobject]@{ ExitCode = 0; Output = @($recmdVersionLine) }
        }
        $id = Get-HostIdentity -Collection 'HOST05' -CollectionRoot $root -OutputRoot $out -RECmdPath $fakeRECmd
        $id.Status | Should -BeExactly 'Partial'
        @($id.Users).Count | Should -Be 0
        @($id.Notes | Where-Object { $_ -eq 'RECmd could not be run on SAM. Running RECmd requires Windows.' }).Count | Should -Be 1
        Get-WorkFolder $out | Should -BeNullOrEmpty
    }

    It 'refuses a RECmd.exe planted in the collection before reading anything' {
        $root = Join-TestPath $TestDrive 'e2e-planted' 'HOST06'
        New-HiveCollection -Root $root | Out-Null
        $planted = Write-TestText -Path (Join-TestPath $root 'RECmd.exe') -Line @('x')
        Mock Invoke-RECmd { throw 'RECmd should not run' }
        Get-ThrownMessage { Get-HostIdentity -Collection 'HOST06' -CollectionRoot $root -OutputRoot (Join-TestPath $TestDrive 'e2e-planted-out') -RECmdPath $planted } | Should -BeLike '*inside the collection*'
        Should -Invoke Invoke-RECmd -Times 0 -Exactly
    }

    It 'runs under strict mode, as the entry scripts run' {
        $root = Join-TestPath $TestDrive 'e2e-strict' 'HOST07'
        New-HiveCollection -Root $root | Out-Null
        Mock Invoke-RECmd {
            Copy-FixtureOutput -Argument $Argument
            [pscustomobject]@{ ExitCode = 0; Output = @($recmdVersionLine) }
        }
        $id = & {
            Set-StrictMode -Version Latest
            Get-HostIdentity -Collection 'HOST07' -CollectionRoot $root -OutputRoot (Join-TestPath $TestDrive 'e2e-strict-out') -RECmdPath $fakeRECmd
        }
        $id.Status | Should -BeExactly 'Complete'
    }
}

Describe 'Save-HostIdentity' {
    It 'writes HOST01_identity.json in the host folder, without a BOM, and replaces it whole' {
        $out = Join-TestPath $TestDrive 'save-out'
        $id = [ordered]@{ SchemaVersion = $HostIdentitySchemaVersion; Collection = 'HOST01'; Status = 'Complete'; Hostname = 'FAKE-HOST-01'; Users = @(); Interfaces = @([ordered]@{ Guid = '{X}'; NameServer = [string[]]@('192.0.2.1') }) }
        $path = Save-HostIdentity -OutputRoot $out -Identity $id
        $path | Should -Be (Join-TestPath $out 'HOST01' 'HOST01_identity.json')
        Test-Utf8Bom -Path $path | Should -BeFalse
        $read = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $read.SchemaVersion | Should -Be $HostIdentitySchemaVersion
        $read.Hostname | Should -BeExactly 'FAKE-HOST-01'
        @($read.Interfaces[0].NameServer) | Should -Be @('192.0.2.1')

        $id.Hostname = 'FAKE-HOST-02'
        Save-HostIdentity -OutputRoot $out -Identity $id | Out-Null
        (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).Hostname | Should -BeExactly 'FAKE-HOST-02'
        @(Get-ChildItem -LiteralPath (Join-TestPath $out 'HOST01') -Filter '*.tmp').Count | Should -Be 0
    }

    It 'saves the whole identity a run returns, deep values included' {
        $root = Join-TestPath $TestDrive 'save-e2e' 'HOST01'
        New-HiveCollection -Root $root | Out-Null
        $out = Join-TestPath $TestDrive 'save-e2e-out'
        Mock Invoke-RECmd {
            Copy-FixtureOutput -Argument $Argument
            [pscustomobject]@{ ExitCode = 0; Output = @("RECmd version $TestedRECmdVersion") }
        }
        $path = Save-HostIdentity -OutputRoot $out -Identity (Get-HostIdentity -Collection 'HOST01' -CollectionRoot $root -OutputRoot $out -RECmdPath $fakeRECmd)
        $read = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        @($read.Users | Where-Object { $_.UserName -eq 'alice.fake' })[0].Flags.NormalUserAccount | Should -BeTrue
        @($read.Interfaces)[0].NetworkName | Should -BeExactly 'FAKE-WIFI'
        $read.TimeZone.ActiveUtcOffset | Should -BeExactly '+11:00'
        $raw = Get-Content -LiteralPath $path -Raw
        $raw | Should -Not -Match 'FAKE-HINT-DROP-ME'
        $raw | Should -Not -Match 'FAKE-ANSWER-DROP-ME'
    }
}

Describe 'Tested RECmd version in the docs' {
    It 'matches the tested version between every tested-recmd-version marker in docs/USAGE.md' {
        $text = [System.IO.File]::ReadAllText((Join-Path -Path $script:RepoRoot -ChildPath 'docs/USAGE.md'))
        $values = @([regex]::Matches($text, '<!--tested-recmd-version-->(.*?)<!--/tested-recmd-version-->') | ForEach-Object { $_.Groups[1].Value })
        $values.Count | Should -BeGreaterThan 0
        ([regex]::Matches($text, '<!--tested-recmd-version-->')).Count | Should -Be $values.Count -Because 'every marker is closed'
        ([regex]::Matches($text, '<!--/tested-recmd-version-->')).Count | Should -Be $values.Count -Because 'every marker is opened'
        foreach ($v in $values) {
            $v | Should -BeExactly $TestedRECmdVersion
        }
    }
}

Describe 'Against a real RECmd' -Tag 'Compatibility' -Skip:(-not $canRunRECmd) {
    BeforeAll {
        $script:recmd = $env:RECMD_COMPAT_PATH
        $lan = '{a1a1a1a1-0000-4000-8000-00000000000a}'
        $static = '{b2b2b2b2-0000-4000-8000-00000000000b}'
        $ifaces = 'ControlSet002\Services\Tcpip\Parameters\Interfaces'
        $hintLan = ConvertTo-HintValue 'FAKE-LAN'
        $systemKeys = [ordered]@{
            'Select'                                           = [ordered]@{ Current = 2; Default = 2; LastKnownGood = 1 }
            'ControlSet001\Control\ComputerName\ComputerName'  = [ordered]@{ ComputerName = 'OLD-HOST-00' }
            'ControlSet002\Control\ComputerName\ComputerName'  = [ordered]@{ ComputerName = 'FAKE-HOST-01' }
            'ControlSet002\Control\TimeZoneInformation'        = [ordered]@{ TimeZoneKeyName = 'Fake Standard Time'; StandardName = 'Fake Standard'; DaylightName = 'Fake Daylight'; Bias = -600; ActiveTimeBias = -660 }
            'ControlSet002\Services\Tcpip\Parameters'          = [ordered]@{ Domain = 'corp.example'; 'NV Domain' = 'corp.example' }
            "$ifaces\$lan"                                     = [ordered]@{ EnableDHCP = 1; DhcpIPAddress = '192.0.2.50'; DhcpSubnetMask = '255.255.255.0'; DhcpServer = '192.0.2.1'; DhcpDefaultGateway = [string[]]@('192.0.2.1'); DhcpNameServer = '192.0.2.1'; LeaseObtainedTime = 1788000000; LeaseTerminatesTime = 1788086400; DhcpNetworkHint = $hintLan }
            "$ifaces\$lan\$hintLan"                            = [ordered]@{ DhcpIPAddress = '192.0.2.50'; DhcpNetworkHint = $hintLan; LeaseObtainedTime = 1788000000; LeaseTerminatesTime = 1788086400 }
            "$ifaces\$static"                                  = [ordered]@{ EnableDHCP = 0; IPAddress = [string[]]@('203.0.113.7'); SubnetMask = [string[]]@('255.255.255.0'); DefaultGateway = [string[]]@('203.0.113.1'); NameServer = '203.0.113.53' }
        }
        $softwareKeys = [ordered]@{
            'Microsoft\Windows NT\CurrentVersion'          = [ordered]@{ ProductName = 'Windows 10 Pro'; EditionID = 'Professional'; DisplayVersion = '23H2'; CurrentBuild = '22631'; InstallDate = 1704067200; RegisteredOwner = 'Fake Owner'; RegisteredOrganization = 'Example Org' }
            'Microsoft\Windows NT\CurrentVersion\Winlogon' = [ordered]@{ DefaultDomainName = 'FAKECORP'; CachePrimaryDomain = 'FAKECORP' }
        }

        $script:compatRoot = Join-TestPath $TestDrive 'compat' 'HOST01'
        $config = New-TestDirectory (Join-TestPath $compatRoot 'C' 'Windows' 'System32' 'config')
        New-TestRegistryHive -Path (Join-TestPath $config 'SYSTEM') -HiveName 'SYSTEM' -Keys $systemKeys | Out-Null
        New-TestRegistryHive -Path (Join-TestPath $config 'SOFTWARE') -HiveName 'SOFTWARE' -Keys $softwareKeys | Out-Null
        $script:compatBefore = Get-FileHashMap -Path $compatRoot

        # RECmd's own output for each hive, for the column checks.
        $script:rawOut = New-TestDirectory (Join-TestPath $TestDrive 'compat-raw' 'out')
        foreach ($h in @('SYSTEM', 'SOFTWARE')) {
            $copy = Join-TestPath $TestDrive 'compat-raw' 'hives' $h $h
            New-TestDirectory (Split-Path -Parent $copy) | Out-Null
            Copy-Item -LiteralPath (Join-TestPath $config $h) -Destination $copy
            $run = Invoke-RECmdHive -RECmdPath $recmd -HivePath $copy -Name $h -OutputDirectory $rawOut
            if (-not $run.Produced) { throw "RECmd wrote no CSV for $h. Output: $($run.Output -join ' / ')" }
        }

        $script:compatOut = Join-TestPath $TestDrive 'compat-out'
        $script:compatId = Get-HostIdentity -Collection 'HOST01' -CollectionRoot $compatRoot -OutputRoot $compatOut -RECmdPath $recmd
    }

    It 'writes every main CSV column the parser reads' {
        foreach ($h in @('SYSTEM', 'SOFTWARE')) {
            $header = @(Get-CsvHeader -Path (Join-TestPath $rawOut "$h.csv"))
            foreach ($c in $RECmdMainColumns) { $header | Should -Contain $c -Because "$h.csv" }
        }
    }

    It 'writes every <Plugin> column the parser reads' -ForEach @(
        @{ Plugin = 'NetworkSettings' }
        @{ Plugin = 'DHCPNetworkHint' }
    ) {
        $files = @(Find-RECmdDetailCsv -OutputDirectory $rawOut -Hive 'SYSTEM' -Plugin $Plugin)
        $files.Count | Should -Be 1
        $header = @(Get-CsvHeader -Path $files[0])
        foreach ($c in $RECmdPluginColumns[$Plugin]) { $header | Should -Contain $c }
    }

    It 'reads the planted host name from the active control set' {
        $compatId.ControlSet | Should -BeExactly 'ControlSet002'
        $compatId.Hostname | Should -BeExactly 'FAKE-HOST-01'
    }

    It 'reads the planted OS, time zone, domain and interfaces' {
        $compatId.Os.ProductName | Should -BeExactly 'Windows 10 Pro'
        $compatId.Os.Build | Should -BeExactly '22631'
        $compatId.Os.InstallDateUtc | Should -BeExactly '2024-01-01T00:00:00Z'
        $compatId.TimeZone.KeyName | Should -BeExactly 'Fake Standard Time'
        $compatId.TimeZone.BiasMinutes | Should -Be -600
        $compatId.TimeZone.ActiveUtcOffset | Should -BeExactly '+11:00'
        $compatId.Domain.DnsDomain | Should -BeExactly 'corp.example'
        $compatId.Domain.CachePrimaryDomain | Should -BeExactly 'FAKECORP'
        @($compatId.Interfaces | ForEach-Object { $_.Address }) | Should -Be @('192.0.2.50', '203.0.113.7')
        @($compatId.Interfaces)[0].LikelyActive | Should -BeTrue
        @($compatId.Interfaces)[0].NetworkName | Should -BeExactly 'FAKE-LAN'
        @($compatId.Interfaces)[0].LeaseObtainedUtc | Should -BeExactly '2026-08-29T10:40:00Z'
        @(@($compatId.Interfaces)[1].DefaultGateway) | Should -Be @('203.0.113.1')
    }

    It 'reports its version, is Partial without a SAM, and leaves the hives as they were' {
        $compatId.Source.RECmdVersion | Should -Match '^\d+\.\d+\.\d+$'
        $compatId.Status | Should -BeExactly 'Partial'
        $after = Get-FileHashMap -Path $compatRoot
        $after.Count | Should -Be $compatBefore.Count
        foreach ($k in $compatBefore.Keys) { $after[$k] | Should -BeExactly $compatBefore[$k] }
        @(Get-ChildItem -LiteralPath (Join-TestPath $compatOut '_work') -Directory -ErrorAction SilentlyContinue).Count | Should -Be 0
    }
}
