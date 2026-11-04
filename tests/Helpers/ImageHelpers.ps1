# Synthetic VHD and VHDX files for the image format checks. Dot-source after
# TestHelpers.ps1. Each builder returns the image's bytes, laid out as the
# format specifications describe, so a test can damage one field and write
# the result. None of these images holds a file system.

function Set-TestBigEndian32([byte[]]$Bytes, [int]$At, [uint32]$Value) {
    $Bytes[$At] = [byte](($Value -shr 24) -band 0xFF)
    $Bytes[$At + 1] = [byte](($Value -shr 16) -band 0xFF)
    $Bytes[$At + 2] = [byte](($Value -shr 8) -band 0xFF)
    $Bytes[$At + 3] = [byte]($Value -band 0xFF)
}

function Set-TestBigEndian64([byte[]]$Bytes, [int]$At, [uint64]$Value) {
    $mask = [uint64]4294967295
    Set-TestBigEndian32 -Bytes $Bytes -At $At -Value ([uint32](($Value -shr 32) -band $mask))
    Set-TestBigEndian32 -Bytes $Bytes -At ($At + 4) -Value ([uint32]($Value -band $mask))
}

function Set-TestLittleEndian([byte[]]$Bytes, [int]$At, [object]$Value) {
    $b = [System.BitConverter]::GetBytes($Value)
    [System.Buffer]::BlockCopy($b, 0, $Bytes, $At, $b.Length)
}

function Set-TestAscii([byte[]]$Bytes, [int]$At, [string]$Text) {
    $b = [System.Text.Encoding]::ASCII.GetBytes($Text)
    [System.Buffer]::BlockCopy($b, 0, $Bytes, $At, $b.Length)
}

function Set-TestGuid([byte[]]$Bytes, [int]$At, [string]$Guid) {
    $b = ([guid]$Guid).ToByteArray()
    [System.Buffer]::BlockCopy($b, 0, $Bytes, $At, 16)
}

function Update-TestVhdChecksum([byte[]]$Footer) {
    # One's complement of the byte sum, the checksum field left out.
    $sum = [uint32]0
    for ($i = 0; $i -lt 512; $i++) {
        if ($i -lt 64 -or $i -gt 67) {
            $sum = [uint32](($sum + $Footer[$i]) % 4294967296)
        }
    }
    Set-TestBigEndian32 -Bytes $Footer -At 64 -Value ([uint32](4294967295 - $sum))
}

function New-TestVhdFooter([uint32]$DiskType, [uint64]$DataOffset, [uint64]$Size) {
    $f = New-Object byte[] 512
    Set-TestAscii -Bytes $f -At 0 -Text 'conectix'
    Set-TestBigEndian32 -Bytes $f -At 8 -Value 2
    Set-TestBigEndian32 -Bytes $f -At 12 -Value 0x00010000
    Set-TestBigEndian64 -Bytes $f -At 16 -Value $DataOffset
    Set-TestAscii -Bytes $f -At 28 -Text 'test'
    Set-TestBigEndian32 -Bytes $f -At 36 -Value 0x5769326B
    Set-TestBigEndian64 -Bytes $f -At 40 -Value $Size
    Set-TestBigEndian64 -Bytes $f -At 48 -Value $Size
    Set-TestBigEndian32 -Bytes $f -At 56 -Value 0x00780411
    Set-TestBigEndian32 -Bytes $f -At 60 -Value $DiskType
    Set-TestGuid -Bytes $f -At 68 -Guid ([guid]::NewGuid().ToString())
    Update-TestVhdChecksum -Footer $f
    return , $f
}

