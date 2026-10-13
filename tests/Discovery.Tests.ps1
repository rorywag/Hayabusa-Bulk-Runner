BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers/TestHelpers.ps1')

    $script:in = New-TestDirectory (Join-TestPath $TestDrive 'in')
    New-TestDirectory (Join-TestPath $in 'HOST01' 'C' 'Windows' 'System32' 'winevt' 'Logs') | Out-Null
    New-TestZip -Path (Join-TestPath $in 'HOST02.zip') -Entries ([ordered]@{ 'C/Windows/System32/winevt/Logs/Security.evtx' = (New-TestByteArray 2048 -Random) }) | Out-Null
    foreach ($f in 'HOST03.VHDX', 'HOST04.vhd', 'notes.txt', 'image.E01', '2026-10-11T080000_ConsoleLog.txt', '2026-10-11T080000_CopyLog.csv', '2026-10-11T080000_SkipLog.csv') {
        Write-TestText -Path (Join-TestPath $in $f) -Line @('x') | Out-Null
    }
    New-TestDirectory (Join-TestPath $in '$RECYCLE.BIN') | Out-Null
    New-TestDirectory (Join-TestPath $in 'System Volume Information') | Out-Null

    $script:canLink = $false
    try {
        $outside = New-TestDirectory (Join-TestPath $TestDrive 'outside')
        New-Item -ItemType SymbolicLink -Path (Join-TestPath $in 'LINKED') -Target $outside -ErrorAction Stop | Out-Null
        $script:canLink = $true
    }
    catch {
        $script:canLink = $false
    }

    $script:w = $null
    $all = @(Get-InputCollection -InputRoot $in -WarningVariable script:w -WarningAction SilentlyContinue -Verbose 4>&1)
    $script:found = @($all | Where-Object { $_ -isnot [System.Management.Automation.VerboseRecord] })
    $script:verbose = @($all | Where-Object { $_ -is [System.Management.Automation.VerboseRecord] } | ForEach-Object { $_.Message })
}

Describe 'Classification' {
    It 'finds folders, zip, vhdx and vhd only, sorted by name' {
        (($found | ForEach-Object { "$($_.Collection)=$($_.InputType)" }) -join ',') | Should -Be 'HOST01=Loose,HOST02=Zip,HOST03=Vhdx,HOST04=Vhd'
    }
    It 'keeps the original entry name as Source' {
        $found[2].Source | Should -Be 'HOST03.VHDX'
    }
    It 'skips KAPE logs quietly' {
        @($w | Where-Object { "$_" -match '_(Console|Copy|Skip)Log' }).Count | Should -Be 0
        @($verbose | Where-Object { $_ -like 'Skipping KAPE log*' }).Count | Should -Be 3
    }
    It 'warns about stray files' {
        @($w | Where-Object { "$_" -like '*notes.txt*not a folder*' }).Count | Should -Be 1
        @($w | Where-Object { "$_" -like '*image.E01*not a folder*' }).Count | Should -Be 1
    }
    It 'skips a symlinked folder with a warning' {
        if (-not $canLink) { Set-ItResult -Skipped -Because 'creating a symbolic link is not permitted here' }
        @($w | Where-Object { "$_" -like '*LINKED*link or junction*' }).Count | Should -Be 1
        $found.Source | Should -Not -Contain 'LINKED'
    }
    It 'skips drive-root system folders' {
        $found.Source | Should -Not -Contain '$RECYCLE.BIN'
        $found.Source | Should -Not -Contain 'System Volume Information'
    }
}

