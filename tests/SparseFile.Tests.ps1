# Files a Velociraptor offline collector stored sparse, rebuilt from their
# .idx index before RECmd reads them. Every file here is synthetic, built
# at test time. No hive is read.

BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers/TestHelpers.ps1')
    . (Join-Path $PSScriptRoot 'Helpers/IdentityHelpers.ps1')

    function script:Get-Sha([byte[]]$Bytes) {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { return ([System.BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '') }
        finally { $sha.Dispose() }
    }

    function script:Get-Slice([byte[]]$Bytes, [int]$Start, [int]$Count) {
        $out = New-Object byte[] $Count
        [System.Array]::Copy($Bytes, $Start, $out, 0, $Count)
        return , $out
    }

    function script:Test-AllZero([byte[]]$Bytes) {
        foreach ($b in $Bytes) { if ($b -ne 0) { return $false } }
        return $true
    }

    $script:n = 0
    function script:New-Case([string]$Name) {
        $script:n++
        return (New-TestDirectory (Join-TestPath $TestDrive "case$n-$Name"))
    }
}

Describe 'Read-SparseIndex' {
    It 'reads the index format a Velociraptor offline collector writes' {
        $d = New-Case 'format'
        $idx = Write-TestText -Path (Join-TestPath $d 'SYSTEM.idx') -Line @('{"ranges":[', '  {"file_length":2203648,"length":2203648},', '  {"file_offset":2203648,"original_offset":2203648,"length":155648}', ']}')
        $r = Read-SparseIndex -Path $idx -MaxBytes $MaxHiveBytes
        $r.Error | Should -BeNullOrEmpty
        $r.OriginalSize | Should -Be (2203648 + 155648)
        $r.DataBytes | Should -Be 2203648
        @($r.Ranges).Count | Should -Be 2
        $r.Ranges[0].IsData | Should -BeTrue
        $r.Ranges[0].FileOffset | Should -Be 0 -Because 'file_offset defaults to 0'
        $r.Ranges[0].OriginalOffset | Should -Be 0 -Because 'original_offset defaults to 0'
        $r.Ranges[1].IsData | Should -BeFalse -Because 'a range without file_length is a hole'
    }

    It 'refuses <Why>, without throwing' -ForEach @(
        @{ Why = 'text that is not JSON'; Json = '{ranges:'; Like = "*isn't valid JSON*" }
        @{ Why = 'an index with no ranges'; Json = '{"x":1}'; Like = '*no list of ranges*' }
        @{ Why = 'ranges that are not a list'; Json = '{"ranges":{"length":1}}'; Like = '*no list of ranges*' }
        @{ Why = 'an empty list of ranges'; Json = '{"ranges":[]}'; Like = '*no list of ranges*' }
        @{ Why = 'a range that is not an object'; Json = '{"ranges":[[1,2]]}'; Like = '*range 0 has no length*' }
        @{ Why = 'a range with no length'; Json = '{"ranges":[{"file_offset":0}]}'; Like = '*range 0 has no length*' }
        @{ Why = 'a negative length'; Json = '{"ranges":[{"length":-5}]}'; Like = '*range 0 length is -5, which is negative*' }
        @{ Why = 'a length given as text'; Json = '{"ranges":[{"length":"10"}]}'; Like = '*range 0 length is not a number*' }
        @{ Why = 'a length that is not whole'; Json = '{"ranges":[{"length":1.5}]}'; Like = '*not a whole number*' }
        @{ Why = 'a negative offset'; Json = '{"ranges":[{"original_offset":-1,"length":4}]}'; Like = '*original_offset is -1, which is negative*' }
        @{ Why = 'a file_length that is not its length'; Json = '{"ranges":[{"file_length":10,"length":12}]}'; Like = '*file_length of 10 but a length of 12*' }
        @{ Why = 'a wildly large number'; Json = '{"ranges":[{"length":1e300}]}'; Like = '*over the limit*' }
        @{ Why = 'a number too big for 64 bits'; Json = '{"ranges":[{"length":99999999999999999999999}]}'; Like = '*over the limit*' }
    ) {
        $d = New-Case 'bad'
        $idx = Write-TestText -Path (Join-TestPath $d 'SAM.idx') -Line @($Json)
        $r = Read-SparseIndex -Path $idx -MaxBytes $MaxHiveBytes
        $r.Error | Should -BeLike $Like
    }

    It 'refuses an index claiming an original size over the limit for hives' {
        $d = New-Case 'huge'
        $one = Read-SparseIndex -Path (Write-TestText -Path (Join-TestPath $d 'a.idx') -Line @('{"ranges":[{"length":3000000000}]}')) -MaxBytes $MaxHiveBytes
        $one.Error | Should -BeLike "*length is 3000000000, over the limit of $MaxHiveBytes*"
        $end = Read-SparseIndex -Path (Write-TestText -Path (Join-TestPath $d 'b.idx') -Line @("{`"ranges`":[{`"original_offset`":$MaxHiveBytes,`"length`":1}]}")) -MaxBytes $MaxHiveBytes
        $end.Error | Should -BeLike "*ends at byte $($MaxHiveBytes + 1), over the limit of $MaxHiveBytes*"
    }

    It 'refuses an index file too big to be one, without reading it' {
        $d = New-Case 'bigidx'
        $was = $MaxSparseIndexBytes
        try {
            $script:MaxSparseIndexBytes = 64
            $idx = Write-TestText -Path (Join-TestPath $d 'x.idx') -Line @('{"ranges":[' + ((1..20 | ForEach-Object { '{"length":1}' }) -join ',') + ']}')
            (Read-SparseIndex -Path $idx -MaxBytes $MaxHiveBytes).Error | Should -BeLike '*too big to be a sparse index*'
        }
        finally {
            $script:MaxSparseIndexBytes = $was
        }
    }
}

