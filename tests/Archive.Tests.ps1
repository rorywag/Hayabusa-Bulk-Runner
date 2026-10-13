BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers/TestHelpers.ps1')
    $script:zd = New-TestDirectory (Join-TestPath $TestDrive 'zips')
    function script:New-Plain([string]$Name) {
        New-TestZip -Path (Join-TestPath $zd $Name) -Entries ([ordered]@{ 'logs/a.evtx' = (New-TestByteArray 300 -Random); 'logs/b.evtx' = (New-TestByteArray 200 -Random) })
    }
}

Describe 'Zip slip' {
    It 'refuses <Case> (<Entry>) and writes nothing' -ForEach @(
        @{ Case = 'parent'; Entry = '../evil.txt' }
        @{ Case = 'deep parent'; Entry = 'a/../../evil.txt' }
        @{ Case = 'backslash parent'; Entry = 'a\..\..\evil.txt' }
        @{ Case = 'absolute'; Entry = '/abs.txt' }
        @{ Case = 'UNC'; Entry = '\\server\share\x.txt' }
        @{ Case = 'drive'; Entry = 'C:/x.txt' }
        @{ Case = 'alternate data stream'; Entry = 'file.txt:hidden' }
        @{ Case = 'device folder'; Entry = 'CON/x.txt' }
        @{ Case = 'device name'; Entry = 'logs/aux.evtx' }
        @{ Case = 'wildcard'; Entry = 'bad?.txt' }
        @{ Case = 'trailing dot'; Entry = 'trail./x.txt' }
    ) {
        $zp = New-TestZip -Path (Join-TestPath $zd ("slip{0}.zip" -f [guid]::NewGuid().ToString('N'))) -Entries ([ordered]@{ 'ok/fine.evtx' = (New-TestByteArray 10 -Random); $Entry = (New-TestByteArray 10 -Random) })
        $dest = Join-TestPath $zd ('x' + [guid]::NewGuid().ToString('N'))
        Get-ThrownMessage { Expand-ZipArchiveSafe -Path $zp -Destination $dest -MaxUncompressedBytes 1GB -MaxRatio 250 } | Should -BeLike '*unsafe entry name*'
        Test-Path -LiteralPath $dest | Should -BeFalse
        Test-Path -LiteralPath (Join-TestPath $TestDrive 'evil.txt') | Should -BeFalse
    }
    It 'passes ordinary names' {
        Test-ZipEntryName -Name 'C/Windows/System32/winevt/Logs/Microsoft-Windows-Sysmon%4Operational.evtx' | Should -BeNullOrEmpty
        Test-ZipEntryName -Name './a/b.evtx' | Should -BeNullOrEmpty
    }
}

Describe 'Zip bomb' {
    It 'refuses an archive over the ratio cap, and extracts it with a raised cap' {
        $zp = New-TestZip -Path (Join-TestPath $zd 'ratio.zip') -Entries ([ordered]@{ 'zeros.bin' = (New-TestByteArray (20MB)) })
        Get-ThrownMessage { Expand-ZipArchiveSafe -Path $zp -Destination (Join-TestPath $zd 'r') -MaxUncompressedBytes 1GB -MaxRatio 250 } | Should -BeLike '*compression ratio*over the cap*ZipMaxRatio*'
        Test-Path -LiteralPath (Join-TestPath $zd 'r') | Should -BeFalse
        Expand-ZipArchiveSafe -Path $zp -Destination (Join-TestPath $zd 'r2') -MaxUncompressedBytes 1GB -MaxRatio 100000 | Should -Be (20MB)
        (Get-Item -LiteralPath (Join-TestPath $zd 'r2' 'zeros.bin')).Length | Should -Be (20MB)
    }
    It 'refuses an archive over the size cap' {
        $zp = New-TestZip -Path (Join-TestPath $zd 'size.zip') -Entries ([ordered]@{ 'rand.bin' = (New-TestByteArray (2MB) -Random) })
        Get-ThrownMessage { Expand-ZipArchiveSafe -Path $zp -Destination (Join-TestPath $zd 's') -MaxUncompressedBytes 1MB -MaxRatio 250 } | Should -BeLike '*declared uncompressed size*over the cap*ZipMaxUncompressedGB*'
    }
    It 'never writes past the declared size when a header understates it' {
        $data = New-Object byte[] (2MB)
        for ($i = 0; $i -lt $data.Length; $i++) { $data[$i] = [byte](65 + (($i -shr 10) % 2)) }
        $zp = New-TestZip -Path (Join-TestPath $zd 'lie.zip') -Entries ([ordered]@{ 'big.bin' = $data })
        Edit-ZipHeader -Path $zp -DeclaredSize 1000
        $dest = Join-TestPath $zd 'l'
        $m = Get-ThrownMessage { Expand-ZipArchiveSafe -Path $zp -Destination $dest -MaxUncompressedBytes 1GB -MaxRatio 1000000 }
        if ($null -eq $m) {
            # The runtime stopped reading at the declared size.
            (Get-Item -LiteralPath (Join-TestPath $dest 'big.bin')).Length | Should -Be 1000
        }
        else {
            # The byte counter stopped it and removed the partial extract.
            $m | Should -BeLike '*expanded past its declared size*'
            Test-Path -LiteralPath $dest | Should -BeFalse
        }
    }
}