function New-TestVhdImage {
    <#
    A VHD of Kind Fixed, Dynamic or Differencing, 4 MB of virtual disk.
    A differencing one carries a parent locator and a parent name, as a
    real one does.
    #>
    param([ValidateSet('Fixed', 'Dynamic', 'Differencing')][string]$Kind = 'Fixed')
    $size = [uint64]4MB
    if ($Kind -eq 'Fixed') {
        $footer = New-TestVhdFooter -DiskType 2 -DataOffset ([uint64]::MaxValue) -Size $size
        $data = New-Object byte[] ([int]$size + 512)
        [System.Buffer]::BlockCopy($footer, 0, $data, [int]$size, 512)
        return , $data
    }
    $type = 3
    if ($Kind -eq 'Differencing') { $type = 4 }
    $footer = New-TestVhdFooter -DiskType $type -DataOffset 512 -Size $size
    # Footer copy, dynamic header at 512, then a two-entry BAT at 1536,
    # padded to a sector, then the footer.
    $data = New-Object byte[] (512 + 1024 + 512 + 512)
    [System.Buffer]::BlockCopy($footer, 0, $data, 0, 512)
    $h = New-Object byte[] 1024
    Set-TestAscii -Bytes $h -At 0 -Text 'cxsparse'
    Set-TestBigEndian64 -Bytes $h -At 8 -Value ([uint64]::MaxValue)
    Set-TestBigEndian64 -Bytes $h -At 16 -Value 1536
    Set-TestBigEndian32 -Bytes $h -At 24 -Value 0x00010000
    Set-TestBigEndian32 -Bytes $h -At 28 -Value 2
    Set-TestBigEndian32 -Bytes $h -At 32 -Value 2MB
    if ($Kind -eq 'Differencing') {
        Set-TestGuid -Bytes $h -At 40 -Guid ([guid]::NewGuid().ToString())
        $name = [System.Text.Encoding]::BigEndianUnicode.GetBytes('parent.vhd')
        [System.Buffer]::BlockCopy($name, 0, $h, 64, $name.Length)
        Set-TestAscii -Bytes $h -At 576 -Text 'W2ku'
        Set-TestBigEndian32 -Bytes $h -At 580 -Value 512
        Set-TestBigEndian32 -Bytes $h -At 584 -Value 20
        Set-TestBigEndian64 -Bytes $h -At 592 -Value 2048
    }
    $sum = [uint32]0
    for ($i = 0; $i -lt 1024; $i++) { if ($i -lt 36 -or $i -gt 39) { $sum = [uint32](($sum + $h[$i]) % 4294967296) } }
    Set-TestBigEndian32 -Bytes $h -At 36 -Value ([uint32](4294967295 - $sum))
    [System.Buffer]::BlockCopy($h, 0, $data, 512, 1024)
    for ($i = 1536; $i -lt 1544; $i++) { $data[$i] = 0xFF }
    [System.Buffer]::BlockCopy($footer, 0, $data, $data.Length - 512, 512)
    return , $data
}

function Update-TestVhdxChecksum([byte[]]$Bytes, [int]$At, [int]$Length) {
    $part = New-Object byte[] $Length
    [System.Buffer]::BlockCopy($Bytes, $At, $part, 0, $Length)
    Initialize-ImageFormatType
    $crc = [HayabusaBulkRunner.DiskImageInspector]::Crc32C($part, 4)
    Set-TestLittleEndian -Bytes $Bytes -At ($At + 4) -Value ([uint32]$crc)
}

$script:TestVhdxMetadataAt = 3MB

