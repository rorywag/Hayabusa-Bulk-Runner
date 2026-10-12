BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers/TestHelpers.ps1')
    $script:zin = New-TestDirectory (Join-TestPath $TestDrive 'zips')
    New-TestZip -Path (Join-TestPath $zin 'H1.zip') -Entries ([ordered]@{ 'disk.vhdx' = (New-TestByteArray 10) }) | Out-Null
    New-TestZip -Path (Join-TestPath $zin 'PLAIN.zip') -Entries ([ordered]@{ 'x.evtx' = (New-TestByteArray 10 -Random) }) | Out-Null
    $bad = New-TestZip -Path (Join-TestPath $zin 'BAD.zip') -Entries ([ordered]@{ 'Container/BAD.vhdx' = (New-TestByteArray 10) })
    Edit-ZipHeader -Path $bad -Method 9
    Write-TestText -Path (Join-TestPath $zin 'RAW.vhdx') -Line @('x') | Out-Null
    $script:cols = @{}
    Get-InputCollection -InputRoot $zin -WarningAction SilentlyContinue | ForEach-Object { $cols[$_.Collection] = $_ }
}

Describe 'Collections needing a mount' {
    It 'lists raw images and readable zips with an image, never unreadable zips' {
        $n = @(Get-CollectionNeedingMount -Collections @($cols.Values))
        (($n | ForEach-Object { $_.Collection.Collection } | Sort-Object) -join ',') | Should -Be 'H1,RAW'
    }
}

Describe 'Elevation pre-check' {
    It 'fails off Windows when an image is nested in a zip' {
        Mock Test-IsWindowsHost { $false }
        Get-ThrownMessage { Assert-ElevationForContainer -Collections @($cols.H1) } | Should -BeLike '*H1.zip (contains disk.vhdx)*requires Windows*'
    }
    It 'fails on Windows without elevation, naming diskpart' {
        Mock Test-IsWindowsHost { $true }
        Mock Test-IsElevated { $false }
        $m = Get-ThrownMessage { Assert-ElevationForContainer -Collections @($cols.H1) }
        $m | Should -BeLike '*1 collection(s) with disk images*H1.zip (contains disk.vhdx)*'
        $m | Should -BeLike '*Mount-DiskImage and diskpart require an elevated session*'
    }
    It 'passes on Windows with elevation' {
        Mock Test-IsWindowsHost { $true }
        Mock Test-IsElevated { $true }
        { Assert-ElevationForContainer -Collections @($cols.H1, $cols.RAW) } | Should -Not -Throw
    }
    It 'passes without elevation when no collection needs a mount, including an unreadable zip with an image inside' {
        Mock Test-IsWindowsHost { $true }
        Mock Test-IsElevated { $false }
        { Assert-ElevationForContainer -Collections @($cols.PLAIN, $cols.BAD) } | Should -Not -Throw
    }
}
