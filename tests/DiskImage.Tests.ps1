BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers/TestHelpers.ps1')
    $script:cap = [long]1GB
    $script:VolumeWaitSeconds = 0
    $script:DriveLetterWaitSeconds = 0

    $script:dm = New-TestDirectory (Join-TestPath $TestDrive 'dm')
    $script:parentRaw = Join-TestPath $dm 'in' 'HOST01.VHDX'
    New-TestDirectory (Split-Path -Parent $parentRaw) | Out-Null
    [System.IO.File]::WriteAllBytes($parentRaw, [byte[]](1..200))
    $script:rawCol = @(Get-InputCollection -InputRoot (Split-Path -Parent $parentRaw))[0]
    $script:parentVhd = Join-TestPath $dm 'in2' 'HOST02.vhd'
    New-TestDirectory (Split-Path -Parent $parentVhd) | Out-Null
    [System.IO.File]::WriteAllBytes($parentVhd, [byte[]](1..100))
    $script:vhdCol = @(Get-InputCollection -InputRoot (Split-Path -Parent $parentVhd))[0]
    $script:zipPath = New-TestZip -Path (Join-TestPath $dm 'zin' 'HOST03.zip') -Entries ([ordered]@{ 'Container/HOST03.vhdx' = 'parent-bytes'; 'Container/HOST03_ConsoleLog.txt' = 'log' })
    $script:zipCol = @(Get-InputCollection -InputRoot (Split-Path -Parent $zipPath))[0]
    $script:hashRaw = (Get-FileHash -LiteralPath $parentRaw).Hash
    $script:hashZip = (Get-FileHash -LiteralPath $zipPath).Hash
    $script:out = New-TestDirectory (Join-TestPath $dm 'out')

    $script:vLetter = [pscustomobject]@{ DiskNumber = 5; PartitionNumber = 1; DriveLetter = 'E'; VolumePath = '\\?\Volume{a}\'; FileSystem = 'NTFS' }
    $script:vNoLetter = [pscustomobject]@{ DiskNumber = 6; PartitionNumber = 2; DriveLetter = $null; VolumePath = '\\?\Volume{b}\'; FileSystem = 'NTFS' }

    $script:realRemoveDiff = ${function:Remove-DifferencingChild}
    $script:realRemoveMount = ${function:Remove-MountFolder}
    $script:realRemoveExtract = ${function:Remove-CollectionExtract}
    function script:Leaf($p) { [System.IO.Path]::GetFileName($p) }
    function script:Resolve-Test($c, [switch]$Keep) { Resolve-CollectionInput -Collection $c -OutputRoot $out -MaxUncompressedBytes $cap -MaxRatio 250 -KeepArtifacts:$Keep }
}

Describe 'Real wrappers off Windows' {
    BeforeAll { Mock Test-IsWindowsHost { $false } }

    It '<Name> refuses off Windows' -ForEach @(
        @{ Name = 'New-DifferencingChild'; Call = { New-DifferencingChild -ParentPath $parentRaw -ChildPath (Join-TestPath $dm 'c.vhdx') } }
        @{ Name = 'Mount-ImageFile'; Call = { Mount-ImageFile -ImagePath $parentRaw } }
        @{ Name = 'Get-ImageVolumeCandidate'; Call = { Get-ImageVolumeCandidate -ImagePath $parentRaw } }
        @{ Name = 'Test-ImageAttached'; Call = { Test-ImageAttached -ImagePath $parentRaw } }
        @{ Name = 'Mount-CollectionImage'; Call = { Mount-CollectionImage -ImagePath $parentRaw -MountRoot $dm -DiffRoot $dm -Collection 'X' -Teardown (New-Object System.Collections.Generic.List[object]) } }
    ) {
        Get-ThrownMessage $Call | Should -BeLike '*requires Windows*'
    }
}

Describe 'diskpart script' {
    It 'creates a differencing child of the parent' {
        Get-DifferencingChildScript -ParentPath 'D:\Case\KAPE\HOST01.vhdx' -ChildPath 'D:\Case\Out\_diff\HOST01.vhdx' | Should -BeExactly 'create vdisk file="D:\Case\Out\_diff\HOST01.vhdx" parent="D:\Case\KAPE\HOST01.vhdx"'
    }
    It 'refuses a path diskpart cannot be sent in its code page' {
        $p = 'D:\F' + [char]0x00E4 + 'lle\HOST01.vhdx'
        $m = Get-ThrownMessage { Get-DifferencingChildScript -ParentPath $p -ChildPath 'D:\Out\_diff\HOST01.vhdx' -Encoding ([System.Text.Encoding]::ASCII) }
        $m | Should -BeLike "*can't be passed to diskpart*"
        $m.Contains($p) | Should -BeTrue
    }
    It 'accepts the same path when the code page holds every character' {
        $p = 'D:\F' + [char]0x00E4 + 'lle\HOST01.vhdx'
        Get-DifferencingChildScript -ParentPath $p -ChildPath 'D:\Out\_diff\HOST01.vhdx' -Encoding ([System.Text.Encoding]::GetEncoding(28591)) | Should -BeExactly "create vdisk file=`"D:\Out\_diff\HOST01.vhdx`" parent=`"$p`""
    }
    It 'picks an encoding for diskpart input' {
        Get-DiskpartEncoding | Should -BeOfType ([System.Text.Encoding])
    }
    It 'refuses a path with a double quote' {
        Get-ThrownMessage { Get-DifferencingChildScript -ParentPath 'D:\a"b.vhdx' -ChildPath 'D:\c.vhdx' } | Should -BeLike '*double quote*'
    }
    It 'calls diskpart by full path under SystemRoot' {
        $saved = $env:SystemRoot
        try {
            $env:SystemRoot = 'C:\Windows'
            Get-DiskpartPath | Should -Be ([System.IO.Path]::Combine('C:\Windows', 'System32', 'diskpart.exe'))
        }
        finally { $env:SystemRoot = $saved }
    }
}

Describe 'Differencing mount orchestration' {
    BeforeEach {
        $script:log = New-Object System.Collections.Generic.List[string]
        $script:scripts = New-Object System.Collections.Generic.List[string]
        $script:attached = @{}
        $script:diskpartFails = $false
        $script:dismountFails = $false
        $script:volumes = @($vLetter)

        Mock Assert-MountSupported { }
        Mock Test-ImageAttached { [bool]$script:attached[$ImagePath] }
        Mock New-DifferencingChild {
            $script:scripts.Add((Get-DifferencingChildScript -ParentPath $ParentPath -ChildPath $ChildPath))
            if ($script:diskpartFails) { throw "diskpart did not create the differencing child $ChildPath (exit code 1). Virtual Disk Service error" }
            [System.IO.File]::WriteAllText($ChildPath, "child of $ParentPath")
            $script:log.Add("create $(Leaf $ChildPath)")
        }
        Mock Mount-ImageFile { $script:log.Add("mount $(Leaf $ImagePath)"); $script:attached[$ImagePath] = $true }
        Mock Get-ImageVolumeCandidate { $script:volumes }
        Mock Add-CollectionAccessPath { $script:log.Add("addaccess $DiskNumber/$PartitionNumber") }
        Mock Remove-CollectionAccessPath { $script:log.Add("removeaccess $DiskNumber/$PartitionNumber") }
        Mock Dismount-CollectionImage {
            if ($script:dismountFails) { throw 'device busy' }
            if (-not (Test-Path -LiteralPath $ImagePath)) { throw 'child gone before dismount' }
            $script:log.Add("dismount $(Leaf $ImagePath)"); $script:attached[$ImagePath] = $false
        }
        Mock Remove-DifferencingChild { $script:log.Add("removediff $(Leaf $Path)"); & $script:realRemoveDiff -Path $Path -DiffRoot $DiffRoot }
        Mock Remove-MountFolder { $script:log.Add('removemountfolder'); & $script:realRemoveMount -Path $Path -MountRoot $MountRoot }
        Mock Remove-CollectionExtract { $script:log.Add('removeextract'); & $script:realRemoveExtract -Path $Path -WorkRoot $WorkRoot }
    }

    It 'raw VHDX with a drive letter: the child is created and mounted, never the parent' {
        $r = Resolve-Test $rawCol
        $child = Join-TestPath $out '_diff' 'HOST01.vhdx'
        $r.Path | Should -Be 'E:\'
        $r.ChildPath | Should -Be $child
        $r.ImagePath | Should -Be $parentRaw
        [System.IO.Path]::GetExtension($r.ChildPath) | Should -BeExactly '.vhdx'
        ($log -join ' > ') | Should -Be 'create HOST01.vhdx > mount HOST01.vhdx'
        $scripts[0] | Should -BeExactly "create vdisk file=`"$child`" parent=`"$parentRaw`""
        $log.Clear()
        Invoke-CollectionCleanup -Resolved $r
        ($log -join ' > ') | Should -Be 'dismount HOST01.vhdx > removediff HOST01.vhdx'
        Test-Path -LiteralPath $child | Should -BeFalse
        (Get-FileHash -LiteralPath $parentRaw).Hash | Should -Be $hashRaw
    }

    It 'raw VHD without a letter: _mnt access path, then access path, dismount, mount folder, child' {
        $script:volumes = @($vNoLetter)
        $r = Resolve-Test $vhdCol
        $r.Path | Should -Be (Join-TestPath $out '_mnt' 'HOST02')
        [System.IO.Path]::GetExtension($r.ChildPath) | Should -BeExactly '.vhd'
        ($log -join ' > ') | Should -Be 'create HOST02.vhd > mount HOST02.vhd > addaccess 6/2'
        $log.Clear()
        Invoke-CollectionCleanup -Resolved $r
        ($log -join ' > ') | Should -Be 'removeaccess 6/2 > dismount HOST02.vhd > removemountfolder > removediff HOST02.vhd'
        Test-Path -LiteralPath $r.Path | Should -BeFalse
        Test-Path -LiteralPath $r.ChildPath | Should -BeFalse
    }

    It 'zip with a VHDX: the child is made from the extracted image, torn down in order' {
        $script:volumes = @($vNoLetter)
        $r = Resolve-Test $zipCol
        $extracted = Join-TestPath $out '_work' 'HOST03' 'Container' 'HOST03.vhdx'
        $r.ImagePath | Should -Be $extracted
        $scripts[0] | Should -BeExactly "create vdisk file=`"$($r.ChildPath)`" parent=`"$extracted`""
        $log.Clear()
        Invoke-CollectionCleanup -Resolved $r
        ($log -join ' > ') | Should -Be 'removeaccess 6/2 > dismount HOST03.vhdx > removemountfolder > removediff HOST03.vhdx > removeextract'
        Test-Path -LiteralPath $r.ExtractPath | Should -BeFalse
        Test-Path -LiteralPath $r.ChildPath | Should -BeFalse
        (Get-FileHash -LiteralPath $zipPath).Hash | Should -Be $hashZip
    }

    It '-KeepArtifacts always dismounts and keeps the child and the extract' {
        $script:volumes = @($vNoLetter)
        $r = Resolve-Test $zipCol -Keep
        $log.Clear()
        Invoke-CollectionCleanup -Resolved $r
        ($log -join ' > ') | Should -Be 'removeaccess 6/2 > dismount HOST03.vhdx > removemountfolder'
        Test-Path -LiteralPath $r.ChildPath | Should -BeTrue
        Test-Path -LiteralPath $r.ImagePath | Should -BeTrue
        $attached[$r.ChildPath] | Should -BeFalse
        Remove-Item -LiteralPath $r.ExtractPath -Recurse -Force
        Remove-Item -LiteralPath $r.ChildPath -Force
    }

    It 'a failed dismount leaves the mount folder, child and extract, and a retry finishes once' {
        $script:volumes = @($vNoLetter)
        $script:dismountFails = $true
        $r = Resolve-Test $zipCol
        $m = Get-ThrownMessage { Invoke-CollectionCleanup -Resolved $r }
        $m | Should -BeLike '*Dismount*device busy*'
        $m | Should -BeLike "*Left $($r.ChildPath) in place*"
        Test-Path -LiteralPath $r.ChildPath | Should -BeTrue
        Test-Path -LiteralPath $r.ExtractPath | Should -BeTrue
        Test-Path -LiteralPath $r.MountPath | Should -BeTrue
        $log | Should -Not -Contain 'removeextract'
        $script:dismountFails = $false
        $log.Clear()
        Invoke-CollectionCleanup -Resolved $r
        ($log -join ' > ') | Should -Be 'dismount HOST03.vhdx > removemountfolder > removediff HOST03.vhdx > removeextract'
    }

    It 'a diskpart failure is reported, nothing is mounted and nothing is left behind' {
        $script:diskpartFails = $true
        Get-ThrownMessage { Resolve-Test $zipCol } | Should -BeLike '*diskpart did not create the differencing child*Virtual Disk Service error*'
        @($log | Where-Object { $_ -like 'mount*' }).Count | Should -Be 0
        Test-Path -LiteralPath (Join-TestPath $out '_work' 'HOST03') | Should -BeFalse
        Test-Path -LiteralPath (Join-TestPath $out '_diff' 'HOST03.vhdx') | Should -BeFalse
    }

    It 'refuses a parent that is already attached, creating no child' {
        $script:attached[$parentRaw] = $true
        Get-ThrownMessage { Resolve-Test $rawCol } | Should -BeLike '*HOST01.VHDX is already attached*left alone*'
        Test-Path -LiteralPath (Join-TestPath $out '_diff' 'HOST01.vhdx') | Should -BeFalse
    }

    It 'replaces a leftover child that is not attached' {
        $stale = Join-TestPath $out '_diff' 'HOST01.vhdx'
        Write-TestText -Path $stale -Line @('stale') | Out-Null
        $r = Resolve-Test $rawCol
        (Get-Content -LiteralPath $stale -Raw) | Should -BeLike 'child of *'
        $log[0] | Should -Be 'removediff HOST01.vhdx'
        $log[1] | Should -Be 'create HOST01.vhdx'
        Invoke-CollectionCleanup -Resolved $r
    }

    It 'refuses a leftover child that is still attached' {
        $stale = Join-TestPath $out '_diff' 'HOST01.vhdx'
        Write-TestText -Path $stale -Line @('stale') | Out-Null
        $script:attached[$stale] = $true
        Get-ThrownMessage { Resolve-Test $rawCol } | Should -BeLike '*Differencing child*still attached*'
        Remove-Item -LiteralPath $stale -Force
    }

    It 'picks the volume holding event logs when there are several' {
        $vA = New-TestDirectory (Join-TestPath $dm 'volA')
        $vB = New-TestDirectory (Join-TestPath $dm 'volB')
        New-TestDirectory (Join-TestPath $vB 'C' 'Windows' 'System32' 'winevt' 'Logs') | Out-Null
        $script:volumes = @(
            [pscustomobject]@{ DiskNumber = 7; PartitionNumber = 1; DriveLetter = 'F'; VolumePath = $vA; FileSystem = 'FAT32' }
            [pscustomobject]@{ DiskNumber = 7; PartitionNumber = 2; DriveLetter = 'G'; VolumePath = $vB; FileSystem = 'NTFS' })
        $r = Resolve-Test $rawCol
        $r.Path | Should -Be 'G:\'
        Invoke-CollectionCleanup -Resolved $r
    }

    It 'with no volume, reports it and still dismounts and deletes the child' {
        $script:volumes = @()
        Get-ThrownMessage { Resolve-Test $rawCol } | Should -BeLike '*No readable volume*'
        $child = Join-TestPath $out '_diff' 'HOST01.vhdx'
        Test-Path -LiteralPath $child | Should -BeFalse
        $attached[$child] | Should -BeFalse
    }

    It 'never modifies the parent images' {
        (Get-FileHash -LiteralPath $parentRaw).Hash | Should -Be $hashRaw
        (Get-FileHash -LiteralPath $zipPath).Hash | Should -Be $hashZip
    }
}

Describe 'Differencing child removal guard' {
    It 'refuses a file outside _diff or a non-image file' {
        $diff = New-TestDirectory (Join-TestPath $out '_diff')
        Get-ThrownMessage { Remove-DifferencingChild -Path $parentRaw -DiffRoot $diff } | Should -BeLike '*not a differencing child directly under*'
        $x = Write-TestText -Path (Join-TestPath $diff 'notes.txt') -Line @('x')
        Get-ThrownMessage { Remove-DifferencingChild -Path $x -DiffRoot $diff } | Should -BeLike '*not a differencing child*'
    }
}