function New-TestVhdxImage {
    <#
    A 4 MB VHDX file for an 8 MB dynamic disk with no data, laid out as
    MS-VHDX describes: the identifier, two headers, two region tables, a
    log, a BAT and a metadata region. HasParent sets the File Parameters
    flag and ParentLocator adds the parent locator item, as a real
    differencing disk has both.
    #>
    param([switch]$HasParent, [switch]$ParentLocator)
    $b = New-Object byte[] 4MB
    Set-TestAscii -Bytes $b -At 0 -Text 'vhdxfile'
    $creator = [System.Text.Encoding]::Unicode.GetBytes('synthetic test image')
    [System.Buffer]::BlockCopy($creator, 0, $b, 8, $creator.Length)
    $seq = 1
    foreach ($at in 64KB, 128KB) {
        Set-TestAscii -Bytes $b -At $at -Text 'head'
        Set-TestLittleEndian -Bytes $b -At ($at + 8) -Value ([uint64]$seq)
        Set-TestGuid -Bytes $b -At ($at + 16) -Guid ([guid]::NewGuid().ToString())
        Set-TestGuid -Bytes $b -At ($at + 32) -Guid ([guid]::NewGuid().ToString())
        Set-TestLittleEndian -Bytes $b -At ($at + 66) -Value ([uint16]1)
        Set-TestLittleEndian -Bytes $b -At ($at + 68) -Value ([uint32]1MB)
        Set-TestLittleEndian -Bytes $b -At ($at + 72) -Value ([uint64]1MB)
        Update-TestVhdxChecksum -Bytes $b -At $at -Length 4096
        $seq++
    }
    foreach ($at in 192KB, 256KB) {
        Set-TestAscii -Bytes $b -At $at -Text 'regi'
        Set-TestLittleEndian -Bytes $b -At ($at + 8) -Value ([uint32]2)
        Set-TestGuid -Bytes $b -At ($at + 16) -Guid '2DC27766-F623-4200-9D64-115E9BFD4A08'
        Set-TestLittleEndian -Bytes $b -At ($at + 32) -Value ([uint64]2MB)
        Set-TestLittleEndian -Bytes $b -At ($at + 40) -Value ([uint32]1MB)
        Set-TestLittleEndian -Bytes $b -At ($at + 44) -Value ([uint32]1)
        Set-TestGuid -Bytes $b -At ($at + 48) -Guid '8B7CA206-4790-4B9A-B8FE-575F050F886E'
        Set-TestLittleEndian -Bytes $b -At ($at + 64) -Value ([uint64]3MB)
        Set-TestLittleEndian -Bytes $b -At ($at + 72) -Value ([uint32]1MB)
        Set-TestLittleEndian -Bytes $b -At ($at + 76) -Value ([uint32]1)
        Update-TestVhdxChecksum -Bytes $b -At $at -Length 64KB
    }
    $m = $script:TestVhdxMetadataAt
    Set-TestAscii -Bytes $b -At $m -Text 'metadata'
    $items = New-Object System.Collections.Generic.List[object]
    $items.Add(@('CAA16737-FA36-4D43-B3B6-33F0AA44E76B', 8, 4))
    $items.Add(@('2FA54224-CD1B-4876-B211-5DBED83BF4B8', 8, 6))
    $items.Add(@('BECA12AB-B2E6-4523-93EF-C309E000C746', 16, 6))
    $items.Add(@('8141BF1D-A96F-4709-BA47-F233A8FAAB5F', 4, 6))
    $items.Add(@('CDA348C7-445D-4471-9CC9-E9885251C556', 4, 6))
    if ($ParentLocator) { $items.Add(@('A8D35F2D-B30B-454D-ABF7-D3D84834AB0C', 64, 4)) }
    Set-TestLittleEndian -Bytes $b -At ($m + 10) -Value ([uint16]$items.Count)
    $offset = 64KB
    for ($i = 0; $i -lt $items.Count; $i++) {
        $e = $m + 32 + ($i * 32)
        Set-TestGuid -Bytes $b -At $e -Guid $items[$i][0]
        Set-TestLittleEndian -Bytes $b -At ($e + 16) -Value ([uint32]$offset)
        Set-TestLittleEndian -Bytes $b -At ($e + 20) -Value ([uint32]$items[$i][1])
        Set-TestLittleEndian -Bytes $b -At ($e + 24) -Value ([uint32]$items[$i][2])
        $offset += $items[$i][1]
    }
    $flags = 0
    if ($HasParent) { $flags = 2 }
    Set-TestLittleEndian -Bytes $b -At ($m + 64KB) -Value ([uint32]1MB)
    Set-TestLittleEndian -Bytes $b -At ($m + 64KB + 4) -Value ([uint32]$flags)
    Set-TestLittleEndian -Bytes $b -At ($m + 64KB + 8) -Value ([uint64]8MB)
    Set-TestGuid -Bytes $b -At ($m + 64KB + 16) -Guid ([guid]::NewGuid().ToString())
    Set-TestLittleEndian -Bytes $b -At ($m + 64KB + 32) -Value ([uint32]512)
    Set-TestLittleEndian -Bytes $b -At ($m + 64KB + 36) -Value ([uint32]4096)
    return , $b
}

function Write-TestImage([string]$Path, [byte[]]$Bytes) {
    New-TestDirectory -Path (Split-Path -Parent $Path) | Out-Null
    [System.IO.File]::WriteAllBytes($Path, $Bytes)
    return $Path
}
