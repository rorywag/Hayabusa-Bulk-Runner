BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers/TestHelpers.ps1')

    $script:tool = New-TestDirectory (Join-TestPath $TestDrive 'tool')
    New-TestDirectory (Join-TestPath $tool 'rules') | Out-Null
    $script:hb = Join-TestPath $tool 'hayabusa.exe'
    Write-TestText -Path $hb -Line @('not a binary') | Out-Null
    $script:cfgDir = New-TestDirectory (Join-TestPath $TestDrive 'cfg')
    New-TestDirectory (Join-TestPath $cfgDir 'myrules') | Out-Null

    function script:Cfg([string]$Name, [string]$Body) {
        Write-TestText -Path (Join-TestPath $cfgDir $Name) -Line @($Body)
    }
    function script:Resolve-With([string]$Body, [hashtable]$CommandLine = @{}) {
        $c = Import-EngagementConfig -Path (Cfg ("c{0}.psd1" -f [guid]::NewGuid().ToString('N')) $Body)
        Resolve-RunSetting -CommandLine $CommandLine -Config $c -HayabusaPath $hb
    }
}

Describe 'Resolve-RunSetting defaults' {
    It 'uses high, standard, the rules folder beside the binary and the ZIP limits' {
        $r = Resolve-RunSetting -CommandLine @{} -Config $null -HayabusaPath $hb
        $r.Selection.MinLevel | Should -Be 'high'
        $r.Selection.ExactLevel | Should -BeNullOrEmpty
        $r.Selection.Profile | Should -Be 'standard'
        $r.Selection.RulesPath | Should -Be (Join-TestPath $tool 'rules')
        $r.Limits.ZipMaxUncompressedGB | Should -Be 100
        $r.Limits.ZipMaxRatio | Should -Be 250
        $r.Sources.MinLevel | Should -Be 'Default'
    }

    It 'warns but does not fail when the default rules folder is missing' {
        $t2 = New-TestDirectory (Join-TestPath $TestDrive 'tool2')
        $hb2 = Write-TestText -Path (Join-TestPath $t2 'hayabusa.exe') -Line @('x')
        $w = $null
        Resolve-RunSetting -CommandLine @{} -Config $null -HayabusaPath $hb2 -WarningVariable w -WarningAction SilentlyContinue | Out-Null
        @($w | Where-Object { "$_" -like '*update-rules*' }).Count | Should -Be 1
    }
}