Describe 'Collection names' {
    It 'cleans <Name> to <Expected>' -ForEach @(
        @{ Name = 'HOST 05 (copy).zip'; Type = 'Zip'; Expected = 'HOST_05__copy_' }
        @{ Name = 'CON.zip'; Type = 'Zip'; Expected = '_CON' }
        @{ Name = 'nul.backup'; Type = 'Loose'; Expected = '_nul.backup' }
        @{ Name = 'dir.zip'; Type = 'Loose'; Expected = 'dir.zip' }
        @{ Name = 'trail..'; Type = 'Loose'; Expected = 'trail' }
        @{ Name = 'trail. .'; Type = 'Loose'; Expected = 'trail._' }
        @{ Name = '...'; Type = 'Loose'; Expected = '_' }
        @{ Name = 'WS-01.corp_x.VHDX'; Type = 'Vhdx'; Expected = 'WS-01.corp_x' }
        @{ Name = '-HOST'; Type = 'Loose'; Expected = '-HOST' }
    ) {
        ConvertTo-CollectionName -Name $Name -InputType $Type | Should -BeExactly $Expected
    }
    It 'caps names at 64 characters' {
        (ConvertTo-CollectionName -Name ('a' * 100) -InputType Loose).Length | Should -Be 64
    }
    It 'lists collisions: HOST01 and host01.zip, a b and a_b' {
        $c = New-TestDirectory (Join-TestPath $TestDrive 'collide')
        foreach ($d in 'HOST01', 'a b', 'a_b', 'unique') { New-TestDirectory (Join-TestPath $c $d) | Out-Null }
        New-TestZip -Path (Join-TestPath $c 'host01.zip') -Entries ([ordered]@{ 'a.evtx' = (New-TestByteArray 10 -Random) }) | Out-Null
        $m = Get-ThrownMessage { Assert-UniqueCollectionName -Collections @(Get-InputCollection -InputRoot $c -WarningAction SilentlyContinue) }
        $m | Should -BeLike '*2 collection name(s)*'
        $m | Should -BeLike '*a_b: a b, a_b*'
        $m | Should -BeLike '*HOST01: HOST01, host01.zip*'
    }
    It 'refuses reserved names' {
        $m = Get-ThrownMessage { Assert-CollectionNameAllowed -Collections @([pscustomobject]@{ Collection = '_runs'; Source = '_runs' }, [pscustomobject]@{ Collection = 'Triage_Dashboard.HTML'; Source = 'Triage_Dashboard.HTML' }, [pscustomobject]@{ Collection = '_diff'; Source = '_diff' }) }
        $m | Should -BeLike '*3 InputRoot entr(ies)*_runs -> _runs*Triage_Dashboard.HTML -> Triage_Dashboard.HTML*_diff -> _diff*'
    }
}

Describe 'Layout guards' {
    It 'warns when InputRoot itself is a volume root' {
        $d = New-TestDirectory (Join-TestPath $TestDrive 'deep')
        New-TestDirectory (Join-TestPath $d 'Windows' 'System32' 'winevt' 'Logs') | Out-Null
        New-TestDirectory (Join-TestPath $d 'Users') | Out-Null
        $ww = $null
        Get-InputCollection -InputRoot $d -WarningVariable ww -WarningAction SilentlyContinue | Out-Null
        @($ww | Where-Object { "$_" -like '*looks like a single collection*Windows and Users*' }).Count | Should -Be 1
    }
    It 'warns on a Loose entry that is itself a volume root, and not on a normal one' {
        $d = New-TestDirectory (Join-TestPath $TestDrive 'volroot')
        New-TestDirectory (Join-TestPath $d 'C' 'Windows' 'System32' 'winevt' 'Logs') | Out-Null
        New-TestDirectory (Join-TestPath $d 'HOSTB' 'C' 'Windows' 'System32' 'winevt' 'Logs') | Out-Null
        $c = @(Get-InputCollection -InputRoot $d -WarningAction SilentlyContinue)
        @($c[0].Warnings).Count | Should -Be 1
        $c[0].Warnings[0] | Should -BeLike '*directly contains Windows*'
        @($c[1].Warnings).Count | Should -Be 0
    }
    It 'warns that a disk image inside a folder will not be mounted' {
        $d = New-TestDirectory (Join-TestPath $TestDrive 'imgfolder')
        New-TestDirectory (Join-TestPath $d 'HOST09') | Out-Null
        Write-TestText -Path (Join-TestPath $d 'HOST09' 'HOST09.vhdx') -Line @('x') | Out-Null
        $c = @(Get-InputCollection -InputRoot $d -WarningAction SilentlyContinue)
        $c[0].InputType | Should -Be 'Loose'
        @($c[0].Warnings | Where-Object { $_ -like '*disk image file(s) that will not be mounted: HOST09.vhdx*directly in InputRoot*' }).Count | Should -Be 1
    }
}

