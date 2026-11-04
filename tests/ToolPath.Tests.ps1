# Where the tools and rules may be, lib\ToolPath.ps1.

BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers/TestHelpers.ps1')
    $script:base = New-TestDirectory (Join-TestPath $TestDrive 'paths')
    $script:in = New-TestDirectory (Join-TestPath $base 'KAPE')
    $script:outRoot = Join-TestPath $base 'Output'
    $script:tools = New-TestDirectory (Join-TestPath $base 'Tools')

    function script:Get-Refusal([string]$Name, [string]$Path, [string]$Use = 'Run') {
        return (Get-ThrownMessage { Assert-ToolPathAllowed -Name $Name -Path $Path -InputRoot $in -OutputRoot $outRoot -Use $Use })
    }
}

Describe 'Test-PathIsUnc' {
    It 'calls <Path> a UNC path' -ForEach @(
        @{ Path = '\\server\share\Tools\RECmd.exe' }
        @{ Path = '\\?\UNC\server\share\Tools\RECmd.exe' }
        @{ Path = '\\.\UNC\server\share\Tools\RECmd.exe' }
        @{ Path = '//server/share/RECmd.exe' }
    ) {
        Test-PathIsUnc -Path $Path | Should -BeTrue
    }

    It 'doesn''t call a local path one' {
        Test-PathIsUnc -Path (Join-TestPath $tools 'hayabusa.exe') | Should -BeFalse
        Test-PathIsUnc -Path 'D:\Tools\hayabusa.exe' | Should -BeFalse
        Test-PathIsUnc -Path '\\?\D:\Tools\hayabusa.exe' | Should -BeFalse
    }
}

Describe 'Assert-ToolPathAllowed' {
    It 'accepts a tool outside the evidence and the output' {
        $f = Write-TestText -Path (Join-TestPath $tools 'ok' 'hayabusa.exe') -Line @('x')
        Get-Refusal 'HayabusaPath' $f | Should -BeNullOrEmpty
    }

    It 'refuses a tool inside InputRoot' {
        $f = Write-TestText -Path (Join-TestPath $in 'WS02' 'RECmd.exe') -Line @('x')
        Get-Refusal 'RECmdPath' $f | Should -BeExactly "RECmdPath $f is inside InputRoot, so the tool won't run it. Keep the tools and rules outside the evidence and the output."
    }

    It 'refuses a tool inside an OutputRoot that doesn''t exist yet' {
        $f = Join-TestPath $outRoot 'bin' 'hayabusa.exe'
        Get-Refusal 'HayabusaPath' $f | Should -BeExactly "HayabusaPath $f is inside OutputRoot, so the tool won't run it. Keep the tools and rules outside the evidence and the output."
    }

    It 'refuses rules inside InputRoot, saying it won''t load them' {
        $r = New-TestDirectory (Join-TestPath $in 'WS03' 'rules')
        Get-Refusal 'RulesPath' $r 'Load' | Should -BeExactly "RulesPath $r is inside InputRoot, so the tool won't load rules from it. Keep the tools and rules outside the evidence and the output."
    }

    It 'judges a path by its normalised form, so a .. can''t carry it out of InputRoot''s reach' {
        New-TestDirectory (Join-TestPath $in 'WS04') | Out-Null
        $f = Write-TestText -Path (Join-TestPath $in 'WS04' 'RECmd.exe') -Line @('x')
        $p = Join-TestPath $tools '..' 'KAPE' 'WS04' 'RECmd.exe'
        Get-Refusal 'RECmdPath' $p | Should -BeLike "RECmdPath $p is inside InputRoot*"
        Test-Path -LiteralPath $f | Should -BeTrue
    }

    It 'refuses a tool on a network share, written as <Kind>' -ForEach @(
        @{ Kind = 'a UNC path'; Path = '\\server\share\Tools\RECmd.exe' }
        @{ Kind = 'a \\?\UNC\ path'; Path = '\\?\UNC\server\share\Tools\RECmd.exe' }
    ) {
        Get-Refusal 'RECmdPath' $Path | Should -BeExactly "RECmdPath $Path is on a network share, so the tool won't run it. Copy it to a local drive and point RECmdPath there."
    }
}

Describe 'Get-ToolFileSha256' {
    It 'gives the same SHA-256 as Get-FileHash, and null for no tool' {
        $f = Write-TestText -Path (Join-TestPath $tools 'hash' 'RECmd.exe') -Line @('some bytes')
        Get-ToolFileSha256 -Path $f | Should -Be (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash
        Get-ToolFileSha256 -Path $null | Should -BeNullOrEmpty
    }
}
