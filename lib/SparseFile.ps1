# Files a Velociraptor offline collector stored sparse. It strips the
# unallocated holes out of such a file and writes a JSON index beside it,
# <name>.idx, mapping the bytes it kept back to their original offsets:
#
#     {"ranges":[
#       {"file_length":2203648,"length":2203648},
#       {"file_offset":2203648,"original_offset":2203648,"length":155648}
#     ]}
#
# A range with file_length is data: file_length bytes at file_offset in the
# stored file belong at original_offset. A range without it is a hole of
# length zero bytes at original_offset. file_offset and original_offset are
# 0 when absent. The original size is the end of the furthest range. A file
# that wasn't sparse has no index. Both come from the collection, so the
# index is read as untrusted input.

# A real index lists a handful of ranges. Anything bigger than this isn't
# read at all.
$script:MaxSparseIndexBytes = 8MB

$script:SparseCopyBufferBytes = 1MB

function Get-SparseIndexPath {
    <#
    .SYNOPSIS
        The sparse index beside a file, <name>.idx in any case, or null.
    .DESCRIPTION
        A link is never taken to be an index.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $dir = [System.IO.Path]::GetDirectoryName($Path)
    $want = [System.IO.Path]::GetFileName($Path) + '.idx'
    try {
        $entries = [System.IO.Directory]::GetFiles((Get-ExtendedLengthPath -Path $dir))
    }
    catch {
        Write-Verbose "Could not list ${dir}: $($_.Exception.Message)"
        return $null
    }
    foreach ($e in $entries) {
        if ([System.IO.Path]::GetFileName($e) -ine $want) {
            continue
        }
        if (([System.IO.File]::GetAttributes($e) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            continue
        }
        return (ConvertFrom-ExtendedLengthPath -Path $e)
    }
    return $null
}

function ConvertTo-SparseNumber {
    # A whole number from an index, from 0 up to Maximum, or throws.
    [CmdletBinding()]
    [OutputType([long])]
    param(
        [AllowNull()]
        [object]$Value,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [long]$Maximum
    )

    $numeric = ($Value -is [int] -or $Value -is [long] -or $Value -is [decimal] -or $Value -is [double] -or $Value -is [int16] -or $Value -is [byte])
    # A number too big for a long. Named as text, since Windows PowerShell
    # 5.1 may not have System.Numerics loaded.
    if ($null -ne $Value -and $Value.GetType().FullName -eq 'System.Numerics.BigInteger') {
        throw "$Name is $Value, over the limit of $Maximum."
    }
    if (-not $numeric) {
        throw "$Name is not a number."
    }
    try {
        $d = [decimal]$Value
    }
    catch {
        throw "$Name is $Value, over the limit of $Maximum."
    }
    if ($d -ne [decimal]::Truncate($d)) {
        throw "$Name is $Value, not a whole number."
    }
    if ($d -lt 0) {
        throw "$Name is $Value, which is negative."
    }
    if ($d -gt $Maximum) {
        throw "$Name is $Value, over the limit of $Maximum."
    }
    return [long]$d
}

function Read-SparseIndex {
    <#
    .SYNOPSIS
        Reads and checks a sparse index.
    .DESCRIPTION
        Returns the ranges and the original size, or Error saying why the
        index can't be used: it's too big, isn't JSON, has no ranges, a
        value isn't a whole number from 0 up to MaxBytes, a data range's
        file_length isn't its length, or the original size is over
        MaxBytes. Never throws.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [long]$MaxBytes
    )

    $result = [pscustomobject]@{
        Ranges       = @()
        OriginalSize = $null
        DataBytes    = 0L
        Error        = $null
    }
    try {
        $long = Get-ExtendedLengthPath -Path $Path
        $size = (New-Object System.IO.FileInfo($long)).Length
        if ($size -gt $script:MaxSparseIndexBytes) {
            throw "it's $size bytes, too big to be a sparse index."
        }
        try {
            $parsed = [System.IO.File]::ReadAllText($long, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        }
        catch {
            throw "it isn't valid JSON."
        }
        $rangesProp = $null
        if ($parsed -is [System.Management.Automation.PSCustomObject]) {
            $rangesProp = $parsed.PSObject.Properties['ranges']
        }
        if ($null -eq $rangesProp -or $rangesProp.Value -isnot [System.Collections.IList] -or @($rangesProp.Value).Count -eq 0) {
            throw 'it has no list of ranges.'
        }

        $ranges = New-Object System.Collections.Generic.List[object]
        $end = 0L
        $data = 0L
        $i = 0
        foreach ($r in @($rangesProp.Value)) {
            $label = "range $i"
            $i++
            # Only an object counts. An array has a Length of its own.
            if ($r -isnot [System.Management.Automation.PSCustomObject] -or $null -eq $r.PSObject.Properties['length']) {
                throw "$label has no length."
            }
            $length = ConvertTo-SparseNumber -Value $r.PSObject.Properties['length'].Value -Name "$label length" -Maximum $MaxBytes
            $fileOffset = 0L
            $p = $r.PSObject.Properties['file_offset']
            if ($null -ne $p) {
                $fileOffset = ConvertTo-SparseNumber -Value $p.Value -Name "$label file_offset" -Maximum $MaxBytes
            }
            $originalOffset = 0L
            $p = $r.PSObject.Properties['original_offset']
            if ($null -ne $p) {
                $originalOffset = ConvertTo-SparseNumber -Value $p.Value -Name "$label original_offset" -Maximum $MaxBytes
            }
            $isData = $false
            $p = $r.PSObject.Properties['file_length']
            if ($null -ne $p) {
                $fileLength = ConvertTo-SparseNumber -Value $p.Value -Name "$label file_length" -Maximum $MaxBytes
                if ($fileLength -ne $length) {
                    throw "$label has a file_length of $fileLength but a length of $length."
                }
                $isData = $true
                $data += $length
            }
            $rangeEnd = $originalOffset + $length
            if ($rangeEnd -gt $MaxBytes) {
                throw "$label ends at byte $rangeEnd, over the limit of $MaxBytes."
            }
            if ($rangeEnd -gt $end) {
                $end = $rangeEnd
            }
            $ranges.Add([pscustomobject]@{
                    IsData         = $isData
                    FileOffset     = $fileOffset
                    OriginalOffset = $originalOffset
                    Length         = $length
                })
        }
        $result.Ranges = $ranges.ToArray()
        $result.OriginalSize = $end
        $result.DataBytes = $data
    }
    catch {
        $result.Error = $_.Exception.Message
    }
    return $result
}

function Expand-SparseFile {
    <#
    .SYNOPSIS
        Writes the full-size original of a file stored sparse, from the
        stored file and its checked index.
    .DESCRIPTION
        The output is created at the original size, so every hole reads as
        zeros, and each data range is streamed into place in chunks, never
        read whole into memory. Nothing past the end of the stored file is
        read: a range that runs past it gets only the bytes that are there,
        and the rest stays zeros. Returns notes on anything that didn't add
        up. Written through a temporary file moved into place, so a failure
        never leaves a part-written Destination. The stored file is only
        ever read.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Source,

        [Parameter(Mandatory)]
        [pscustomobject]$Index,

        [Parameter(Mandatory)]
        [string]$Destination
    )

    $leaf = [System.IO.Path]::GetFileName($Source)
    $notes = New-Object System.Collections.Generic.List[string]
    $target = Get-ExtendedLengthPath -Path $Destination
    $temp = Get-ExtendedLengthPath -Path ($Destination + '.tmp')
    $in = $null
    $out = $null
    $done = $false
    try {
        $in = [System.IO.File]::Open((Get-ExtendedLengthPath -Path $Source), [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $sourceLength = $in.Length
        $out = New-Object System.IO.FileStream($temp, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $out.SetLength($Index.OriginalSize)
        $buffer = New-Object byte[] $script:SparseCopyBufferBytes
        $short = 0L
        foreach ($r in @($Index.Ranges | Where-Object { $_.IsData })) {
            $available = [math]::Max(0L, [math]::Min([long]$r.Length, $sourceLength - [long]$r.FileOffset))
            $short += ($r.Length - $available)
            if ($available -eq 0) {
                continue
            }
            $in.Position = $r.FileOffset
            $out.Position = $r.OriginalOffset
            $left = $available
            while ($left -gt 0) {
                $want = [int][math]::Min([long]$buffer.Length, $left)
                $got = $in.Read($buffer, 0, $want)
                if ($got -le 0) {
                    break
                }
                $out.Write($buffer, 0, $got)
                $left -= $got
            }
        }
        if ($short -gt 0) {
            $notes.Add("The sparse index of $leaf points past the end of the file as collected, so $short byte(s) it lists were left as zeros.")
        }
        elseif ($Index.DataBytes -ne $sourceLength) {
            $notes.Add("The sparse index of $leaf lists $($Index.DataBytes) bytes of data, but the file as collected is $sourceLength bytes.")
        }
        $out.Dispose()
        $out = $null
        [System.IO.File]::Move($temp, $target)
        $done = $true
    }
    finally {
        if ($null -ne $out) {
            $out.Dispose()
        }
        if ($null -ne $in) {
            $in.Dispose()
        }
        if (-not $done -and [System.IO.File]::Exists($temp)) {
            [System.IO.File]::Delete($temp)
        }
    }
    return $notes.ToArray()
}