Describe 'Engagement config' {
    It 'ExactLevel replaces MinLevel and a relative RulesPath resolves to the config folder' {
        $r = Resolve-With "@{ ExactLevel = 'Critical'; RulesPath = 'myrules'; IncludeTags = 'attack.credential_access'; TimelineStart = '2026-01-01 00:00:00 +00:00'; TimelineEnd = '2026-01-31 23:59:59 +00:00'; Profile = 'Verbose' }"
        $r.Selection.ExactLevel | Should -Be 'critical'
        $r.Selection.MinLevel | Should -BeNullOrEmpty
        $r.Sources.MinLevel | Should -Be 'NotUsed'
        $r.Selection.RulesPath | Should -Be (Join-TestPath $cfgDir 'myrules')
        @($r.Selection.IncludeTags) | Should -Be @('attack.credential_access')
        $r.Selection.Profile | Should -Be 'verbose'
        $r.Selection.TimelineEnd | Should -Be '2026-01-31 23:59:59 +00:00'
    }

    It 'records the config hash' {
        $p = Cfg 'h.psd1' "@{ MinLevel = 'low' }"
        (Import-EngagementConfig -Path $p).Sha256 | Should -Be (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash
    }

    It 'command line MinLevel overrides config ExactLevel' {
        $r = Resolve-With "@{ ExactLevel = 'critical' }" @{ MinLevel = 'medium' }
        $r.Selection.MinLevel | Should -Be 'medium'
        $r.Selection.ExactLevel | Should -BeNullOrEmpty
        $r.Sources.ExactLevel | Should -Be 'OverriddenByCommandLine'
    }

    It 'rejects a config that sets both levels' {
        Get-ThrownMessage { Resolve-With "@{ MinLevel='high'; ExactLevel='low' }" } | Should -BeLike '*both MinLevel and ExactLevel*'
    }

    It 'rejects unknown keys' {
        Get-ThrownMessage { Import-EngagementConfig -Path (Cfg 'typo.psd1' "@{ IncludeTag = @('x') }") } | Should -BeLike '*unknown key*IncludeTag*'
    }

    It 'never runs code from the config file' {
        $marker = Join-TestPath $TestDrive 'pwned.txt'
        $p = Cfg 'code.psd1' "@{ MinLevel = `$(Set-Content '$marker' 'x'; 'high') }"
        Get-ThrownMessage { Import-EngagementConfig -Path $p } | Should -BeLike '*could not be read as data*'
        Test-Path -LiteralPath $marker | Should -BeFalse
    }

    It 'rejects <Name>' -ForEach @(
        @{ Name = 'a bad level'; Body = "@{ MinLevel='severe' }"; Like = "*MinLevel 'severe' is not valid*" }
        @{ Name = 'a bad profile'; Body = "@{ Profile='super-verbose' }"; Like = '*Profile*not valid*' }
        @{ Name = 'a bad timeline format'; Body = "@{ TimelineStart='2026-01-01' }"; Like = '*TimelineStart*not valid*' }
        @{ Name = 'a reversed time window'; Body = "@{ TimelineStart='2026-02-01 00:00:00 +00:00'; TimelineEnd='2026-01-01 00:00:00 +00:00' }"; Like = '*must be earlier*' }
        @{ Name = 'a tag in both lists'; Body = "@{ IncludeTags=@('a'); ExcludeTags=@('a') }"; Like = '*both IncludeTags and ExcludeTags*' }
        @{ Name = 'a missing RulesPath'; Body = "@{ RulesPath='nope' }"; Like = '*RulesPath not found*' }
        @{ Name = 'ZipMaxUncompressedGB of 0'; Body = '@{ ZipMaxUncompressedGB = 0 }'; Like = '*is not valid. Use a number*' }
        @{ Name = 'a non-numeric ZipMaxUncompressedGB'; Body = "@{ ZipMaxUncompressedGB = 'lots' }"; Like = '*is not valid. Use a number*' }
        @{ Name = 'ZipMaxRatio below 1'; Body = '@{ ZipMaxRatio = 0.5 }'; Like = '*is not valid. Use a number*' }
        @{ Name = 'a negative ZipMaxRatio'; Body = '@{ ZipMaxRatio = -1 }'; Like = '*is not valid. Use a number*' }
    ) {
        Get-ThrownMessage { Resolve-With $Body } | Should -BeLike $Like
    }

    It 'records ZIP limits from the config and their source' {
        $r = Resolve-With '@{ ZipMaxUncompressedGB = 2.5; ZipMaxRatio = 400 }'
        $r.Limits.ZipMaxUncompressedGB | Should -Be 2.5
        $r.Limits.ZipMaxUncompressedBytes | Should -Be ([long](2.5 * 1GB))
        $r.Limits.ZipMaxRatio | Should -Be 400
        $r.Sources.ZipMaxRatio | Should -Be 'Config'
    }
}

Describe 'Emergency level in settings' {
    It 'accepts emergency as MinLevel and ExactLevel' {
        (Resolve-RunSetting -CommandLine @{ MinLevel = 'emergency' } -Config $null -HayabusaPath $hb).Selection.MinLevel | Should -Be 'emergency'
        $r = Resolve-With "@{ ExactLevel = 'Emergency' }"
        $r.Selection.ExactLevel | Should -Be 'emergency'
        $r.Selection.MinLevel | Should -BeNullOrEmpty
    }

    It 'the main script -MinLevel accepts emergency' {
        $p = (Get-Command $MainScript).Parameters['MinLevel']
        ($p.Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }).ValidValues | Should -Contain 'emergency'
    }
}