Describe 'Free space' {
    It 'refuses extraction when there is not enough room' {
        Mock Get-FreeSpace { [long]1 }
        Get-ThrownMessage { Expand-ZipArchiveSafe -Path (New-Plain 'fs.zip') -Destination (Join-TestPath $zd 'fs') -MaxUncompressedBytes 1GB -MaxRatio 250 } | Should -BeLike '*Not enough free space*'
    }
    It 'warns and extracts when free space cannot be read' {
        Mock Get-FreeSpace { $null }
        $w = $null
        Expand-ZipArchiveSafe -Path (New-Plain 'fs2.zip') -Destination (Join-TestPath $zd 'fs2') -MaxUncompressedBytes 1GB -MaxRatio 250 -WarningVariable w -WarningAction SilentlyContinue | Out-Null
        @($w | Where-Object { "$_" -like '*without a free space check*' }).Count | Should -Be 1
        Test-Path -LiteralPath (Join-TestPath $zd 'fs2' 'logs' 'a.evtx') | Should -BeTrue
    }
    It 'reads real free space' {
        Get-FreeSpace -Path $TestDrive | Should -BeGreaterThan 0
    }
}

Describe 'Zip readability' {
    It 'reads a plain Deflate zip as readable' {
        $i = Get-ZipEntryInfo -Path (New-Plain 'plain.zip')
        $i.Readable | Should -BeTrue
        $i.EntryCount | Should -Be 2
        $i.EvtxEntryCount | Should -Be 2
    }
    It 'reads the central directory of a plain zip' {
        $d = Get-ZipCentralDirectory -Path (New-Plain 'cd.zip')
        $d.Ok | Should -BeTrue
        @($d.Entries).Count | Should -Be 2
        @($d.Entries | ForEach-Object { $_.Method } | Sort-Object -Unique) | Should -Be @(8)
    }
    It 'marks compression method <Method> unsupported' -ForEach @(
        @{ Method = 9; Name = 'Deflate64' }, @{ Method = 12; Name = 'BZip2' }, @{ Method = 14; Name = 'LZMA' }, @{ Method = 93; Name = 'Zstandard' }, @{ Method = 77; Name = '77' }
    ) {
        $zp = New-Plain ("m$Method.zip")
        Edit-ZipHeader -Path $zp -Method $Method
        $i = Get-ZipEntryInfo -Path $zp
        $i.Readable | Should -BeFalse
        $i.ReadReason | Should -Be 'Unsupported'
        $i.ReadError | Should -BeLike "*uses compression method $Method*which .NET cannot extract*and 1 more*"
        if ($Name -ne '77') { $i.ReadError | Should -BeLike "*($Name)*" }
    }
    It 'marks AES (method 99) and encrypted entries unsupported' {
        $aes = New-Plain 'aes.zip'; Edit-ZipHeader -Path $aes -Method 99
        (Get-ZipEntryInfo -Path $aes).ReadError | Should -BeLike "*entry 'logs/a.evtx' is encrypted*"
        $enc = New-Plain 'enc.zip'; Edit-ZipHeader -Path $enc -Flags 1
        $i = Get-ZipEntryInfo -Path $enc
        $i.Readable | Should -BeFalse
        $i.ReadError | Should -BeLike '*is encrypted*'
        $strong = New-Plain 'strong.zip'; Edit-ZipHeader -Path $strong -Flags 0x40
        (Get-ZipEntryInfo -Path $strong).Readable | Should -BeFalse
    }
    It 'reads a Zip64 archive' {
        $zp = Join-TestPath $zd 'zip64.zip'
        $fs = [System.IO.File]::Open($zp, [System.IO.FileMode]::CreateNew)
        $z = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
        foreach ($n in 1..3) { $e = $z.CreateEntry("f$n.evtx"); $s = $e.Open(); $s.WriteByte(1); $s.Dispose() }
        $z.Dispose(); $fs.Dispose()
        # Rewrite the end record as Zip64: insert a Zip64 record and locator.
        $b = [System.IO.File]::ReadAllBytes($zp)
        $eocd = $b.Length - 22
        $cdSize = [BitConverter]::ToUInt32($b, $eocd + 12); $cdOffset = [BitConverter]::ToUInt32($b, $eocd + 16)
        $ms = New-Object System.IO.MemoryStream
        $ms.Write($b, 0, $eocd)
        $z64At = $ms.Position
        $rec = New-Object byte[] 56
        [BitConverter]::GetBytes([uint32]0x06064b50).CopyTo($rec, 0); [BitConverter]::GetBytes([uint64]44).CopyTo($rec, 4)
        [BitConverter]::GetBytes([uint64]3).CopyTo($rec, 24); [BitConverter]::GetBytes([uint64]3).CopyTo($rec, 32)
        [BitConverter]::GetBytes([uint64]$cdSize).CopyTo($rec, 40); [BitConverter]::GetBytes([uint64]$cdOffset).CopyTo($rec, 48)
        $ms.Write($rec, 0, 56)
        $loc = New-Object byte[] 20
        [BitConverter]::GetBytes([uint32]0x07064b50).CopyTo($loc, 0); [BitConverter]::GetBytes([uint64]$z64At).CopyTo($loc, 8); [BitConverter]::GetBytes([uint32]1).CopyTo($loc, 16)
        $ms.Write($loc, 0, 20)
        $end = New-Object byte[] 22
        [Array]::Copy($b, $eocd, $end, 0, 22)
        [BitConverter]::GetBytes([uint16]0xFFFF).CopyTo($end, 8); [BitConverter]::GetBytes([uint16]0xFFFF).CopyTo($end, 10)
        [BitConverter]::GetBytes([uint32]::MaxValue).CopyTo($end, 12); [BitConverter]::GetBytes([uint32]::MaxValue).CopyTo($end, 16)
        $ms.Write($end, 0, 22)
        [System.IO.File]::WriteAllBytes($zp, $ms.ToArray())
        $d = Get-ZipCentralDirectory -Path $zp
        $d.Error | Should -BeNullOrEmpty
        $d.Ok | Should -BeTrue
        @($d.Entries).Count | Should -Be 3
    }
}