Describe 'ZIP peek during discovery' {
    BeforeAll {
        $script:zin = New-TestDirectory (Join-TestPath $TestDrive 'zips')
        New-TestZip -Path (Join-TestPath $zin 'IMG_EVTX.zip') -Entries ([ordered]@{ 'disk/host.vhdx' = (New-TestByteArray 4096); 'logs/Security.evtx' = (New-TestByteArray 100 -Random); 'logs/System.evtx' = (New-TestByteArray 100 -Random) }) | Out-Null
        New-TestZip -Path (Join-TestPath $zin 'TWO_IMG.zip') -Entries ([ordered]@{ 'a.vhdx' = (New-TestByteArray 10); 'b.VHD' = (New-TestByteArray 10) }) | Out-Null
        New-TestZip -Path (Join-TestPath $zin 'NESTED.zip') -Entries ([ordered]@{ 'inner/more.zip' = (New-TestByteArray 10); 'x.evtx' = (New-TestByteArray 10 -Random) }) | Out-Null
        New-TestZip -Path (Join-TestPath $zin 'PLAIN.zip') -Entries ([ordered]@{ 'C/Windows/System32/winevt/Logs/Security.evtx' = (New-TestByteArray 100 -Random) }) | Out-Null
        [System.IO.File]::WriteAllBytes((Join-TestPath $zin 'CORRUPT.zip'), (New-TestByteArray 500 -Random))
        $d64 = New-TestZip -Path (Join-TestPath $zin 'D64.zip') -Entries ([ordered]@{ 'Container/D64.vhdx' = 'parent' })
        Edit-ZipHeader -Path $d64 -Method 9
        $script:zc = @{}
        $zw = $null
        Get-InputCollection -InputRoot $zin -WarningVariable zw -WarningAction SilentlyContinue | ForEach-Object { $zc[$_.Collection] = $_ }
        $script:zipWarnings = @($zw | ForEach-Object { "$_" })
    }
    It 'finds an image nested in a zip without extracting' {
        @($zc.IMG_EVTX.Zip.ImageEntries) | Should -Contain 'disk/host.vhdx'
        Test-Path -LiteralPath (Join-TestPath $zin 'disk') | Should -BeFalse
    }
    It 'warns about skipped evidence beside an image' {
        @($zc.IMG_EVTX.Warnings | Where-Object { $_ -like 'Skipped evidence*2 loose evtx*' }).Count | Should -Be 1
    }
    It 'warns about two images and nested zips' {
        @($zc.TWO_IMG.Warnings | Where-Object { $_ -like '*2 disk images*will fail*' }).Count | Should -Be 1
        @($zc.NESTED.Warnings | Where-Object { $_ -like '*nested ZIP*inner/more.zip*' }).Count | Should -Be 1
    }
    It 'turns an unreadable zip into guidance, not a failure' {
        $zc.CORRUPT.Zip.Readable | Should -BeFalse
        @($zc.CORRUPT.Warnings | Where-Object { $_ -like "CORRUPT.zip can't be extracted by this tool*Extract it yourself, put the extracted folder in InputRoot, and rerun." }).Count | Should -Be 1
    }
    It 'guides an unsupported zip holding an image to the image itself' {
        $zc.D64.Zip.Readable | Should -BeFalse
        $zc.D64.Zip.ReadReason | Should -Be 'Unsupported'
        $zc.D64.Warnings[0] | Should -BeExactly "D64.zip can't be extracted by this tool (unsupported compression or encryption). Extract it yourself, put the extracted disk image (D64.vhdx) directly in InputRoot, and rerun."
    }
    It 'keeps the guidance short: no entry name, method or count' {
        foreach ($c in $zc.CORRUPT, $zc.D64) {
            $c.Warnings[0] | Should -Not -BeLike '*Container/*'
            $c.Warnings[0] | Should -Not -BeLike '*method*'
            $c.Warnings[0] | Should -Not -BeLike '*more entr*'
        }
        $zc.CORRUPT.Warnings[0] | Should -BeLike "CORRUPT.zip can't be extracted by this tool (it could not be read, the file may be damaged).*"
        $zc.D64.Zip.ReadError | Should -BeLike "*entry 'Container/D64.vhdx' uses compression method 9 (Deflate64)*"
    }
    It 'records the guidance on the collection but does not warn about it here' {
        @($zipWarnings | Where-Object { $_ -like "*can't be extracted*" }).Count | Should -Be 0
        @($zipWarnings | Where-Object { $_ -like 'TWO_IMG.zip: *2 disk images*' }).Count | Should -Be 1
    }
    It 'leaves a plain zip with no warnings' {
        @($zc.PLAIN.Warnings).Count | Should -Be 0
        $zc.PLAIN.Zip.Readable | Should -BeTrue
    }
}

Describe 'A ZIP entry name Windows cannot use in a path' {
    It 'fails only that ZIP, with guidance naming it, and discovery carries on' {
        $root = New-TestDirectory (Join-TestPath $TestDrive 'oddname')
        New-TestDirectory (Join-TestPath $root 'GOOD' 'C' 'Windows' 'System32' 'winevt' 'Logs') | Out-Null
        New-TestZip -Path (Join-TestPath $root 'ODD.zip') -Entries ([ordered]@{ 'C/Windows/a|b.evtx' = 'synthetic' }) | Out-Null
        $c = @(Get-InputCollection -InputRoot $root -WarningAction SilentlyContinue)
        $c.Count | Should -Be 2
        $odd = @($c | Where-Object { $_.Collection -eq 'ODD' })[0]
        $odd.Zip.Readable | Should -BeFalse
        @($odd.Warnings)[0] | Should -BeExactly "ODD.zip can't be extracted by this tool (an entry name isn't valid on Windows). Extract it yourself, put the extracted folder in InputRoot, and rerun."
        @($c | Where-Object { $_.Collection -eq 'GOOD' }).Count | Should -Be 1
    }
}
