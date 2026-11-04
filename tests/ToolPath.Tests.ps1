# Where the tools and rules really live, lib\ToolPath.ps1. Folder links are
# junctions on Windows, which need no privilege, and symbolic links
# elsewhere. Tests that need a Windows-only alias, a subst drive or a mapped
# network drive, run on the Windows CI legs and are skipped elsewhere.

BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers/TestHelpers.ps1')
    $script:base = New-TestDirectory (Join-TestPath $TestDrive 'paths')
    $script:in = New-TestDirectory (Join-TestPath $base 'KAPE')
    $script:outRoot = Join-TestPath $base 'Output'
    $script:tools = New-TestDirectory (Join-TestPath $base 'Tools')

    function script:New-DirLink([string]$Path, [string]$Target) {
        # Returns $null when the link is made, or why not.
        $type = 'SymbolicLink'
        if ($TestOnWindows) { $type = 'Junction' }
        try {
            New-Item -ItemType $type -Path $Path -Target $Target -ErrorAction Stop | Out-Null
            return $null
        }
        catch {
            return "this session can't create a $type`: $($_.Exception.Message)"
        }
    }

    function script:Get-Refusal([string]$Name, [string]$Path, [string]$Use = 'Run') {
        return (Get-ThrownMessage { Assert-ToolPathAllowed -Name $Name -Path $Path -InputRoot $in -OutputRoot $outRoot -Use $Use })
    }
}

Describe 'Resolve-FinalPath' {
    It 'leaves a path with no links as it is' {
        $f = Write-TestText -Path (Join-TestPath $tools 'plain' 'hayabusa.exe') -Line @('x')
        Resolve-FinalPath -Path $f | Should -Be $f
    }

    It 'keeps the part of a path that doesn''t exist yet' {
        $p = Join-TestPath $tools 'not' 'there' 'yet.exe'
        Resolve-FinalPath -Path $p | Should -Be $p
    }

    It 'follows a folder link to where it really leads' {
        $real = New-TestDirectory (Join-TestPath $in 'WS02' 'Users' 'Public')
        Write-TestText -Path (Join-TestPath $real 'RECmd.exe') -Line @('x') | Out-Null
        $link = Join-TestPath $tools 'looks-local'
        $skip = New-DirLink $link (Join-TestPath $in 'WS02')
        if ($null -ne $skip) { Set-ItResult -Skipped -Because $skip; return }
        Resolve-FinalPath -Path (Join-TestPath $link 'Users' 'Public' 'RECmd.exe') | Should -Be (Join-TestPath $real 'RECmd.exe')
    }

    It 'follows a link whose target is relative, and a chain of links' {
        $real = New-TestDirectory (Join-TestPath $base 'chain-real')
        $one = Join-TestPath $base 'chain-one'
        $two = Join-TestPath $base 'chain-two'
        try {
            New-Item -ItemType SymbolicLink -Path $one -Target 'chain-real' -ErrorAction Stop | Out-Null
            New-Item -ItemType SymbolicLink -Path $two -Target $one -ErrorAction Stop | Out-Null
        }
        catch {
            Set-ItResult -Skipped -Because "this session can't create a symbolic link: $($_.Exception.Message)"
            return
        }
        Resolve-FinalPath -Path (Join-TestPath $two 'x.exe') | Should -Be (Join-TestPath $real 'x.exe')
    }

    It 'gives up on links that loop' {
        if ($TestOnWindows) { Set-ItResult -Skipped -Because 'a handle gives the final path on Windows, and a looping link has none to open'; return }
        $a = Join-TestPath $base 'loop-a'
        $b = Join-TestPath $base 'loop-b'
        try {
            New-Item -ItemType SymbolicLink -Path $a -Target $b -ErrorAction Stop | Out-Null
            New-Item -ItemType SymbolicLink -Path $b -Target $a -ErrorAction Stop | Out-Null
        }
        catch {
            Set-ItResult -Skipped -Because "this session can't create a symbolic link: $($_.Exception.Message)"
            return
        }
        Get-ThrownMessage { Resolve-FinalPathByWalk -Path (Join-TestPath $a 'x.exe') } | Should -BeLike '*goes through more than 40 links, so it may loop.'
    }
}