Describe 'Zip readability fails safe' {
    It 'treats <Case> as unreadable with guidance' -ForEach @(
        @{ Case = 'a zero-byte file'; Make = { param($p) [System.IO.File]::WriteAllBytes($p, (New-Object byte[] 0)) } }
        @{ Case = 'random bytes'; Make = { param($p) [System.IO.File]::WriteAllBytes($p, (New-TestByteArray 4000 -Random)) } }
        @{ Case = 'a truncated central directory'; Make = { param($p) $b = [System.IO.File]::ReadAllBytes((New-Plain ('t' + [guid]::NewGuid().ToString('N') + '.zip'))); $cd = Find-ZipSignature $b 0x02014b50; $out = New-Object byte[] ($b.Length - 30); [Array]::Copy($b, 0, $out, 0, $cd + 10); [Array]::Copy($b, $cd + 40, $out, $cd + 10, $b.Length - $cd - 40); [System.IO.File]::WriteAllBytes($p, $out) } }
        @{ Case = 'a bad central header signature'; Make = { param($p) $b = [System.IO.File]::ReadAllBytes((New-Plain ('s' + [guid]::NewGuid().ToString('N') + '.zip'))); $cd = Find-ZipSignature $b 0x02014b50; $b[$cd] = 0; [System.IO.File]::WriteAllBytes($p, $b) } }
        @{ Case = 'an entry count larger than the headers present'; Make = { param($p) $b = [System.IO.File]::ReadAllBytes((New-Plain ('c' + [guid]::NewGuid().ToString('N') + '.zip'))); $e = $b.Length - 22; [BitConverter]::GetBytes([uint16]9).CopyTo($b, $e + 8); [BitConverter]::GetBytes([uint16]9).CopyTo($b, $e + 10); [System.IO.File]::WriteAllBytes($p, $b) } }
        @{ Case = 'a directory offset beyond the end of the file'; Make = { param($p) $b = [System.IO.File]::ReadAllBytes((New-Plain ('o' + [guid]::NewGuid().ToString('N') + '.zip'))); $e = $b.Length - 22; [BitConverter]::GetBytes([uint32]($b.Length + 1000)).CopyTo($b, $e + 16); [System.IO.File]::WriteAllBytes($p, $b) } }
        @{ Case = 'a Zip64 marker with no locator'; Make = { param($p) $b = [System.IO.File]::ReadAllBytes((New-Plain ('z' + [guid]::NewGuid().ToString('N') + '.zip'))); $e = $b.Length - 22; [BitConverter]::GetBytes([uint32]::MaxValue).CopyTo($b, $e + 16); [System.IO.File]::WriteAllBytes($p, $b) } }
        @{ Case = 'a spanned archive'; Make = { param($p) $b = [System.IO.File]::ReadAllBytes((New-Plain ('m' + [guid]::NewGuid().ToString('N') + '.zip'))); $e = $b.Length - 22; [BitConverter]::GetBytes([uint16]1).CopyTo($b, $e + 4); [System.IO.File]::WriteAllBytes($p, $b) } }
    ) {
        $p = Join-TestPath $zd ("bad{0}.zip" -f [guid]::NewGuid().ToString('N'))
        & $Make $p
        $d = Get-ZipCentralDirectory -Path $p
        $d.Ok | Should -BeFalse
        $d.Error | Should -Not -BeNullOrEmpty
        $i = Get-ZipEntryInfo -Path $p
        $i.Readable | Should -BeFalse
        $i.ReadReason | Should -BeIn @('Unparseable', 'Corrupt')
        Get-ZipGuidance -Source 'X.zip' -Info $i | Should -BeLike "X.zip can't be extracted by this tool*Extract it yourself*"
    }
    It 'reports a missing file as unreadable, never throws' {
        $d = Get-ZipCentralDirectory -Path (Join-TestPath $zd 'nope.zip')
        $d.Ok | Should -BeFalse
    }
}

