# Mounts a real VHDX. Runs only on Windows in an elevated session; skipped
# everywhere else. Tagged Mount so it can be selected or left out:
#
#     Invoke-Pester -Path tests -TagFilter Mount
#
# The image is built fresh, so it is clean, unlike a KAPE image taken from a
# live host. This checks the mechanism: the parent is never written, the
# differencing child is removed, and nothing is left attached.

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
        $script:in = New-TestDirectory (Join-TestPath $TestDrive 'in')
        $script:parent = Join-TestPath $in 'HOST01.vhdx'

        $scriptFile = Join-TestPath $TestDrive 'create.txt'
        Write-TestText -Path $scriptFile -Line @("create vdisk file=`"$parent`" maximum=64 type=expandable") | Out-Null
        $dp = & (Get-DiskpartPath) /s $scriptFile 2>&1
        if ($LASTEXITCODE -ne 0) { throw "diskpart could not create the test image: $($dp -join ' ')" }

        Mount-DiskImage -ImagePath $parent | Out-Null
        try {
            $disk = Get-DiskImage -ImagePath $parent | Get-Disk
            Initialize-Disk -Number $disk.Number -PartitionStyle MBR
            $part = New-Partition -DiskNumber $disk.Number -UseMaximumSize -AssignDriveLetter
            Format-Volume -Partition $part -FileSystem NTFS -NewFileSystemLabel 'TESTEVID' -Confirm:$false | Out-Null
            $root = "$((Get-Partition -DiskNumber $disk.Number -PartitionNumber $part.PartitionNumber).DriveLetter):\"
            Write-TestText -Path (Join-Path $root 'Windows\System32\winevt\Logs\x.evtx') -Line @('synthetic') | Out-Null
            Write-TestText -Path (Join-Path $root 'fake.behavior') -Line @('EXIT=0', 'CSV=r.csv') | Out-Null
            Write-TestText -Path (Join-Path $root 'r.csv') -Line @($TimelineHeader, (New-TimelineRow 'WS01' 'high' 'RuleA')) | Out-Null
        }
        finally {
            Dismount-DiskImage -ImagePath $parent | Out-Null
        }
        $script:parentHash = (Get-FileHash -LiteralPath $parent -Algorithm SHA256).Hash
    }

    AfterAll {
        foreach ($p in @($parent) + @(Get-ChildItem -Path (Join-TestPath $TestDrive '*' '_diff') -Filter '*.vhdx' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })) {
            if ($p -and (Test-Path -LiteralPath $p) -and (Get-DiskImage -ImagePath $p -ErrorAction SilentlyContinue).Attached) {
                Dismount-DiskImage -ImagePath $p | Out-Null
            }
        }
    }

    It 'resolves to a volume holding the event logs and tears it all down' {
        $out = New-TestDirectory (Join-TestPath $TestDrive 'out')
        $c = @(Get-InputCollection -InputRoot $in -WarningAction SilentlyContinue)
        $c.Count | Should -Be 1
        $c[0].InputType | Should -Be 'Vhdx'
        $r = Resolve-CollectionInput -Collection $c[0] -OutputRoot $out -MaxUncompressedBytes 1GB -MaxRatio 250
        try {
            Test-Path -LiteralPath (Join-Path $r.Path 'Windows\System32\winevt\Logs\x.evtx') | Should -BeTrue
            $r.ChildPath | Should -Be (Join-TestPath $out '_diff' 'HOST01.vhdx')
            Test-ImageAttached -ImagePath $r.ChildPath | Should -BeTrue
            Test-ImageAttached -ImagePath $parent | Should -BeFalse
        }
        finally {
            Invoke-CollectionCleanup -Resolved $r
        }
        Test-Path -LiteralPath $r.ChildPath | Should -BeFalse
        Test-ImageAttached -ImagePath $parent | Should -BeFalse
        (Get-FileHash -LiteralPath $parent -Algorithm SHA256).Hash | Should -Be $parentHash
    }

    It 'runs the whole tool against it and leaves the parent unchanged' {
        $hb = New-FakeHayabusa -Directory (Join-TestPath $TestDrive 'tool')
        $out = Join-TestPath $TestDrive 'out-main'
        $r = & $MainScript -InputRoot $in -OutputRoot $out -HayabusaPath $hb -WarningAction SilentlyContinue
        $row = (Get-RunManifest -Path $r.ManifestPath)['HOST01']
        $row.Status | Should -Be 'Completed'
        $row.Host | Should -Be 'WS01'
        $row.High | Should -Be '1'
        @(Get-ChildItem -LiteralPath (Join-TestPath $out '_diff') -Force -ErrorAction SilentlyContinue).Count | Should -Be 0
        Test-ImageAttached -ImagePath $parent | Should -BeFalse
        (Get-FileHash -LiteralPath $parent -Algorithm SHA256).Hash | Should -Be $parentHash
    }
}
