# Builds a small throwaway registry hive file from scratch, for the RECmd
# compatibility test. Nothing is read from or saved out of the live
# registry: the file is written byte by byte in the regf format, the same
# way the Hayabusa self-test writes its sample event log. Only junk keys
# with obviously fake values go in it.
#
# Layout: a 4096-byte base block, then one hive bin holding a security
# cell, a key node per key, a fast leaf list per key with subkeys, a value
# list and value cells per key with values, and a data cell per value too
# big to sit in its value cell. The rest of the bin is one free cell.

$script:HiveCellAlign = 8
$script:HiveBinAlign = 4096

function Write-HiveUInt16 {
    param([System.IO.BinaryWriter]$Writer, [int]$Value)
    $Writer.Write([uint16]$Value)
}

function Write-HiveUInt32 {
    param([System.IO.BinaryWriter]$Writer, [long]$Value)
    $Writer.Write([uint32]($Value -band 0xFFFFFFFFL))
}

function Add-HiveCell {
    # Appends a cell holding Content and returns its offset from the start
    # of the hive bins. The size field is negative, marking it in use.
    param([System.IO.MemoryStream]$Stream, [byte[]]$Content)
    $offset = $Stream.Position
    $size = 4 + $Content.Length
    $padded = [int]([math]::Ceiling($size / $script:HiveCellAlign) * $script:HiveCellAlign)
    $w = New-Object System.IO.BinaryWriter($Stream, [System.Text.Encoding]::ASCII, $true)
    $w.Write([int32](-$padded))
    $w.Write($Content)
    for ($i = $size; $i -lt $padded; $i++) { $w.Write([byte]0) }
    $w.Flush()
    $w.Dispose()
    return [long]$offset
}

function Set-HiveUInt32 {
    # Writes a 32-bit value into an earlier cell. Offset is the cell's
    # offset, Field the byte position within its content.
    param([System.IO.MemoryStream]$Stream, [long]$Offset, [int]$Field, [long]$Value)
    $here = $Stream.Position
    $Stream.Position = $Offset + 4 + $Field
    $bytes = [BitConverter]::GetBytes([uint32]($Value -band 0xFFFFFFFFL))
    $Stream.Write($bytes, 0, 4)
    $Stream.Position = $here
}

function ConvertTo-HiveValue {
    # Type and bytes for a value: a string is REG_SZ, a string array
    # REG_MULTI_SZ, an integer REG_DWORD, a byte array REG_BINARY.
    param([AllowNull()][object]$Value)
    $unicode = [System.Text.Encoding]::Unicode
    if ($Value -is [byte[]]) {
        return [pscustomobject]@{ Type = 3; Bytes = $Value }
    }
    if ($Value -is [string[]] -or $Value -is [object[]]) {
        $text = (@($Value | ForEach-Object { [string]$_ }) -join "`0") + "`0`0"
        return [pscustomobject]@{ Type = 7; Bytes = $unicode.GetBytes($text) }
    }
    if ($Value -is [int] -or $Value -is [uint32] -or $Value -is [long]) {
        return [pscustomobject]@{ Type = 4; Bytes = [BitConverter]::GetBytes([uint32]([long]$Value -band 0xFFFFFFFFL)) }
    }
    return [pscustomobject]@{ Type = 1; Bytes = $unicode.GetBytes([string]$Value + "`0") }
}