Describe 'Extraction-time guard' {
    It 'replaces the raw .NET unsupported-method error with guidance' {
        $zp = New-Plain 'bz.zip'
        Edit-ZipHeader -Path $zp -Method 12
        $m = Get-ThrownMessage { Expand-ZipArchiveSafe -Path $zp -Destination (Join-TestPath $zd 'bz') -MaxUncompressedBytes 1GB -MaxRatio 250 }
        $m | Should -BeLike "bz.zip can't be extracted by this tool (unsupported compression or encryption). Extract it yourself*InputRoot*"
        $m | Should -Not -BeLike '*BZip2*'
        Test-Path -LiteralPath (Join-TestPath $zd 'bz') | Should -BeFalse
    }
}

Describe 'Short guidance text' {
    It 'gives <Reason> the reason "<Text>"' -ForEach @(
        @{ Reason = 'Unsupported'; Text = 'unsupported compression or encryption' }
        @{ Reason = 'Unparseable'; Text = 'it could not be read, the file may be damaged' }
        @{ Reason = 'Corrupt'; Text = 'it could not be read, the file may be damaged' }
    ) {
        Get-ZipReadReasonText -Info ([pscustomobject]@{ ReadReason = $Reason }) | Should -BeExactly $Text
    }
    It 'leaves out the entry and the count, which stay in ReadError' {
        $info = [pscustomobject]@{ ReadReason = 'Unsupported'; ReadError = "entry 'logs/a.evtx' uses compression method 9 (Deflate64), which .NET cannot extract, and 3 more entries have the same problem"; ImageEntries = @() }
        Get-ZipGuidance -Source 'H.zip' -Info $info | Should -BeExactly "H.zip can't be extracted by this tool (unsupported compression or encryption). Extract it yourself, put the extracted folder in InputRoot, and rerun."
    }
    It 'names the image to put in InputRoot when the zip holds one' {
        $info = [pscustomobject]@{ ReadReason = 'Unsupported'; ReadError = 'x'; ImageEntries = @('Container/H.vhdx') }
        Get-ZipGuidance -Source 'H.zip' -Info $info | Should -BeExactly "H.zip can't be extracted by this tool (unsupported compression or encryption). Extract it yourself, put the extracted disk image (H.vhdx) directly in InputRoot, and rerun."
    }
}

