# The evidence image format check, lib\ImageFormat.ps1. Every image is
# synthetic and built by tests\Helpers\ImageHelpers.ps1, then damaged one
# field at a time.

BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers/TestHelpers.ps1')
    . (Join-Path $PSScriptRoot 'Helpers/ImageHelpers.ps1')
    $script:img = New-TestDirectory (Join-TestPath $TestDrive 'img')

    function script:Save([string]$Name, [byte[]]$Bytes) {
        return (Write-TestImage -Path (Join-TestPath $img $Name) -Bytes $Bytes)
    }

    function script:Get-Refusal([string]$Path) {
        return (Get-ThrownMessage { Assert-ImageHasNoParent -ImagePath $Path })
    }

    function script:Set-VhdxRegionEntry([byte[]]$Bytes, [int]$Index, [uint64]$Offset, [uint32]$Length, [uint32]$Required = 1, [string]$Guid = $null) {
        # Changes one entry in both region tables, and their checksums.
        foreach ($at in 192KB, 256KB) {
            $e = $at + 16 + ($Index * 32)
            if ($Guid) { Set-TestGuid -Bytes $Bytes -At $e -Guid $Guid }
            Set-TestLittleEndian -Bytes $Bytes -At ($e + 16) -Value $Offset
            Set-TestLittleEndian -Bytes $Bytes -At ($e + 24) -Value $Length
            Set-TestLittleEndian -Bytes $Bytes -At ($e + 28) -Value $Required
            Update-TestVhdxChecksum -Bytes $Bytes -At $at -Length 64KB
        }
    }
}