Describe 'Rebuilding a file stored sparse' {
    It 'puts each data range back at its original offset across a mid-file hole and a trailing one, holes as zeros' {
        $d = New-Case 'midhole'
        $a = New-TestPattern 5000 1
        $b = New-TestPattern 7000 2
        $src = Join-TestPath $d 'SYSTEM'
        $expected = New-SparseTestFile -Path $src -Segment @($a, 3000, $b, 2000)
        (Get-Item -LiteralPath $src).Length | Should -Be 12000 -Because 'the stored file has the holes taken out'
        $dest = Join-TestPath $d 'out' 'SYSTEM'
        New-TestDirectory (Split-Path -Parent $dest) | Out-Null
        $r = Copy-IdentityFile -Source $src -Destination $dest
        $r.Rehydrated | Should -BeTrue
        @($r.Notes).Count | Should -Be 0
        $got = [System.IO.File]::ReadAllBytes($dest)
        $got.Length | Should -Be 17000
        Get-Sha (Get-Slice $got 0 5000) | Should -BeExactly (Get-Sha $a)
        Test-AllZero (Get-Slice $got 5000 3000) | Should -BeTrue -Because 'the mid-file hole is zeros'
        Get-Sha (Get-Slice $got 8000 7000) | Should -BeExactly (Get-Sha $b) -Because 'data after a hole moves back to its original offset'
        Test-AllZero (Get-Slice $got 15000 2000) | Should -BeTrue -Because 'the trailing hole is zeros'
        Get-Sha $got | Should -BeExactly (Get-Sha $expected)
        @(Get-ChildItem -LiteralPath (Split-Path -Parent $dest) -Filter '*.tmp').Count | Should -Be 0
        ([System.IO.File]::GetAttributes($dest) -band [System.IO.FileAttributes]::ReadOnly) | Should -Be 0
    }

    It 'rebuilds the shape in the example index: data from offset 0, then a hole to the end' {
        $d = New-Case 'example'
        $a = New-TestPattern 4096 3
        $src = Join-TestPath $d 'SOFTWARE'
        [System.IO.File]::WriteAllBytes($src, $a)
        Write-TestText -Path ($src + '.idx') -Line @('{"ranges":[{"file_length":4096,"length":4096},{"file_offset":4096,"original_offset":4096,"length":1024}]}') | Out-Null
        $dest = Join-TestPath $d 'SOFTWARE.out'
        (Copy-IdentityFile -Source $src -Destination $dest).Rehydrated | Should -BeTrue
        $got = [System.IO.File]::ReadAllBytes($dest)
        $got.Length | Should -Be 5120
        Get-Sha (Get-Slice $got 0 4096) | Should -BeExactly (Get-Sha $a)
        Test-AllZero (Get-Slice $got 4096 1024) | Should -BeTrue
    }

    It 'takes a first range with no file_offset or original_offset to start at 0' {
        $d = New-Case 'defaults'
        $a = New-TestPattern 300 4
        $src = Join-TestPath $d 'SAM'
        [System.IO.File]::WriteAllBytes($src, $a)
        Write-TestText -Path ($src + '.idx') -Line @('{"ranges":[{"file_length":300,"length":300}]}') | Out-Null
        $dest = Join-TestPath $d 'SAM.out'
        (Copy-IdentityFile -Source $src -Destination $dest).Rehydrated | Should -BeTrue
        Get-Sha ([System.IO.File]::ReadAllBytes($dest)) | Should -BeExactly (Get-Sha $a)
    }

    It 'streams a range bigger than its buffer in chunks' {
        $d = New-Case 'chunks'
        $a = New-TestPattern 3500 5
        $b = New-TestPattern 2600 6
        $src = Join-TestPath $d 'SYSTEM'
        $expected = New-SparseTestFile -Path $src -Segment @($a, 1000, $b)
        $was = $SparseCopyBufferBytes
        try {
            $script:SparseCopyBufferBytes = 512
            $dest = Join-TestPath $d 'SYSTEM.out'
            (Copy-IdentityFile -Source $src -Destination $dest).Rehydrated | Should -BeTrue
            Get-Sha ([System.IO.File]::ReadAllBytes($dest)) | Should -BeExactly (Get-Sha $expected)
        }
        finally {
            $script:SparseCopyBufferBytes = $was
        }
    }

    It 'finds the index whatever its case' {
        $d = New-Case 'case'
        $src = Join-TestPath $d 'SYSTEM'
        $expected = New-SparseTestFile -Path $src -Segment @((New-TestPattern 100 7), 50) -IndexPath (Join-TestPath $d 'system.IDX')
        $dest = Join-TestPath $d 'SYSTEM.out'
        (Copy-IdentityFile -Source $src -Destination $dest).Rehydrated | Should -BeTrue
        [System.IO.File]::ReadAllBytes($dest).Length | Should -Be $expected.Length
    }

    It 'copies a file with no index byte for byte, as KAPE collects it' {
        $d = New-Case 'plain'
        $a = New-TestPattern 9000 8
        $src = Join-TestPath $d 'SYSTEM'
        [System.IO.File]::WriteAllBytes($src, $a)
        $dest = Join-TestPath $d 'SYSTEM.out'
        $r = Copy-IdentityFile -Source $src -Destination $dest
        $r.Rehydrated | Should -BeFalse
        @($r.Notes).Count | Should -Be 0
        Get-Sha ([System.IO.File]::ReadAllBytes($dest)) | Should -BeExactly (Get-Sha $a)
    }

    It 'falls back to a plain copy with a note when the index is malformed, without throwing' {
        $d = New-Case 'malformed'
        $a = New-TestPattern 6000 9
        $src = Join-TestPath $d 'SAM'
        [System.IO.File]::WriteAllBytes($src, $a)
        Write-TestText -Path ($src + '.idx') -Line @('{"ranges":[{"file_length":10,"length":"x"}') | Out-Null
        $dest = Join-TestPath $d 'SAM.out'
        $r = Copy-IdentityFile -Source $src -Destination $dest
        $r.Rehydrated | Should -BeFalse
        @($r.Notes) | Should -HaveCount 1
        $r.Notes[0] | Should -BeLike "The sparse index beside SAM, SAM.idx, couldn't be used: *SAM was copied as collected, so RECmd may not be able to read it."
        Get-Sha ([System.IO.File]::ReadAllBytes($dest)) | Should -BeExactly (Get-Sha $a)
    }

    It 'falls back to a plain copy, never allocating the size, when the index claims more than the hive limit' {
        $d = New-Case 'overcap'
        $a = New-TestPattern 4096 10
        $src = Join-TestPath $d 'SOFTWARE'
        [System.IO.File]::WriteAllBytes($src, $a)
        Write-TestText -Path ($src + '.idx') -Line @("{`"ranges`":[{`"file_length`":4096,`"length`":4096},{`"original_offset`":4096,`"length`":$MaxHiveBytes}]}") | Out-Null
        $dest = Join-TestPath $d 'SOFTWARE.out'
        $r = Copy-IdentityFile -Source $src -Destination $dest
        $r.Rehydrated | Should -BeFalse
        $r.Notes[0] | Should -BeLike '*over the limit*'
        (Get-Item -LiteralPath $dest).Length | Should -Be 4096
    }

    It 'never reads past the end of the stored file, and says so' {
        $d = New-Case 'short'
        $a = New-TestPattern 5000 11
        $src = Join-TestPath $d 'SYSTEM'
        [System.IO.File]::WriteAllBytes($src, $a)
        Write-TestText -Path ($src + '.idx') -Line @('{"ranges":[{"file_length":8000,"length":8000}]}') | Out-Null
        $dest = Join-TestPath $d 'SYSTEM.out'
        $r = Copy-IdentityFile -Source $src -Destination $dest
        $r.Rehydrated | Should -BeTrue
        $r.Notes[0] | Should -BeExactly 'The sparse index of SYSTEM points past the end of the file as collected, so 3000 byte(s) it lists were left as zeros.'
        $got = [System.IO.File]::ReadAllBytes($dest)
        $got.Length | Should -Be 8000
        Get-Sha (Get-Slice $got 0 5000) | Should -BeExactly (Get-Sha $a)
        Test-AllZero (Get-Slice $got 5000 3000) | Should -BeTrue
    }

    It 'notes a stored file that holds more than its index lists' {
        $d = New-Case 'extra'
        $src = Join-TestPath $d 'SYSTEM'
        [System.IO.File]::WriteAllBytes($src, (New-TestPattern 5000 12))
        Write-TestText -Path ($src + '.idx') -Line @('{"ranges":[{"file_length":4000,"length":4000},{"original_offset":4000,"length":100}]}') | Out-Null
        $r = Copy-IdentityFile -Source $src -Destination (Join-TestPath $d 'SYSTEM.out')
        $r.Rehydrated | Should -BeTrue
        $r.Notes[0] | Should -BeExactly 'The sparse index of SYSTEM lists 4000 bytes of data, but the file as collected is 5000 bytes.'
    }

    It 'leaves the stored file and its index as they were' {
        $d = New-Case 'untouched'
        $src = Join-TestPath $d 'SYSTEM'
        New-SparseTestFile -Path $src -Segment @((New-TestPattern 2000 13), 500, (New-TestPattern 1000 14)) | Out-Null
        $before = Get-FileHashMap -Path $d
        Copy-IdentityFile -Source $src -Destination (Join-TestPath $TestDrive "untouched-$n.out") | Out-Null
        $after = Get-FileHashMap -Path $d
        $after.Count | Should -Be $before.Count
        foreach ($k in $before.Keys) { $after[$k] | Should -BeExactly $before[$k] }
    }
}