Describe 'Long paths' {
    BeforeAll {
        $script:lp = New-TestDirectory (Join-TestPath $TestDrive 'longpath')
        # Shaped like KAPE's WER report archives, which run past 260 characters.
        $script:deepEntry = 'C/ProgramData/Microsoft/Windows/WER/ReportArchive/' + 'AppCrash_' + ('x' * 120) + '/' + 'Report_' + ('y' * 100) + '/Report.wer'
        # Windows PowerShell 5.1 may run with legacy path handling, which
        # refuses long paths outright. Everywhere else the deep entry must extract.
        $script:mayRefuseLongPaths = $TestOnWindows -and $PSVersionTable.PSVersion.Major -lt 6
    }

    It 'extracts an entry past 260 characters, and teardown removes it' {
        $zp = New-TestZip -Path (Join-TestPath $lp 'deep.zip') -Entries ([ordered]@{ $deepEntry = 'synthetic'; 'C/Windows/System32/winevt/Logs/Security.evtx' = (New-TestByteArray 50 -Random) })
        $dest = Join-TestPath $lp 'deep-out'
        ($dest.Length + 1 + $deepEntry.Length) | Should -BeGreaterThan 300
        $m = Get-ThrownMessage { Expand-ZipArchiveSafe -Path $zp -Destination $dest -MaxUncompressedBytes 1GB -MaxRatio 250 }
        if ($null -eq $m) {
            $tree = @(Get-FileTree -Path $dest)
            @($tree | Where-Object { $_.Name -eq 'Report.wer' }).Count | Should -Be 1
            @($tree | Where-Object { $_.Name -eq 'Security.evtx' }).Count | Should -Be 1
            @($tree | Where-Object { $_.FullName.StartsWith('\\?\') }).Count | Should -Be 0
            Remove-CollectionExtract -Path $dest -WorkRoot $lp
            Test-Path -LiteralPath $dest | Should -BeFalse
        }
        else {
            $mayRefuseLongPaths | Should -BeTrue -Because "only Windows PowerShell 5.1 may refuse long paths, but got: $m"
            $m | Should -BeLike "deep.zip can't be extracted here: some of its paths are longer than Windows allows (the longest needs * characters). Point OutputRoot at a shorter folder*"
            Test-Path -LiteralPath $dest | Should -BeFalse
        }
    }

    It 'gives guidance, not a raw .NET error, for a name Windows cannot hold' {
        $zp = New-TestZip -Path (Join-TestPath $lp 'longname.zip') -Entries ([ordered]@{ ('C/' + ('n' * 300) + '.evtx') = 'synthetic' })
        $dest = Join-TestPath $lp 'longname-out'
        $m = Get-ThrownMessage { Expand-ZipArchiveSafe -Path $zp -Destination $dest -MaxUncompressedBytes 1GB -MaxRatio 250 }
        $m | Should -BeExactly "longname.zip can't be extracted here: one of its names is 305 characters, longer than the 255 Windows allows. Extract it yourself with a tool that can shorten or skip that entry, put the extracted folder in InputRoot, and rerun."
        Test-Path -LiteralPath $dest | Should -BeFalse
    }

    It 'reports an unrelated error on a deep ZIP as itself, not as a long path' {
        $zp = Join-TestPath $lp 'dupe.zip'
        $fs = [System.IO.File]::Open($zp, [System.IO.FileMode]::CreateNew)
        $za = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
        foreach ($i in 1..2) {
            $w = New-Object System.IO.StreamWriter($za.CreateEntry($deepEntry).Open())
            $w.Write('synthetic')
            $w.Dispose()
        }
        $za.Dispose()
        $fs.Dispose()
        $dest = Join-TestPath $lp 'dupe-out'
        $m = Get-ThrownMessage { Expand-ZipArchiveSafe -Path $zp -Destination $dest -MaxUncompressedBytes 1GB -MaxRatio 250 }
        if ($mayRefuseLongPaths -and $m -like "dupe.zip can't be extracted here*") {
            Set-ItResult -Skipped -Because 'this runtime refuses the deep path before the duplicate entry is reached'
            return
        }
        $m | Should -BeLike '*already exists*'
        $m | Should -Not -BeLike "*can't be extracted here*"
        Test-Path -LiteralPath $dest | Should -BeFalse
    }

    Context 'When the path cannot even be resolved, as on Windows PowerShell 5.1' {
        BeforeAll {
            $script:longName = 'C/' + ('r' * 300) + '.evtx'
            Mock Get-SafeEntryTarget { throw (New-Object System.IO.PathTooLongException 'The specified path, file name, or both are too long.') } -ParameterFilter { $Name -eq $longName }
        }

        It 'gives the same guidance, not an unsafe-name refusal' {
            $zp = New-TestZip -Path (Join-TestPath $lp 'unresolved.zip') -Entries ([ordered]@{ $longName = 'synthetic'; 'C/Windows/a.evtx' = 'synthetic' })
            $dest = Join-TestPath $lp 'unresolved-out'
            $m = Get-ThrownMessage { Expand-ZipArchiveSafe -Path $zp -Destination $dest -MaxUncompressedBytes 1GB -MaxRatio 250 }
            $m | Should -BeExactly "unresolved.zip can't be extracted here: one of its names is 305 characters, longer than the 255 Windows allows. Extract it yourself with a tool that can shorten or skip that entry, put the extracted folder in InputRoot, and rerun."
            Test-Path -LiteralPath $dest | Should -BeFalse
        }

        It 'still refuses an unsafe name in the same archive as unsafe' {
            $zp = New-TestZip -Path (Join-TestPath $lp 'unresolved-slip.zip') -Entries ([ordered]@{ $longName = 'synthetic'; 'a/../../evil.txt' = 'synthetic' })
            $dest = Join-TestPath $lp 'unresolved-slip-out'
            $m = Get-ThrownMessage { Expand-ZipArchiveSafe -Path $zp -Destination $dest -MaxUncompressedBytes 1GB -MaxRatio 250 }
            $m | Should -BeLike "Archive refused, 1 unsafe entry name(s): 'a/../../evil.txt': parent directory segment"
            Test-Path -LiteralPath $dest | Should -BeFalse
        }
    }

    It 'describes the failure without throwing, whatever it is given' {
        $none = Get-ZipPathMeasure -Archive $null -Destination $null
        $none.LongestPath | Should -Be 0
        $none.LongestName | Should -Be 0
        $odd = Get-ZipPathMeasure -Archive ([pscustomobject]@{ Entries = @([pscustomobject]@{ FullName = $null }, 'not an entry') }) -Destination 'D:\Out'
        $odd.LongestPath | Should -BeGreaterOrEqual 0
        Get-LongPathGuidance -Source 'HOST{1}.zip' -Measure $none | Should -BeExactly "HOST{1}.zip can't be extracted here: some of its paths are longer than Windows allows. Point OutputRoot at a shorter folder such as D:\Out, or extract it yourself nearer the drive root, put the extracted folder in InputRoot, and rerun."
        Get-LongPathGuidance -Source 'X{0}.zip' -Measure ([pscustomobject]@{ LongestPath = 400; LongestName = 300 }) | Should -BeLike 'X{0}.zip*one of its names is 300 characters*'
        Get-LongPathGuidance -Source 'Y.zip' -Measure ([pscustomobject]@{ LongestPath = 287; LongestName = 40 }) | Should -BeLike '*(the longest needs 287 characters)*'
    }

    It 'adds the extended-length prefix on Windows only, and only when needed' {
        $short = 'C:\Case\Out\_work\HOST01'
        $long = 'C:\Case\' + ('a' * 250)
        $unc = '\\server\share\' + ('b' * 250)
        Get-ExtendedLengthPath -Path $short | Should -BeExactly $short
        if ($TestOnWindows) {
            Get-ExtendedLengthPath -Path $long | Should -BeExactly ('\\?\' + $long)
            Get-ExtendedLengthPath -Path $unc | Should -BeExactly ('\\?\UNC\server\share\' + ('b' * 250))
            Get-ExtendedLengthPath -Path $short -Always | Should -BeExactly ('\\?\' + $short)
            Get-ExtendedLengthPath -Path ('\\?\' + $long) | Should -BeExactly ('\\?\' + $long)
        }
        else {
            Get-ExtendedLengthPath -Path $long | Should -BeExactly $long
            Get-ExtendedLengthPath -Path $short -Always | Should -BeExactly $short
        }
        ConvertFrom-ExtendedLengthPath -Path ('\\?\' + $long) | Should -BeExactly $long
        ConvertFrom-ExtendedLengthPath -Path '\\?\UNC\server\share\x' | Should -BeExactly '\\server\share\x'
        ConvertFrom-ExtendedLengthPath -Path $short | Should -BeExactly $short
    }
}

Describe 'Entry names Windows cannot use in a path' {
    BeforeAll { $script:bn = New-TestDirectory (Join-TestPath $TestDrive 'badname') }

    It 'marks the ZIP unreadable, with guidance naming it, for <Label>' -ForEach @(
        @{ Label = 'a pipe'; Entry = 'C/Windows/a|b.evtx' }
        @{ Label = 'a control character'; Entry = ('C/Windows/a' + [char]1 + 'b.evtx') }
        @{ Label = 'a double quote'; Entry = 'C/Windows/a"b.evtx' }
    ) {
        $zp = New-TestZip -Path (Join-TestPath $bn ('{0}.zip' -f [guid]::NewGuid().ToString('N'))) -Entries ([ordered]@{ $Entry = 'synthetic'; 'C/Windows/System32/winevt/Logs/Security.evtx' = 'synthetic' })
        $info = Get-ZipEntryInfo -Path $zp
        $info.Readable | Should -BeFalse
        $info.ReadReason | Should -Be 'BadName'
        Get-ZipGuidance -Source 'BAD.zip' -Info $info | Should -BeExactly "BAD.zip can't be extracted by this tool (an entry name isn't valid on Windows). Extract it yourself, put the extracted folder in InputRoot, and rerun."
    }
    It 'checks a disk image name without throwing, whatever characters it holds' {
        { Test-DiskImageName -Name ('x' + [char]1 + '|"<>.vhdx') } | Should -Not -Throw
        Test-DiskImageName -Name 'C/a|b.VHDX' | Should -BeTrue
        Test-DiskImageName -Name 'C/a|b.evtx' | Should -BeFalse
        Test-DiskImageName -Name 'C/noext' | Should -BeFalse
        Test-DiskImageName -Name 'dir.vhdx/file' | Should -BeFalse
    }
}