Describe 'Images it accepts' {
    It 'accepts a <Kind> VHD' -ForEach @(@{ Kind = 'Fixed' }, @{ Kind = 'Dynamic' }) {
        Get-Refusal (Save "ok-$Kind.vhd" (New-TestVhdImage -Kind $Kind)) | Should -BeNullOrEmpty
    }

    It 'accepts a VHDX with no parent' {
        Get-Refusal (Save 'ok.vhdx' (New-TestVhdxImage)) | Should -BeNullOrEmpty
    }

    It 'accepts a VHD with the 511-byte footer older versions wrote' {
        $b = New-TestVhdImage -Kind Fixed
        $short = New-Object byte[] ($b.Length - 1)
        [System.Buffer]::BlockCopy($b, 0, $short, 0, $short.Length)
        Get-Refusal (Save 'short-footer.vhd' $short) | Should -BeNullOrEmpty
    }

    It 'accepts a VHDX with one damaged header, using the other' {
        $b = New-TestVhdxImage
        $b[64KB + 200] = 0x5A
        Get-Refusal (Save 'one-header.vhdx' $b) | Should -BeNullOrEmpty
    }

    It 'accepts a VHDX with one damaged region table, using the other' {
        $b = New-TestVhdxImage
        $b[256KB + 300] = 0x5A
        Get-Refusal (Save 'one-region.vhdx' $b) | Should -BeNullOrEmpty
    }

    It 'only reads the image, sharing it for reading' {
        $p = Save 'readonly.vhdx' (New-TestVhdxImage)
        $before = (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash
        $held = [System.IO.File]::Open($p, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        try {
            Get-Refusal $p | Should -BeNullOrEmpty -Because 'another reader holding the image open is fine'
        }
        finally {
            $held.Dispose()
        }
        (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash | Should -Be $before
    }
}

Describe 'Differencing images it refuses' {
    It 'refuses a differencing VHD, naming it' {
        $p = Save 'diff.vhd' (New-TestVhdImage -Kind Differencing)
        Get-Refusal $p | Should -BeExactly "$p is a differencing disk, and the tool won't open the parent it points to, so it isn't mounted. Merge it into a standalone image and rerun."
    }

    It 'refuses a VHD whose footer copy at the start says differencing, whatever the end says' {
        $b = New-TestVhdImage -Kind Dynamic
        $copy = New-Object byte[] 512
        [System.Buffer]::BlockCopy($b, 0, $copy, 0, 512)
        Set-TestBigEndian32 -Bytes $copy -At 60 -Value 4
        Update-TestVhdChecksum -Footer $copy
        [System.Buffer]::BlockCopy($copy, 0, $b, 0, 512)
        Get-Refusal (Save 'diff-copy.vhd' $b) | Should -BeLike '*is a differencing disk*'
    }

    It 'refuses a VHDX with <Name>' -ForEach @(
        @{ Name = 'HasParent set'; HasParent = $true; Locator = $false }
        @{ Name = 'a parent locator'; HasParent = $false; Locator = $true }
        @{ Name = 'both'; HasParent = $true; Locator = $true }
    ) {
        $p = Save "parent-$($Name.Replace(' ', '-')).vhdx" (New-TestVhdxImage -HasParent:$HasParent -ParentLocator:$Locator)
        Get-Refusal $p | Should -BeExactly "$p is a differencing disk, and the tool won't open the parent it points to, so it isn't mounted. Merge it into a standalone image and rerun."
    }
}

Describe 'Malformed images it refuses' {
    It 'refuses a VHD with <Name>' -ForEach @(
        @{ Name = 'no cookie'; Want = 'it has no VHD footer at the end of the file'; Change = { param($b) $b[$b.Length - 512] = 0x41 } }
        @{ Name = 'a bad checksum'; Want = 'its footer checksum doesn''t match'; Change = { param($b) $b[$b.Length - 512 + 100] = 0x41 } }
        @{ Name = 'an unknown disk type'; Want = 'its footer gives disk type 5, which isn''t fixed, dynamic or differencing'; Change = {
                param($b)
                $f = New-Object byte[] 512
                [System.Buffer]::BlockCopy($b, $b.Length - 512, $f, 0, 512)
                Set-TestBigEndian32 -Bytes $f -At 60 -Value 5
                Update-TestVhdChecksum -Footer $f
                [System.Buffer]::BlockCopy($f, 0, $b, $b.Length - 512, 512)
            }
        }
    ) {
        $b = New-TestVhdImage -Kind Fixed
        & $Change $b
        $p = Save "bad-$($Name.Replace(' ', '-')).vhd" $b
        Get-Refusal $p | Should -BeExactly "$p isn't a well-formed VHD image, because $Want, so it isn't mounted."
    }

    It 'refuses a dynamic VHD whose header offset points past the end of the file' {
        $b = New-TestVhdImage -Kind Dynamic
        foreach ($at in 0, ($b.Length - 512)) {
            $f = New-Object byte[] 512
            [System.Buffer]::BlockCopy($b, $at, $f, 0, 512)
            Set-TestBigEndian64 -Bytes $f -At 16 -Value ([uint64]1TB)
            Update-TestVhdChecksum -Footer $f
            [System.Buffer]::BlockCopy($f, 0, $b, $at, 512)
        }
        Get-Refusal (Save 'far-header.vhd' $b) | Should -BeLike '*because it points past the end of the file*'
    }

    It 'refuses a dynamic VHD whose header carries a parent locator' {
        $b = New-TestVhdImage -Kind Dynamic
        Set-TestAscii -Bytes $b -At (512 + 576) -Text 'W2ku'
        Get-Refusal (Save 'dyn-locator.vhd' $b) | Should -BeLike '*because its dynamic disk header carries a parent locator*'
    }

    It 'refuses a VHD whose two footers disagree' {
        $b = New-TestVhdImage -Kind Dynamic
        $f = New-Object byte[] 512
        [System.Buffer]::BlockCopy($b, 0, $f, 0, 512)
        Set-TestBigEndian32 -Bytes $f -At 60 -Value 2
        Update-TestVhdChecksum -Footer $f
        [System.Buffer]::BlockCopy($f, 0, $b, 0, 512)
        Get-Refusal (Save 'disagree.vhd' $b) | Should -BeLike '*because its two footers give different disk types*'
    }

    It 'refuses a file too small to be a VHD' {
        Get-Refusal (Save 'tiny.vhd' ([byte[]](1..100))) | Should -BeLike "*because it's too small to hold a VHD footer*"
    }

    It 'refuses a VHDX with <Name>' -ForEach @(
        @{ Name = 'neither header valid'; Want = 'neither of its VHDX headers is valid'; Change = { param($b) $b[64KB + 200] = 1; $b[128KB + 200] = 1 } }
        @{ Name = 'neither region table valid'; Want = 'neither of its region tables is valid'; Change = { param($b) $b[192KB + 300] = 1; $b[256KB + 300] = 1 } }
        @{ Name = 'region tables that differ'; Want = 'its two region tables differ'; Change = { param($b) $b[256KB + 300] = 1; Update-TestVhdxChecksum -Bytes $b -At 256KB -Length 64KB } }
        @{ Name = 'a huge region entry count'; Want = 'neither of its region tables is valid'; Change = {
                param($b)
                foreach ($at in 192KB, 256KB) { Set-TestLittleEndian -Bytes $b -At ($at + 8) -Value ([uint32]100000); Update-TestVhdxChecksum -Bytes $b -At $at -Length 64KB }
            }
        }
        @{ Name = 'a region past the end of the file'; Want = "a region lies outside the file or isn't aligned"; Change = { param($b) Set-VhdxRegionEntry -Bytes $b -Index 1 -Offset ([uint64]64MB) -Length ([uint32]1MB) } }
        @{ Name = 'a region whose length runs past the end'; Want = "a region lies outside the file or isn't aligned"; Change = { param($b) Set-VhdxRegionEntry -Bytes $b -Index 1 -Offset ([uint64]3MB) -Length ([uint32]2MB) } }
        @{ Name = 'an unaligned region'; Want = "a region lies outside the file or isn't aligned"; Change = { param($b) Set-VhdxRegionEntry -Bytes $b -Index 1 -Offset ([uint64](3MB + 4096)) -Length ([uint32]1MB) } }
        @{ Name = 'an unknown required region'; Want = "it has a required region the tool doesn't know"; Change = { param($b) Set-VhdxRegionEntry -Bytes $b -Index 0 -Offset ([uint64]2MB) -Length ([uint32]1MB) -Required 1 -Guid ([guid]::NewGuid().ToString()) } }
        @{ Name = 'no metadata table signature'; Want = 'its metadata table has no signature'; Change = { param($b) $b[3MB] = 0x41 } }
        @{ Name = 'a huge metadata entry count'; Want = 'its metadata table lists more entries than the format allows'; Change = { param($b) Set-TestLittleEndian -Bytes $b -At (3MB + 10) -Value ([uint16]60000) } }
        @{ Name = 'a metadata item past the region'; Want = 'a metadata item lies outside the metadata region'; Change = { param($b) Set-TestLittleEndian -Bytes $b -At (3MB + 32 + 16) -Value ([uint32]2MB) } }
        @{ Name = 'a metadata item inside the table'; Want = 'a metadata item lies outside the metadata region'; Change = { param($b) Set-TestLittleEndian -Bytes $b -At (3MB + 32 + 16) -Value ([uint32]100) } }
        @{ Name = 'an unknown required metadata item'; Want = "it has a required metadata item the tool doesn't know"; Change = { param($b) Set-TestGuid -Bytes $b -At (3MB + 32 + 32) -Guid ([guid]::NewGuid().ToString()) } }
        @{ Name = 'no file parameters item'; Want = 'its metadata has no file parameters item'; Change = { param($b) Set-TestGuid -Bytes $b -At (3MB + 32) -Guid ([guid]::NewGuid().ToString()); Set-TestLittleEndian -Bytes $b -At (3MB + 32 + 24) -Value ([uint32]0) } }
        @{ Name = 'an item listed twice'; Want = 'its metadata table lists an item twice'; Change = { param($b) Set-TestGuid -Bytes $b -At (3MB + 32 + 32) -Guid 'CAA16737-FA36-4D43-B3B6-33F0AA44E76B' } }
    ) {
        $b = New-TestVhdxImage
        & $Change $b
        $p = Save "bad-$($Name.Replace(' ', '-')).vhdx" $b
        Get-Refusal $p | Should -BeExactly "$p isn't a well-formed VHDX image, because $Want, so it isn't mounted."
    }

    It 'refuses two headers with the same sequence number that differ' {
        $b = New-TestVhdxImage
        Set-TestLittleEndian -Bytes $b -At (128KB + 8) -Value ([uint64]1)
        Update-TestVhdxChecksum -Bytes $b -At 128KB -Length 4096
        Get-Refusal (Save 'same-seq.vhdx' $b) | Should -BeLike '*because its two VHDX headers have the same sequence number but differ*'
    }

    It 'refuses a VHDX shorter than its own headers' {
        $b = New-Object byte[] 512KB
        Set-TestAscii -Bytes $b -At 0 -Text 'vhdxfile'
        Get-Refusal (Save 'short.vhdx' $b) | Should -BeLike "*because it's too small to hold the VHDX headers*"
    }

    It 'refuses a file whose content doesn''t match its extension' {
        $vhdx = Save 'really-vhdx.vhd' (New-TestVhdxImage)
        Get-Refusal $vhdx | Should -BeExactly "$vhdx is a VHDX file named as a VHD, so it isn't mounted."
        $vhd = Save 'really-vhd.vhdx' (New-TestVhdImage -Kind Fixed)
        Get-Refusal $vhd | Should -BeExactly "$vhd is a VHD file named as a VHDX, so it isn't mounted."
    }
}

Describe 'Refusing before anything is mounted or written' {
    BeforeAll {
        $script:out = New-TestDirectory (Join-TestPath $TestDrive 'out')
        Mock Assert-MountSupported { }
        Mock Test-ImageAttached { $false }
        Mock Get-ImageSha256 { throw 'the image should not be hashed' }
        Mock New-DifferencingChild { throw 'diskpart should not run' }
        Mock Mount-ImageFile { throw 'nothing should be mounted' }
    }

    It 'fails a differencing image in InputRoot before hashing, diskpart or the _diff folder' {
        $in = New-TestDirectory (Join-TestPath $TestDrive 'in-diff')
        Write-TestImage -Path (Join-TestPath $in 'HOST01.vhdx') -Bytes (New-TestVhdxImage -HasParent -ParentLocator) | Out-Null
        $col = @(Get-InputCollection -InputRoot $in)[0]
        $o = Join-TestPath $out 'diff'
        Get-ThrownMessage { Resolve-CollectionInput -Collection $col -OutputRoot $o -MaxUncompressedBytes 1GB -MaxRatio 250 } | Should -BeLike '*HOST01.vhdx is a differencing disk*'
        Should -Invoke Get-ImageSha256 -Times 0 -Exactly
        Should -Invoke New-DifferencingChild -Times 0 -Exactly
        Test-Path -LiteralPath (Join-TestPath $o '_diff') | Should -BeFalse
    }

    It 'fails a differencing image extracted from a ZIP the same way' {
        $in = New-TestDirectory (Join-TestPath $TestDrive 'in-zipdiff')
        New-TestZip -Path (Join-TestPath $in 'HOST02.zip') -Entries ([ordered]@{ 'Container/HOST02.vhd' = (New-TestVhdImage -Kind Differencing) }) -NoCompression | Out-Null
        $col = @(Get-InputCollection -InputRoot $in)[0]
        $o = Join-TestPath $out 'zipdiff'
        Get-ThrownMessage { Resolve-CollectionInput -Collection $col -OutputRoot $o -MaxUncompressedBytes 1GB -MaxRatio 250 } | Should -BeLike '*HOST02.vhd is a differencing disk*'
        Should -Invoke Get-ImageSha256 -Times 0 -Exactly
        Should -Invoke New-DifferencingChild -Times 0 -Exactly
        Test-Path -LiteralPath (Join-TestPath $o '_diff') | Should -BeFalse
        Test-Path -LiteralPath (Join-TestPath $o '_work' 'HOST02') | Should -BeFalse -Because 'the extract is removed when the host fails'
    }
}