function New-HiveKeyTree {
    # Turns @{ 'A\B' = @{ Name = value } } into a tree of nodes.
    param([System.Collections.IDictionary]$Keys)
    $root = [pscustomobject]@{ Name = ''; Children = [ordered]@{}; Values = [ordered]@{} }
    foreach ($path in $Keys.Keys) {
        $node = $root
        foreach ($segment in ([string]$path).Split('\')) {
            if ($segment.Length -eq 0) { continue }
            $found = $null
            foreach ($k in $node.Children.Keys) {
                if ($k -ieq $segment) { $found = $node.Children[$k] }
            }
            if ($null -eq $found) {
                $found = [pscustomobject]@{ Name = $segment; Children = [ordered]@{}; Values = [ordered]@{} }
                $node.Children[$segment] = $found
            }
            $node = $found
        }
        $values = $Keys[$path]
        if ($null -ne $values) {
            foreach ($v in $values.Keys) { $node.Values[$v] = $values[$v] }
        }
    }
    return $root
}

function Add-HiveKey {
    # Writes one key node and everything under it. Returns the node's offset.
    param([System.IO.MemoryStream]$Stream, [pscustomobject]$Node, [string]$Name, [long]$Parent, [long]$Security, [bool]$IsRoot)

    $ascii = [System.Text.Encoding]::ASCII
    $nameBytes = $ascii.GetBytes($Name)
    $nk = New-Object System.IO.MemoryStream
    $w = New-Object System.IO.BinaryWriter($nk)
    $w.Write($ascii.GetBytes('nk'))
    $flags = 0x20
    if ($IsRoot) { $flags = 0x2C }
    Write-HiveUInt16 $w $flags
    $w.Write([long]0x01DB000000000000)
    Write-HiveUInt32 $w 0
    Write-HiveUInt32 $w $Parent
    Write-HiveUInt32 $w 0            # subkey count, set below
    Write-HiveUInt32 $w 0
    Write-HiveUInt32 $w 0xFFFFFFFF   # subkey list, set below
    Write-HiveUInt32 $w 0xFFFFFFFF
    Write-HiveUInt32 $w 0            # value count, set below
    Write-HiveUInt32 $w 0xFFFFFFFF   # value list, set below
    Write-HiveUInt32 $w $Security
    Write-HiveUInt32 $w 0xFFFFFFFF   # class name
    Write-HiveUInt32 $w 0            # largest subkey name
    Write-HiveUInt32 $w 0
    Write-HiveUInt32 $w 0            # largest value name
    Write-HiveUInt32 $w 0            # largest value data
    Write-HiveUInt32 $w 0
    Write-HiveUInt16 $w $nameBytes.Length
    Write-HiveUInt16 $w 0
    $w.Write($nameBytes)
    $w.Flush()
    $offset = Add-HiveCell -Stream $Stream -Content $nk.ToArray()

    # Values
    $valueOffsets = New-Object System.Collections.Generic.List[long]
    $maxValueName = 0
    $maxValueData = 0
    foreach ($valueName in $Node.Values.Keys) {
        $data = ConvertTo-HiveValue -Value $Node.Values[$valueName]
        $vName = $ascii.GetBytes([string]$valueName)
        $maxValueName = [math]::Max($maxValueName, $vName.Length * 2)
        $maxValueData = [math]::Max($maxValueData, $data.Bytes.Length)
        $vk = New-Object System.IO.MemoryStream
        $vw = New-Object System.IO.BinaryWriter($vk)
        $vw.Write($ascii.GetBytes('vk'))
        Write-HiveUInt16 $vw $vName.Length
        if ($data.Bytes.Length -le 4) {
            Write-HiveUInt32 $vw (0x80000000L -bor $data.Bytes.Length)
            $resident = New-Object byte[] 4
            [Array]::Copy($data.Bytes, $resident, $data.Bytes.Length)
            $vw.Write($resident)
        }
        else {
            $dataOffset = Add-HiveCell -Stream $Stream -Content $data.Bytes
            Write-HiveUInt32 $vw $data.Bytes.Length
            Write-HiveUInt32 $vw $dataOffset
        }
        Write-HiveUInt32 $vw $data.Type
        $vFlags = 0
        if ($vName.Length -gt 0) { $vFlags = 1 }
        Write-HiveUInt16 $vw $vFlags
        Write-HiveUInt16 $vw 0
        $vw.Write($vName)
        $vw.Flush()
        $valueOffsets.Add((Add-HiveCell -Stream $Stream -Content $vk.ToArray()))
    }
    if ($valueOffsets.Count -gt 0) {
        $list = New-Object byte[] (4 * $valueOffsets.Count)
        for ($i = 0; $i -lt $valueOffsets.Count; $i++) {
            [Array]::Copy([BitConverter]::GetBytes([uint32]$valueOffsets[$i]), 0, $list, 4 * $i, 4)
        }
        $listOffset = Add-HiveCell -Stream $Stream -Content $list
        Set-HiveUInt32 -Stream $Stream -Offset $offset -Field 36 -Value $valueOffsets.Count
        Set-HiveUInt32 -Stream $Stream -Offset $offset -Field 40 -Value $listOffset
        Set-HiveUInt32 -Stream $Stream -Offset $offset -Field 60 -Value $maxValueName
        Set-HiveUInt32 -Stream $Stream -Offset $offset -Field 64 -Value $maxValueData
    }

    # Subkeys, sorted the way Windows keeps them
    $childNames = @($Node.Children.Keys | Sort-Object -Property { $_.ToUpperInvariant() })
    if ($childNames.Count -gt 0) {
        $children = New-Object System.Collections.Generic.List[object]
        $maxChildName = 0
        foreach ($childName in $childNames) {
            $childOffset = Add-HiveKey -Stream $Stream -Node $Node.Children[$childName] -Name $childName -Parent $offset -Security $Security -IsRoot $false
            $children.Add([pscustomobject]@{ Offset = $childOffset; Name = $childName })
            $maxChildName = [math]::Max($maxChildName, $childName.Length * 2)
        }
        $lf = New-Object System.IO.MemoryStream
        $lw = New-Object System.IO.BinaryWriter($lf)
        $lw.Write($ascii.GetBytes('lf'))
        Write-HiveUInt16 $lw $children.Count
        foreach ($c in $children) {
            Write-HiveUInt32 $lw $c.Offset
            $hint = New-Object byte[] 4
            $hb = $ascii.GetBytes($c.Name)
            [Array]::Copy($hb, $hint, [math]::Min(4, $hb.Length))
            $lw.Write($hint)
        }
        $lw.Flush()
        $lfOffset = Add-HiveCell -Stream $Stream -Content $lf.ToArray()
        Set-HiveUInt32 -Stream $Stream -Offset $offset -Field 20 -Value $children.Count
        Set-HiveUInt32 -Stream $Stream -Offset $offset -Field 28 -Value $lfOffset
        Set-HiveUInt32 -Stream $Stream -Offset $offset -Field 52 -Value $maxChildName
    }
    return $offset
}

function New-TestRegistryHive {
    <#
    Writes a hive to Path. HiveName is the file name embedded in the base
    block, such as SYSTEM or SOFTWARE, which is how RECmd decides the hive
    type. Keys maps key paths, relative to the root, to their values.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$HiveName,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Keys
    )

    $ascii = [System.Text.Encoding]::ASCII
    $bins = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($bins, $ascii, $true)
    # Hive bin header; its size is set once the cells are in.
    $bw.Write($ascii.GetBytes('hbin'))
    $bw.Write([uint32]0)
    $bw.Write([uint32]0)
    $bw.Write([uint64]0)
    $bw.Write([long]0x01DB000000000000)
    $bw.Write([uint32]0)
    $bw.Flush()

    # One security cell shared by every key: owner Administrators, group
    # SYSTEM, and a DACL allowing SYSTEM full access.
    $sd = New-Object System.IO.MemoryStream
    $sw = New-Object System.IO.BinaryWriter($sd)
    $sw.Write([byte]1); $sw.Write([byte]0); Write-HiveUInt16 $sw 0x8004
    Write-HiveUInt32 $sw 20; Write-HiveUInt32 $sw 36; Write-HiveUInt32 $sw 0; Write-HiveUInt32 $sw 48
    $sw.Write([byte[]](1, 2, 0, 0, 0, 0, 0, 5)); Write-HiveUInt32 $sw 32; Write-HiveUInt32 $sw 544
    $sw.Write([byte[]](1, 1, 0, 0, 0, 0, 0, 5)); Write-HiveUInt32 $sw 18
    $sw.Write([byte]2); $sw.Write([byte]0); Write-HiveUInt16 $sw 28; Write-HiveUInt16 $sw 1; Write-HiveUInt16 $sw 0
    $sw.Write([byte]0); $sw.Write([byte]0); Write-HiveUInt16 $sw 20; Write-HiveUInt32 $sw 0xF003F
    $sw.Write([byte[]](1, 1, 0, 0, 0, 0, 0, 5)); Write-HiveUInt32 $sw 18
    $sw.Flush()
    $descriptor = $sd.ToArray()
    $tree = New-HiveKeyTree -Keys $Keys
    $keyCount = 1
    $queue = New-Object System.Collections.Generic.Queue[object]
    $queue.Enqueue($tree)
    while ($queue.Count -gt 0) {
        $n = $queue.Dequeue()
        foreach ($c in $n.Children.Values) { $keyCount++; $queue.Enqueue($c) }
    }
    $sk = New-Object System.IO.MemoryStream
    $kw = New-Object System.IO.BinaryWriter($sk)
    $kw.Write($ascii.GetBytes('sk')); Write-HiveUInt16 $kw 0
    Write-HiveUInt32 $kw 0; Write-HiveUInt32 $kw 0
    Write-HiveUInt32 $kw $keyCount
    Write-HiveUInt32 $kw $descriptor.Length
    $kw.Write($descriptor)
    $kw.Flush()
    $bins.Position = $bins.Length
    $skOffset = Add-HiveCell -Stream $bins -Content $sk.ToArray()
    Set-HiveUInt32 -Stream $bins -Offset $skOffset -Field 4 -Value $skOffset
    Set-HiveUInt32 -Stream $bins -Offset $skOffset -Field 8 -Value $skOffset

    $rootOffset = Add-HiveKey -Stream $bins -Node $tree -Name 'ROOT' -Parent 0 -Security $skOffset -IsRoot $true

    # The rest of the bin is one free cell, positive size.
    $used = $bins.Length
    $binSize = [long]([math]::Ceiling(($used + 8) / $script:HiveBinAlign) * $script:HiveBinAlign)
    $bins.Position = $used
    $fw = New-Object System.IO.BinaryWriter($bins, $ascii, $true)
    $fw.Write([int32]($binSize - $used))
    $fw.Write((New-Object byte[] ($binSize - $used - 4)))
    $fw.Flush()
    $bins.Position = 8
    $bins.Write([BitConverter]::GetBytes([uint32]$binSize), 0, 4)

    # Base block
    $base = New-Object byte[] 4096
    $bb = New-Object System.IO.MemoryStream(, $base)
    $hw = New-Object System.IO.BinaryWriter($bb)
    $hw.Write($ascii.GetBytes('regf'))
    $hw.Write([uint32]1); $hw.Write([uint32]1)
    $hw.Write([long]0x01DB000000000000)
    $hw.Write([uint32]1); $hw.Write([uint32]3); $hw.Write([uint32]0); $hw.Write([uint32]1)
    $hw.Write([uint32]$rootOffset)
    $hw.Write([uint32]$binSize)
    $hw.Write([uint32]1)
    $fileName = [System.Text.Encoding]::Unicode.GetBytes("\System32\Config\$HiveName")
    $hw.Write($fileName)
    $hw.Flush()
    [uint32]$sum = 0
    for ($i = 0; $i -lt 508; $i += 4) {
        $sum = $sum -bxor [BitConverter]::ToUInt32($base, $i)
    }
    if ($sum -eq [uint32]::MaxValue) { $sum = [uint32]::MaxValue - 1 }
    if ($sum -eq 0) { $sum = 1 }
    [Array]::Copy([BitConverter]::GetBytes($sum), 0, $base, 508, 4)

    $out = New-Object byte[] (4096 + $binSize)
    [Array]::Copy($base, $out, 4096)
    [Array]::Copy($bins.ToArray(), 0, $out, 4096, $binSize)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllBytes($Path, $out)
    return $Path
}