Describe 'Test-PathOnNetworkShare' {
    It 'calls <Path> a network share' -ForEach @(
        @{ Path = '\\server\share\Tools\RECmd.exe' }
        @{ Path = '\\?\UNC\server\share\Tools\RECmd.exe' }
        @{ Path = '\\server@SSL\DavWWWRoot\RECmd.exe' }
        @{ Path = '//server/share/RECmd.exe' }
    ) {
        Test-PathOnNetworkShare -Path $Path | Should -BeTrue
    }

    It 'doesn''t call a local path one' {
        Test-PathOnNetworkShare -Path (Join-TestPath $tools 'hayabusa.exe') | Should -BeFalse
        Test-PathOnNetworkShare -Path '\\?\C:\Tools\hayabusa.exe' | Should -BeFalse -Because 'a \\?\ prefix on a local drive is still local, unless that drive is mapped'
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
        Get-Refusal 'HayabusaPath' $f | Should -BeLike "HayabusaPath $f is inside OutputRoot, so the tool won't run it.*"
    }

    It 'refuses rules inside InputRoot, saying it won''t load them' {
        $r = New-TestDirectory (Join-TestPath $in 'WS03' 'rules')
        Get-Refusal 'RulesPath' $r 'Load' | Should -BeExactly "RulesPath $r is inside InputRoot, so the tool won't load rules from it. Keep the tools and rules outside the evidence and the output."
    }

    It 'refuses a tool that only looks local, through a folder link into InputRoot' {
        New-TestDirectory (Join-TestPath $in 'WS04') | Out-Null
        Write-TestText -Path (Join-TestPath $in 'WS04' 'RECmd.exe') -Line @('x') | Out-Null
        $link = Join-TestPath $tools 'RECmd'
        $skip = New-DirLink $link (Join-TestPath $in 'WS04')
        if ($null -ne $skip) { Set-ItResult -Skipped -Because $skip; return }
        $p = Join-TestPath $link 'RECmd.exe'
        Get-Refusal 'RECmdPath' $p | Should -BeLike "RECmdPath $p is inside InputRoot, through a link to *WS04*RECmd.exe, so the tool won't run it.*"
    }

    It 'refuses a tool on a network share, written as <Kind>' -ForEach @(
        @{ Kind = 'a UNC path'; Path = '\\server\share\Tools\RECmd.exe' }
        @{ Kind = 'a \\?\UNC\ path'; Path = '\\?\UNC\server\share\Tools\RECmd.exe' }
    ) {
        Get-Refusal 'RECmdPath' $Path | Should -BeExactly "RECmdPath $Path is on a network share, so the tool won't run it. Copy it to a local drive and point RECmdPath there."
    }
}

Describe 'Aliases only Windows has' -Skip:(-not $TestOnWindows) {
    It 'refuses a tool reached through a subst drive that maps into InputRoot' {
        Write-TestText -Path (Join-TestPath $in 'WS05' 'hayabusa.exe') -Line @('x') | Out-Null
        $letter = @('Q', 'R', 'S', 'T', 'U', 'V', 'W') | Where-Object { -not (Test-Path -LiteralPath "$($_):\") } | Select-Object -First 1
        if ($null -eq $letter) { Set-ItResult -Skipped -Because 'no free drive letter for subst'; return }
        & subst.exe "$($letter):" (Join-TestPath $in 'WS05') | Out-Null
        try {
            if (-not (Test-Path -LiteralPath "$($letter):\hayabusa.exe")) { Set-ItResult -Skipped -Because 'subst did not map the drive'; return }
            Get-Refusal 'HayabusaPath' "$($letter):\hayabusa.exe" | Should -BeLike "HayabusaPath $($letter):\hayabusa.exe is inside InputRoot, through a link to *WS05\hayabusa.exe*"
        }
        finally {
            & subst.exe "$($letter):" /D | Out-Null
        }
    }

    It 'refuses a tool on a mapped network drive' {
        $letter = @('M', 'N', 'O', 'P') | Where-Object { -not (Test-Path -LiteralPath "$($_):\") } | Select-Object -First 1
        if ($null -eq $letter) { Set-ItResult -Skipped -Because 'no free drive letter to map'; return }
        $share = '\\localhost\' + $env:SystemDrive.Substring(0, 1) + '$'
        $mapped = & net.exe use "$($letter):" $share 2>&1
        if ($LASTEXITCODE -ne 0) { Set-ItResult -Skipped -Because "this session can't map $share`: $($mapped -join ' ')"; return }
        try {
            $p = "$($letter):\Windows\System32\cmd.exe"
            Get-Refusal 'HayabusaPath' $p | Should -BeLike "HayabusaPath $p is on a network share*"
        }
        finally {
            & net.exe use "$($letter):" /delete /y 2>&1 | Out-Null
        }
    }
}

Describe 'Get-ToolFileSha256' {
    It 'gives the same SHA-256 as Get-FileHash, and null for no tool' {
        $f = Write-TestText -Path (Join-TestPath $tools 'hash' 'RECmd.exe') -Line @('some bytes')
        Get-ToolFileSha256 -Path $f | Should -Be (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash
        Get-ToolFileSha256 -Path $null | Should -BeNullOrEmpty
    }
}
