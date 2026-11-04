# Mounts a real VHDX. Runs only on Windows in an elevated session; skipped
# everywhere else. Tagged Mount so it can be selected or left out:
#
#     Invoke-Pester -Path tests -TagFilter Mount
#
# The images are built fresh, so they are clean, unlike a KAPE image taken
# from a live host. This checks the mechanism: the parent is never written,
# the differencing child is removed, nothing is left attached, and the tool's
# own before-and-after hash in run-meta matches the test's. One image is laid
# out as KAPE writes its container, with the logs under C\, and the other as
# a full disk, with Windows at the volume root.

BeforeDiscovery {
    $script:canMount = $false
    if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
        $principal = New-Object System.Security.Principal.WindowsPrincipal([System.Security.Principal.WindowsIdentity]::GetCurrent())
        $script:canMount = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    }
}

Describe 'Mounting a real VHDX' -Tag 'Mount' -Skip:(-not $canMount) {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'Helpers/TestHelpers.ps1')
        Enter-TestPlainConsole
        # Every image is listed here before it's created, so AfterAll can
        # dismount it even when a build or a test stops partway.
        $script:images = New-Object System.Collections.Generic.List[string]

        function script:New-TestNtfsImage([string]$Path, [string]$Label, [scriptblock]$Fill) {
            # Builds a 64 MB expandable VHDX with one NTFS volume, runs Fill
            # with the volume root, dismounts it, and returns its SHA-256.
            $script:images.Add($Path)
            $scriptFile = Join-TestPath $TestDrive "create-$Label.txt"
            Write-TestText -Path $scriptFile -Line @("create vdisk file=`"$Path`" maximum=64 type=expandable") | Out-Null
            $dp = & (Get-DiskpartPath) /s $scriptFile 2>&1
            if ($LASTEXITCODE -ne 0) { throw "diskpart could not create the test image ${Path}: $($dp -join ' ')" }

            Mount-DiskImage -ImagePath $Path | Out-Null
            try {
                $disk = Get-DiskImage -ImagePath $Path | Get-Disk
                Initialize-Disk -Number $disk.Number -PartitionStyle MBR
                $part = New-Partition -DiskNumber $disk.Number -UseMaximumSize -AssignDriveLetter
                Format-Volume -Partition $part -FileSystem NTFS -NewFileSystemLabel $Label -Confirm:$false | Out-Null
                $root = "$((Get-Partition -DiskNumber $disk.Number -PartitionNumber $part.PartitionNumber).DriveLetter):\"
                & $Fill -Root $root
            }
            finally {
                Dismount-DiskImage -ImagePath $Path | Out-Null
            }
            return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
        }

        # Laid out as KAPE writes its container, with the logs one folder
        # down under C\ and the fake's files at the volume root.
        $script:in = New-TestDirectory (Join-TestPath $TestDrive 'in')
        $script:parent = Join-TestPath $in 'HOST01.vhdx'
        $script:parentHash = New-TestNtfsImage -Path $parent -Label 'TESTEVID' -Fill {
            param($Root)
            Write-TestText -Path (Join-Path $Root 'C\Windows\System32\winevt\Logs\x.evtx') -Line @('synthetic') | Out-Null
            Write-TestText -Path (Join-Path $Root 'fake.behavior') -Line @('EXIT=0', 'CSV=r.csv') | Out-Null
            Write-TestText -Path (Join-Path $Root 'r.csv') -Line @($TimelineHeader, (New-TimelineRow 'WS01' 'high' 'RuleA')) | Out-Null
        }

        # A full disk, with Windows at the volume root. Hayabusa is given
        # only the Logs folder, so the fake's files go in there.
        $script:inFull = New-TestDirectory (Join-TestPath $TestDrive 'in-full')
        $script:fullParent = Join-TestPath $inFull 'HOST02.vhdx'
        $script:fullParentHash = New-TestNtfsImage -Path $fullParent -Label 'TESTFULL' -Fill {
            param($Root)
            $logs = Join-Path $Root 'Windows\System32\winevt\Logs'
            Write-TestText -Path (Join-Path $logs 'x.evtx') -Line @('synthetic') | Out-Null
            Write-TestText -Path (Join-Path $logs 'fake.behavior') -Line @('EXIT=0', 'CSV=r.csv') | Out-Null
            Write-TestText -Path (Join-Path $logs 'r.csv') -Line @($TimelineHeader, (New-TimelineRow 'WS02' 'high' 'RuleB')) | Out-Null
        }
    }

    AfterAll {
        $all = @()
        $made = Get-Variable -Name 'images' -Scope Script -ValueOnly -ErrorAction SilentlyContinue
        if ($null -ne $made) { $all += @($made) }
        $all += @(Get-ChildItem -Path (Join-TestPath $TestDrive '*' '_diff') -Filter '*.vhdx' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
        foreach ($p in $all) {
            # Each image on its own, so one that won't let go doesn't keep
            # the others attached.
            try {
                if ($p -and (Test-Path -LiteralPath $p) -and (Get-DiskImage -ImagePath $p -ErrorAction SilentlyContinue).Attached) {
                    Dismount-DiskImage -ImagePath $p | Out-Null
                }
                if ($p -and (Test-Path -LiteralPath $p)) {
                    [System.IO.File]::Delete($p)
                }
            }
            catch {
                Write-Warning "Could not dismount or remove the test image ${p}: $($_.Exception.Message)"
            }
        }
        Exit-TestPlainConsole
    }

    It 'refuses an OutputRoot holding a non-ASCII character clearly, leaving nothing behind' {
        $out = New-TestDirectory (Join-TestPath $TestDrive ('F' + [char]0x00E4 + 'lle') 'out')
        $c = @(Get-InputCollection -InputRoot $in -WarningAction SilentlyContinue)
        $m = Get-ThrownMessage { Resolve-CollectionInput -Collection $c[0] -OutputRoot $out -MaxUncompressedBytes 1GB -MaxRatio 250 }
        $m | Should -BeLike "*can't be passed to diskpart, which can't reliably read non-ASCII characters*"
        @(Get-ChildItem -LiteralPath (Join-TestPath $out '_diff') -Force -ErrorAction SilentlyContinue).Count | Should -Be 0
        (Get-DiskImage -ImagePath $parent).Attached | Should -BeFalse
        (Get-FileHash -LiteralPath $parent -Algorithm SHA256).Hash | Should -Be $parentHash
    }

    It 'resolves to a volume holding the event logs and tears it all down' {
        $out = New-TestDirectory (Join-TestPath $TestDrive 'out')
        $c = @(Get-InputCollection -InputRoot $in -WarningAction SilentlyContinue)
        $c.Count | Should -Be 1
        $c[0].InputType | Should -Be 'Vhdx'
        $r = Resolve-CollectionInput -Collection $c[0] -OutputRoot $out -MaxUncompressedBytes 1GB -MaxRatio 250
        try {
            Test-Path -LiteralPath (Join-Path $r.Path 'C\Windows\System32\winevt\Logs\x.evtx') | Should -BeTrue
            $r.ChildPath | Should -Be (Join-TestPath $out '_diff' 'HOST01.vhdx')
            Test-ImageAttached -ImagePath $r.ChildPath | Should -BeTrue
            Test-ImageAttached -ImagePath $parent | Should -BeFalse
        }
        finally {
            Invoke-CollectionCleanup -Resolved $r
        }
        $r.ImageHash.Before | Should -BeExactly $parentHash
        $r.ImageHash.After | Should -BeExactly $parentHash
        $r.ImageHash.Match | Should -BeTrue
        Test-Path -LiteralPath $r.ChildPath | Should -BeFalse
        Test-ImageAttached -ImagePath $parent | Should -BeFalse
        (Get-FileHash -LiteralPath $parent -Algorithm SHA256).Hash | Should -Be $parentHash
    }

    It 'runs the whole tool against it and leaves the parent unchanged' {
        $hb = New-FakeHayabusa -Directory (Join-TestPath $TestDrive 'tool')
        $out = Join-TestPath $TestDrive 'out-main'
        $r = & $MainScript -PassThru -InputRoot $in -OutputRoot $out -HayabusaPath $hb -WarningAction SilentlyContinue
        $row = (Get-RunManifest -Path $r.ManifestPath)['HOST01']
        $row.Status | Should -Be 'Completed'
        $row.Host | Should -Be 'WS01'
        $row.High | Should -Be '1'
        @(Get-ChildItem -LiteralPath (Join-TestPath $out '_diff') -Force -ErrorAction SilentlyContinue).Count | Should -Be 0
        Test-ImageAttached -ImagePath $parent | Should -BeFalse
        (Get-FileHash -LiteralPath $parent -Algorithm SHA256).Hash | Should -Be $parentHash
        $entry = @((Get-Content -LiteralPath $r.RunMetaPath -Raw | ConvertFrom-Json).Collections | Where-Object { $_.Collection -eq 'HOST01' })[0]
        $entry.ImagePath | Should -Be $parent
        $entry.ImageSha256Before | Should -BeExactly $parentHash
        $entry.ImageSha256After | Should -BeExactly $parentHash
        $entry.ImageHashMatch | Should -BeTrue
    }

    It 'gives Hayabusa only winevt\Logs on a full-disk image, says so under the Mount step and leaves the parent unchanged' {
        $hb = New-FakeHayabusa -Directory (Join-TestPath $TestDrive 'tool-full')
        $out = Join-TestPath $TestDrive 'out-full'
        $r = & $MainScript -PassThru -InputRoot $inFull -OutputRoot $out -HayabusaPath $hb -WarningAction SilentlyContinue
        $row = (Get-RunManifest -Path $r.ManifestPath)['HOST02']
        $row.Status | Should -Be 'Completed'
        $row.Host | Should -Be 'WS02'
        $row.High | Should -Be '1'

        $argv = @(Get-Content -LiteralPath (Join-TestPath $out 'HOST02' 'HOST02_timeline.args'))
        $at = [array]::IndexOf($argv, '-d')
        $at | Should -BeGreaterOrEqual 0
        $argv[$at + 1] | Should -BeLike '*\Windows\System32\winevt\Logs' -Because 'Hayabusa reads only the Logs folder of a full disk'

        $text = @(Get-Content -LiteralPath $r.RunLogPath -Encoding UTF8 | ForEach-Object { $_.Substring(21) })
        $mount = @($text | Where-Object { $_ -like '      Mount *' })
        $mount.Count | Should -Be 1
        $mount[0] | Should -Match '^      Mount +done, winevt\\Logs only +\d+s$'
        $text[[array]::IndexOf($text, $mount[0]) + 1] | Should -BeExactly "      Only Windows\System32\winevt\Logs was read, so event logs moved elsewhere on this volume weren't." -Because 'the note sits right under the Mount step'

        @(Get-ChildItem -LiteralPath (Join-TestPath $out '_diff') -Force -ErrorAction SilentlyContinue).Count | Should -Be 0
        Test-ImageAttached -ImagePath $fullParent | Should -BeFalse
        (Get-FileHash -LiteralPath $fullParent -Algorithm SHA256).Hash | Should -Be $fullParentHash
    }
}
