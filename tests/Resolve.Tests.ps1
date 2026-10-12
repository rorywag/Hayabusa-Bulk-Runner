BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers/TestHelpers.ps1')
    $script:cap = [long]1GB
    $script:in = New-TestDirectory (Join-TestPath $TestDrive 'in')
    New-TestDirectory (Join-TestPath $in 'HOST01' 'C' 'Windows' 'System32' 'winevt' 'Logs') | Out-Null
    New-TestZip -Path (Join-TestPath $in 'PLAIN.zip') -Entries ([ordered]@{ 'C/Windows/System32/winevt/Logs/Security.evtx' = (New-TestByteArray 100 -Random) }) | Out-Null
    New-TestZip -Path (Join-TestPath $in 'TWO_IMG.zip') -Entries ([ordered]@{ 'a.vhdx' = (New-TestByteArray 10); 'b.VHD' = (New-TestByteArray 10) }) | Out-Null
    New-TestZip -Path (Join-TestPath $in 'NESTED.zip') -Entries ([ordered]@{ 'inner/more.zip' = (New-TestByteArray 10); 'x.evtx' = (New-TestByteArray 10 -Random) }) | Out-Null
    [System.IO.File]::WriteAllBytes((Join-TestPath $in 'CORRUPT.zip'), (New-TestByteArray 500 -Random))
    $d64 = New-TestZip -Path (Join-TestPath $in 'D64.zip') -Entries ([ordered]@{ 'x.evtx' = (New-TestByteArray 10 -Random) })
    Edit-ZipHeader -Path $d64 -Method 9
    $script:cols = @{}
    Get-InputCollection -InputRoot $in -WarningAction SilentlyContinue | ForEach-Object { $cols[$_.Collection] = $_ }
    $script:out = New-TestDirectory (Join-TestPath $TestDrive 'out')
    function script:Resolve-Test($c, [switch]$Keep) { Resolve-CollectionInput -Collection $c -OutputRoot $out -MaxUncompressedBytes $cap -MaxRatio 250 -KeepArtifacts:$Keep }
}

Describe 'Resolving loose folders and zips' {
    It 'uses a Loose folder as is, with nothing to tear down' {
        $r = Resolve-Test $cols.HOST01
        Invoke-CollectionCleanup -Resolved $r
        $r.Path | Should -Be $cols.HOST01.SourcePath
        $r.Teardown.Count | Should -Be 0
        Test-Path -LiteralPath $cols.HOST01.SourcePath | Should -BeTrue
    }
    It 'extracts a zip without an image and cleanup removes the extract' {
        $r = Resolve-Test $cols.PLAIN
        $r.Path | Should -Be (Join-TestPath $out '_work' 'PLAIN')
        Test-Path -LiteralPath (Join-TestPath $r.Path 'C' 'Windows' 'System32' 'winevt' 'Logs' 'Security.evtx') | Should -BeTrue
        $r.ImagePath | Should -BeNullOrEmpty
        Invoke-CollectionCleanup -Resolved $r
        Test-Path -LiteralPath $r.Path | Should -BeFalse
    }
    It 'keeps the extract with -KeepArtifacts' {
        $r = Resolve-Test $cols.PLAIN -Keep
        Invoke-CollectionCleanup -Resolved $r
        Test-Path -LiteralPath (Join-TestPath $r.Path 'C') | Should -BeTrue
    }
    It 'replaces a stale extract' {
        Write-TestText -Path (Join-TestPath $out '_work' 'PLAIN' 'marker.txt') -Line @('stale') | Out-Null
        $r = Resolve-Test $cols.PLAIN
        Test-Path -LiteralPath (Join-TestPath $r.Path 'marker.txt') | Should -BeFalse
        Test-Path -LiteralPath (Join-TestPath $r.Path 'C') | Should -BeTrue
        Invoke-CollectionCleanup -Resolved $r
    }
    It 'is safe to clean up twice, or with nothing resolved' {
        $r = Resolve-Test $cols.PLAIN
        Invoke-CollectionCleanup -Resolved $r
        { Invoke-CollectionCleanup -Resolved $r; Invoke-CollectionCleanup -Resolved $null } | Should -Not -Throw
        Test-Path -LiteralPath $r.Path | Should -BeFalse
    }
    It 'warns about a nested zip inside the extract' {
        $r = Resolve-Test $cols.NESTED
        @($r.Warnings | Where-Object { $_ -like 'Nested ZIP(s) not opened*' }).Count | Should -Be 1
        Invoke-CollectionCleanup -Resolved $r
    }
    It 'fails a zip holding two images and cleans up' {
        Get-ThrownMessage { Resolve-Test $cols.TWO_IMG } | Should -BeLike '*2 disk images*Only one*'
        Test-Path -LiteralPath (Join-TestPath $out '_work' 'TWO_IMG') | Should -BeFalse
    }
    It 'refuses an unreadable zip with guidance, before extracting anything' -ForEach @(@{ Name = 'CORRUPT' }, @{ Name = 'D64' }) {
        $m = Get-ThrownMessage { Resolve-Test $cols[$Name] }
        $m | Should -BeLike "$Name.zip can't be extracted by this tool*Extract it yourself*"
        $m | Should -Not -BeLike '*unsupported compression method*'
        Test-Path -LiteralPath (Join-TestPath $out '_work' $Name) | Should -BeFalse
    }
}

Describe 'Removal guards' {
    It 'removes extracts only strictly inside _work' {
        $wr = New-TestDirectory (Join-TestPath $out '_work')
        Get-ThrownMessage { Remove-CollectionExtract -Path $TestDrive -WorkRoot $wr } | Should -BeLike '*not a folder under*'
        Get-ThrownMessage { Remove-CollectionExtract -Path $wr -WorkRoot $wr } | Should -BeLike '*not a folder under*'
    }
    It 'never removes a mount folder recursively' {
        $mr = New-TestDirectory (Join-TestPath $out '_mnt')
        $busy = New-TestDirectory (Join-TestPath $mr 'BUSY')
        Write-TestText -Path (Join-TestPath $busy 'f') -Line @('x') | Out-Null
        { Remove-MountFolder -Path $busy -MountRoot $mr } | Should -Throw
        Test-Path -LiteralPath (Join-TestPath $busy 'f') | Should -BeTrue
    }
}
