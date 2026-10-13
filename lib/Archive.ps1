$script:DiskImageExtensions = @('.vhd', '.vhdx')

# Copy buffer for streaming extraction.
$script:ExtractBufferSize = 81920

# Windows path limits, used to tell a path-too-long failure from any other
# file error: 260 characters for a plain path, 255 for a single name.
$script:MaxPlainPathLength = 260
$script:MaxPathNameLength = 255

# Free space required beyond the archive's uncompressed size: 10 percent of
# that size or 1 GB, whichever is larger.
$script:FreeSpaceMarginFraction = 0.10
$script:FreeSpaceMarginMinBytes = [long]1GB

function Initialize-ZipSupport {
    # Windows PowerShell 5.1 does not load these assemblies by default.
    [CmdletBinding()]
    param()

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
}

function Test-DiskImageName {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Name
    )

    return ($script:DiskImageExtensions -contains (Get-EntryExtension -Name $Name))
}

function Get-EntryExtension {
    # The extension of a ZIP entry or file name, in lower case with its dot,
    # or empty. Plain string work: on Windows PowerShell 5.1,
    # [System.IO.Path]::GetExtension throws for characters such as | or "
    # that an archive made elsewhere can hold.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Name
    )

    $leaf = $Name.Substring($Name.LastIndexOfAny([char[]]@('/', '\')) + 1)
    $dot = $leaf.LastIndexOf('.')
    if ($dot -lt 0 -or $dot -eq $leaf.Length - 1) {
        return ''
    }
    return $leaf.Substring($dot).ToLowerInvariant()
}

# .NET's ZIP reader handles only these compression methods.
$script:SupportedZipMethods = @(0, 8)
$script:ZipMethodNames = @{
    0  = 'Stored'
    8  = 'Deflate'
    9  = 'Deflate64'
    12 = 'BZip2'
    14 = 'LZMA'
    93 = 'Zstandard'
    95 = 'XZ'
    98 = 'PPMd'
    99 = 'AES encryption'
}

# Largest central directory read into memory. Anything bigger is treated as
# unreadable rather than risking memory on a crafted archive.
$script:MaxCentralDirectoryBytes = [long]256MB

function Get-ZipMethodName {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [int]$Method
    )

    if ($script:ZipMethodNames.ContainsKey($Method)) {
        return "$Method ($($script:ZipMethodNames[$Method]))"
    }
    return "$Method"
}

function Get-ZipCentralDirectory {
    <#
    .SYNOPSIS
        Reads a ZIP's central directory directly, without .NET's ZIP reader.
    .DESCRIPTION
        Returns each entry's name, compression method and general-purpose
        flags, which ZipArchiveEntry does not expose on .NET Framework. Only
        bytes are read. Nothing is decompressed.

        Fails safe: any problem parsing the bytes returns Ok = $false with
        the reason in Error. It never throws and never reports a ZIP it
        could not fully read as fine. Covers a missing end-of-directory
        record, bad signatures, offsets or lengths outside the file, a
        truncated header, an entry count that does not match the headers
        present, a broken Zip64 locator and a spanned archive.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $result = [pscustomobject]@{
        Ok      = $false
        Error   = $null
        Entries = @()
    }

    $stream = $null
    try {
        $stream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        $length = [long]$stream.Length
        if ($length -lt 22) {
            throw 'file is too short to be a ZIP'
        }

        # The end-of-central-directory record is in the last 22 to 65557 bytes.
        $tailLength = [int][math]::Min($length, [long]65557)
        $tailStart = $length - $tailLength
        $tail = New-Object byte[] $tailLength
        [void]$stream.Seek($tailStart, [System.IO.SeekOrigin]::Begin)
        if ($stream.Read($tail, 0, $tailLength) -ne $tailLength) {
            throw 'could not read the end of the file'
        }

        $eocd = -1
        for ($i = $tailLength - 22; $i -ge 0; $i--) {
            if ([BitConverter]::ToUInt32($tail, $i) -eq 0x06054b50) {
                $commentLength = [BitConverter]::ToUInt16($tail, $i + 20)
                if ($i + 22 + $commentLength -eq $tailLength) {
                    $eocd = $i
                    break
                }
            }
        }
        if ($eocd -lt 0) {
            throw 'no end-of-central-directory record'
        }

        $diskNumber = [BitConverter]::ToUInt16($tail, $eocd + 4)
        $cdDisk = [BitConverter]::ToUInt16($tail, $eocd + 6)
        if ($diskNumber -ne 0 -or $cdDisk -ne 0) {
            throw 'spanned or multi-part archive'
        }
        [long]$total = [BitConverter]::ToUInt16($tail, $eocd + 10)
        [long]$cdSize = [BitConverter]::ToUInt32($tail, $eocd + 12)
        [long]$cdOffset = [BitConverter]::ToUInt32($tail, $eocd + 16)
        [long]$eocdAbsolute = $tailStart + $eocd
        [long]$cdLimit = $eocdAbsolute

        # In PowerShell 0xFFFFFFFF is the Int32 -1, so compare with the
        # unsigned maximum explicitly.
        [long]$max32 = [uint32]::MaxValue
        if ($total -eq [uint16]::MaxValue -or $cdSize -eq $max32 -or $cdOffset -eq $max32) {
            # Zip64: a 20-byte locator sits just before the record.
            $locator = $eocd - 20
            if ($locator -lt 0 -or [BitConverter]::ToUInt32($tail, $locator) -ne 0x07064b50) {
                throw 'Zip64 locator missing or damaged'
            }
            [long]$zip64Offset = [long][BitConverter]::ToUInt64($tail, $locator + 8)
            if ($zip64Offset -lt 0 -or $zip64Offset + 56 -gt $tailStart + $locator) {
                throw 'Zip64 record offset is outside the file'
            }
            $record = New-Object byte[] 56
            [void]$stream.Seek($zip64Offset, [System.IO.SeekOrigin]::Begin)
            if ($stream.Read($record, 0, 56) -ne 56 -or [BitConverter]::ToUInt32($record, 0) -ne 0x06064b50) {
                throw 'Zip64 end-of-central-directory record missing or damaged'
            }
            $total = [long][BitConverter]::ToUInt64($record, 32)
            $cdSize = [long][BitConverter]::ToUInt64($record, 40)
            $cdOffset = [long][BitConverter]::ToUInt64($record, 48)
            $cdLimit = $zip64Offset
        }

        if ($cdOffset -lt 0 -or $cdSize -lt 0 -or $total -lt 0 -or $cdOffset + $cdSize -gt $cdLimit) {
            throw 'central directory offset or size is outside the file'
        }
        if ($cdSize -gt $script:MaxCentralDirectoryBytes) {
            throw 'central directory is too large to check'
        }
        if ($total -gt 0 -and $cdSize -lt 46) {
            throw 'central directory is smaller than one entry'
        }

        $cd = New-Object byte[] ([int]$cdSize)
        [void]$stream.Seek($cdOffset, [System.IO.SeekOrigin]::Begin)
        $read = 0
        while ($read -lt $cdSize) {
            $n = $stream.Read($cd, $read, [int]($cdSize - $read))
            if ($n -le 0) {
                throw 'central directory is truncated'
            }
            $read += $n
        }

        $entries = New-Object System.Collections.Generic.List[object]
        $pos = 0
        for ($e = 0; $e -lt $total; $e++) {
            if ($pos + 46 -gt $cdSize) {
                throw "central directory ends after $e of $total entries"
            }
            if ([BitConverter]::ToUInt32($cd, $pos) -ne 0x02014b50) {
                throw "bad central directory header at entry $e"
            }
            $flags = [int][BitConverter]::ToUInt16($cd, $pos + 8)
            $method = [int][BitConverter]::ToUInt16($cd, $pos + 10)
            $nameLength = [int][BitConverter]::ToUInt16($cd, $pos + 28)
            $extraLength = [int][BitConverter]::ToUInt16($cd, $pos + 30)
            $commentLength = [int][BitConverter]::ToUInt16($cd, $pos + 32)
            $next = $pos + 46 + $nameLength + $extraLength + $commentLength
            if ($next -gt $cdSize) {
                throw "central directory entry $e runs past the directory"
            }
            $name = [System.Text.Encoding]::UTF8.GetString($cd, $pos + 46, $nameLength)
            $entries.Add([pscustomobject]@{
                    Name      = $name
                    Method    = $method
                    Flags     = $flags
                    Encrypted = (($flags -band 0x41) -ne 0) -or ($method -eq 99)
                })
            $pos = $next
        }

        $result.Entries = $entries.ToArray()
        $result.Ok = $true
    }
    catch {
        $result.Ok = $false
        $result.Entries = @()
        $result.Error = $_.Exception.Message
    }
    finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }

    return $result
}

function Get-ZipEntryInfo {
    <#
    .SYNOPSIS
        Lists a ZIP's entries and checks it can be extracted, without extracting.
    .DESCRIPTION
        Returns entry counts, declared sizes, and the names of any disk
        images, evtx files and nested ZIPs inside.

        Readability is checked first from the raw central directory. An
        encrypted entry, or a compression method other than Stored or
        Deflate, makes the ZIP unreadable (ReadReason Unsupported), since
        .NET cannot extract it. The rule is the same on Windows PowerShell
        5.1 and PowerShell 7. A central directory that cannot be parsed is
        unreadable too (ReadReason Unparseable), never assumed fine. An
        entry name holding a character no Windows path can use, such as |
        or a control character, makes it unreadable as well (ReadReason
        BadName). A ZIP that passes but that .NET still cannot open is
        ReadReason Corrupt.

        Unreadable ZIPs are reported, not thrown, so discovery can guide the
        operator. Get-ZipGuidance builds the message.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    Initialize-ZipSupport

    $info = [pscustomobject]@{
        Path              = $Path
        Readable          = $false
        ReadReason        = $null
        ReadError         = $null
        EntryCount        = 0
        UncompressedBytes = [long]0
        CompressedBytes   = [long]0
        ImageEntries      = @()
        EvtxEntryCount    = 0
        NestedZipEntries  = @()
    }

    $directory = Get-ZipCentralDirectory -Path $Path
    if (-not $directory.Ok) {
        $info.ReadReason = 'Unparseable'
        $info.ReadError = "its central directory could not be read ($($directory.Error))"
        return $info
    }

    # Checked before anything else looks at the names, so one odd entry
    # fails this ZIP alone and can never stop discovery.
    $badNames = @($directory.Entries | Where-Object { $_.Name -match '[\x00-\x1F"<>|]' })
    if ($badNames.Count -gt 0) {
        $shown = $badNames[0].Name -replace '[\x00-\x1F]', '?'
        $why = "entry '$shown' holds a character Windows can't use in a path"
        if ($badNames.Count -gt 1) {
            $why += ", and $($badNames.Count - 1) more entr(ies) have the same problem"
        }
        $info.ReadReason = 'BadName'
        $info.ReadError = $why
        $info.EntryCount = @($directory.Entries).Count
        return $info
    }

    $images = @($directory.Entries | Where-Object { Test-DiskImageName -Name $_.Name } | ForEach-Object { $_.Name })
    $bad = @($directory.Entries | Where-Object { $_.Encrypted -or $script:SupportedZipMethods -notcontains $_.Method })
    if ($bad.Count -gt 0) {
        $first = $bad[0]
        if ($first.Encrypted) {
            $why = "entry '$($first.Name)' is encrypted"
        }
        else {
            $why = "entry '$($first.Name)' uses compression method $(Get-ZipMethodName -Method $first.Method), which .NET cannot extract"
        }
        if ($bad.Count -gt 1) {
            $why += ", and $($bad.Count - 1) more entr(ies) have the same problem"
        }
        $info.ReadReason = 'Unsupported'
        $info.ReadError = $why
        $info.EntryCount = @($directory.Entries).Count
        $info.ImageEntries = $images
        return $info
    }

    $archive = $null
    try {
        $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
        $imageList = New-Object System.Collections.Generic.List[string]
        $nested = New-Object System.Collections.Generic.List[string]
        $evtx = 0
        $uncompressed = [long]0
        $compressed = [long]0

        foreach ($entry in $archive.Entries) {
            $uncompressed += $entry.Length
            $compressed += $entry.CompressedLength
            $ext = Get-EntryExtension -Name $entry.FullName
            if ($script:DiskImageExtensions -contains $ext) {
                $imageList.Add($entry.FullName)
            }
            elseif ($ext -eq '.evtx') {
                $evtx++
            }
            elseif ($ext -eq '.zip') {
                $nested.Add($entry.FullName)
            }
        }

        $info.Readable = $true
        $info.EntryCount = $archive.Entries.Count
        $info.UncompressedBytes = $uncompressed
        $info.CompressedBytes = $compressed
        $info.ImageEntries = $imageList.ToArray()
        $info.EvtxEntryCount = $evtx
        $info.NestedZipEntries = $nested.ToArray()
    }
    catch {
        $info.Readable = $false
        $info.ReadReason = 'Corrupt'
        $info.ReadError = ".NET could not open it ($($_.Exception.Message))"
        $info.ImageEntries = $images
    }
    finally {
        if ($null -ne $archive) {
            $archive.Dispose()
        }
    }

    return $info
}

function Get-ZipReadReasonText {
    <#
    .SYNOPSIS
        The short reason a ZIP cannot be extracted, for analyst-facing text.
    .DESCRIPTION
        Names the kind of problem only. The offending entry and method stay
        in ReadError, which goes to the per-host log, not the console,
        manifest or dashboard.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Info
    )

    if ($Info.ReadReason -eq 'Unsupported') {
        return 'unsupported compression or encryption'
    }
    if ($Info.ReadReason -eq 'BadName') {
        return "an entry name isn't valid on Windows"
    }
    return 'it could not be read, the file may be damaged'
}

function Get-ZipGuidance {
    <#
    .SYNOPSIS
        Short guidance for a ZIP this tool cannot extract.
    .DESCRIPTION
        Used in the manifest, the dashboard and the run-time error. When the
        ZIP is known to hold a disk image, the operator is told to put the
        extracted image itself in InputRoot, because an image left inside a
        folder is not mounted and Hayabusa would find nothing.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Source,

        [Parameter(Mandatory)]
        [pscustomobject]$Info
    )

    $images = @($Info.ImageEntries)
    if ($images.Count -gt 0) {
        $leaf = ($images | ForEach-Object { ($_ -split '[\\/]')[-1] }) -join ', '
        $advice = "Extract it yourself, put the extracted disk image ($leaf) directly in InputRoot, and rerun."
    }
    else {
        $advice = 'Extract it yourself, put the extracted folder in InputRoot, and rerun.'
    }
    return "$Source can't be extracted by this tool ($(Get-ZipReadReasonText -Info $Info)). $advice"
}

function Test-ZipEntryName {
    <#
    .SYNOPSIS
        Returns the reason an entry name is unsafe to extract, or null if it is safe.
    .DESCRIPTION
        Rejects anything that could write outside the target folder or that
        Windows would interpret differently from its literal name.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Name
    )

    $n = $Name.Replace('\', '/')

    if ($n.StartsWith('/')) {
        return 'absolute or UNC path'
    }
    if ($n -match '^[A-Za-z]:') {
        return 'drive-qualified path'
    }
    if ($n.Contains(':')) {
        return 'colon in name (alternate data stream)'
    }
    if ($n -match '[\x00-\x1F<>"|?*]') {
        return 'character not valid in a Windows file name'
    }

    foreach ($segment in $n.Split('/')) {
        if ($segment.Length -eq 0) {
            continue
        }
        if ($segment -eq '..') {
            return 'parent directory segment'
        }
        if ($segment.EndsWith('.') -or $segment.EndsWith(' ')) {
            if ($segment -ne '.') {
                return 'segment ends with a dot or space'
            }
        }
        $stem = $segment.Split('.')[0]
        if ($stem -match '^(?i)(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') {
            return 'reserved device name'
        }
    }

    return $null
}

function Get-SafeEntryTarget {
    # Resolves an entry to a full path and confirms it stays under Destination.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Destination,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $sep = [System.IO.Path]::DirectorySeparatorChar
    $root = [System.IO.Path]::GetFullPath($Destination).TrimEnd('\', '/')
    $relative = $Name.Replace('\', '/').Replace('/', $sep)
    $target = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($root, $relative))

    if (-not $target.StartsWith($root + $sep, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Entry '$Name' resolves outside the extraction folder."
    }
    return $target
}

function Assert-ZipArchiveSafe {
    <#
    .SYNOPSIS
        Checks every entry of an open archive before anything is extracted.
    .DESCRIPTION
        Refuses the whole archive if any entry name is unsafe, if any entry
        resolves outside Destination (zip slip), or if the declared total size
        or the overall compression ratio is over its cap (zip bomb). The ratio
        is taken across the whole archive, not per entry, because empty
        pre-sized evtx files and fixed-size disk images legitimately compress
        hundreds of times smaller. An entry whose path is too long to
        resolve is not unsafe, but it can't be extracted, so its
        PathTooLongException is thrown once the other checks pass. Returns
        the declared uncompressed total.
    #>
    [CmdletBinding()]
    [OutputType([long])]
    param(
        [Parameter(Mandatory)]
        [System.IO.Compression.ZipArchive]$Archive,

        [Parameter(Mandatory)]
        [string]$Destination,

        [Parameter(Mandatory)]
        [long]$MaxUncompressedBytes,

        [Parameter(Mandatory)]
        [double]$MaxRatio
    )

    $total = [long]0
    $compressed = [long]0
    $problems = New-Object System.Collections.Generic.List[string]
    $pathTooLong = $null

    foreach ($entry in $Archive.Entries) {
        $total += $entry.Length
        $compressed += $entry.CompressedLength

        if ($entry.FullName.Length -eq 0) {
            continue
        }
        $reason = Test-ZipEntryName -Name $entry.FullName
        if ($null -ne $reason) {
            $problems.Add("'$($entry.FullName)': $reason")
            continue
        }
        try {
            Get-SafeEntryTarget -Destination $Destination -Name $entry.FullName | Out-Null
        }
        catch {
            # Windows PowerShell 5.1 can't resolve a name over 255
            # characters at all. That entry can't be written either, so
            # keep the error for the long-path guidance instead of calling
            # the name unsafe.
            $err = $_.Exception
            while ($null -ne $err.InnerException) {
                $err = $err.InnerException
            }
            if ($err -is [System.IO.PathTooLongException]) {
                if ($null -eq $pathTooLong) {
                    $pathTooLong = $err
                }
            }
            else {
                $problems.Add("'$($entry.FullName)': resolves outside the extraction folder")
            }
        }
    }

    if ($problems.Count -gt 0) {
        $shown = @($problems | Select-Object -First 10) -join '; '
        throw "Archive refused, $($problems.Count) unsafe entry name(s): $shown"
    }

    if ($total -gt $MaxUncompressedBytes) {
        throw ("Archive refused: declared uncompressed size {0:N0} bytes is over the cap of {1:N0} bytes (ZipMaxUncompressedGB)." -f $total, $MaxUncompressedBytes)
    }

    if ($total -gt 0) {
        $ratio = $total / [math]::Max($compressed, 1)
        if ($ratio -gt $MaxRatio) {
            throw ("Archive refused: overall compression ratio {0:N0}:1 is over the cap of {1:N0}:1 (ZipMaxRatio)." -f $ratio, $MaxRatio)
        }
    }

    if ($null -ne $pathTooLong) {
        throw $pathTooLong
    }

    return $total
}

function Get-FreeSpace {
    <#
    .SYNOPSIS
        Returns free bytes on the volume holding Path, or null if unknown.
    .DESCRIPTION
        DriveInfo does not accept UNC roots, so network shares come back as
        null and the caller warns rather than refusing.
    #>
    [CmdletBinding()]
    [OutputType([long])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    try {
        $root = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($Path))
        if ([string]::IsNullOrEmpty($root) -or $root.StartsWith('\\')) {
            return $null
        }
        $drive = New-Object System.IO.DriveInfo($root)
        return [long]$drive.AvailableFreeSpace
    }
    catch {
        return $null
    }
}

function Get-ZipPathMeasure {
    <#
    .SYNOPSIS
        The longest full path and the longest single name a ZIP would create
        under Destination.
    .DESCRIPTION
        Used only to describe a path-too-long failure, so it must never
        throw itself: it measures string lengths without calling any path
        API, and returns zeros if anything about the archive can't be read.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [object]$Archive,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$Destination
    )

    $longestPath = 0
    $longestName = 0
    try {
        $rootLength = ([string]$Destination).Length
        $entries = @()
        if ($null -ne $Archive) {
            $entries = @($Archive.Entries | Where-Object { $null -ne $_ })
        }
        foreach ($entry in $entries) {
            $name = [string]$entry.FullName
            $length = $rootLength + 1 + $name.Length
            if ($length -gt $longestPath) {
                $longestPath = $length
            }
            foreach ($segment in $name.Split([char[]]@('/', '\'))) {
                if ($segment.Length -gt $longestName) {
                    $longestName = $segment.Length
                }
            }
        }
    }
    catch {
        Write-Verbose "Could not measure the paths in the archive: $($_.Exception.Message)"
    }
    return [pscustomobject]@{ LongestPath = $longestPath; LongestName = $longestName }
}

function Get-LongPathGuidance {
    # Guidance for a ZIP whose paths Windows can't create. Plain string
    # interpolation of numbers already measured, no -f format string, so a
    # name with braces in it can't make this fail while describing a failure.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Source,

        [Parameter(Mandatory)]
        [pscustomobject]$Measure
    )

    if ($Measure.LongestName -gt $script:MaxPathNameLength) {
        return "$Source can't be extracted here: one of its names is $($Measure.LongestName) characters, longer than the $($script:MaxPathNameLength) Windows allows. " +
        'Extract it yourself with a tool that can shorten or skip that entry, put the extracted folder in InputRoot, and rerun.'
    }
    $count = ''
    if ($Measure.LongestPath -gt 0) {
        $count = " (the longest needs $($Measure.LongestPath) characters)"
    }
    return "$Source can't be extracted here: some of its paths are longer than Windows allows$count. " +
    'Point OutputRoot at a shorter folder such as D:\Out, or extract it yourself nearer the drive root, put the extracted folder in InputRoot, and rerun.'
}

function Expand-ZipArchiveSafe {
    <#
    .SYNOPSIS
        Extracts a ZIP into a new folder after safety checks.
    .DESCRIPTION
        Runs Assert-ZipArchiveSafe and a free space check first. Extraction
        is a streaming copy that counts bytes, so an entry whose header
        understates its size is stopped as soon as it writes more than it
        declared, and the run stops if the running total passes the cap.
        Nothing is executed or interpreted. Destination must not exist. On
        any failure the partial extract is removed.

        Deep paths, such as KAPE's WER report archives under ProgramData,
        are written through the \\?\ extended-length prefix on Windows, so
        they extract past the 260-character limit. A path that still can't
        be created, such as a single name over 255 characters, or any long
        path on a runtime that refuses the prefix, fails the extraction
        with guidance instead of a raw .NET error.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([long])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Destination,

        [Parameter(Mandatory)]
        [long]$MaxUncompressedBytes,

        [Parameter(Mandatory)]
        [double]$MaxRatio
    )

    Initialize-ZipSupport

    if (Test-Path -LiteralPath $Destination) {
        throw "Extraction folder already exists: $Destination"
    }

    if (-not $PSCmdlet.ShouldProcess($Destination, "Extract $Path")) {
        return
    }

    $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
    $created = $false
    try {
        $declared = Assert-ZipArchiveSafe -Archive $archive -Destination $Destination -MaxUncompressedBytes $MaxUncompressedBytes -MaxRatio $MaxRatio

        $parent = Split-Path -Path $Destination -Parent
        $free = Get-FreeSpace -Path $parent
        $margin = [long][math]::Max($declared * $script:FreeSpaceMarginFraction, $script:FreeSpaceMarginMinBytes)
        $needed = $declared + $margin
        if ($null -eq $free) {
            Write-Warning "Could not read free space for $parent. Extracting $Path without a free space check."
        }
        elseif ($free -lt $needed) {
            throw ("Not enough free space to extract {0}: needs {1:N0} bytes including margin, {2:N0} bytes free." -f $Path, $needed, $free)
        }

        [System.IO.Directory]::CreateDirectory($Destination) | Out-Null
        $created = $true

        $buffer = New-Object byte[] $script:ExtractBufferSize
        $written = [long]0

        foreach ($entry in $archive.Entries) {
            if ($entry.FullName.Length -eq 0) {
                continue
            }
            $target = Get-SafeEntryTarget -Destination $Destination -Name $entry.FullName

            if ($entry.FullName.EndsWith('/') -or $entry.FullName.EndsWith('\')) {
                [System.IO.Directory]::CreateDirectory((Get-ExtendedLengthPath -Path $target)) | Out-Null
                continue
            }

            [System.IO.Directory]::CreateDirectory((Get-ExtendedLengthPath -Path ([System.IO.Path]::GetDirectoryName($target)))) | Out-Null

            $in = $null
            $out = $null
            try {
                $in = $entry.Open()
                $out = New-Object System.IO.FileStream((Get-ExtendedLengthPath -Path $target), [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                $entryWritten = [long]0
                while (($read = $in.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $entryWritten += $read
                    $written += $read
                    if ($entryWritten -gt $entry.Length) {
                        throw "Entry '$($entry.FullName)' expanded past its declared size of $($entry.Length) bytes."
                    }
                    if ($written -gt $MaxUncompressedBytes) {
                        throw "Extraction passed the cap of $MaxUncompressedBytes bytes (ZipMaxUncompressedGB)."
                    }
                    $out.Write($buffer, 0, $read)
                }
            }
            finally {
                if ($null -ne $out) { $out.Dispose() }
                if ($null -ne $in) { $in.Dispose() }
            }
        }

        return $written
    }
    catch {
        if ($created -and (Test-Path -LiteralPath $Destination)) {
            try {
                Remove-DirectoryTree -Path $Destination
            }
            catch {
                Write-Warning "Could not remove the partial extract ${Destination}: $($_.Exception.Message). Teardown will try again."
            }
        }
        # The discovery check should stop these first. If .NET still meets
        # an unsupported method or an encrypted entry, replace its raw
        # message with the same guidance.
        $inner = $_.Exception
        while ($null -ne $inner.InnerException) {
            $inner = $inner.InnerException
        }
        if ($inner -is [System.IO.InvalidDataException] -and $inner.Message -match '(?i)compress|encrypt|not supported') {
            $name = [System.IO.Path]::GetFileName($Path)
            Write-Verbose "${name}: $($inner.Message)"
            throw "$name can't be extracted by this tool (unsupported compression or encryption). Extract it yourself, put the extracted folder, or the disk image inside it, in InputRoot, and rerun."
        }

        # A path Windows can't create, even with the extended-length prefix.
        $measure = Get-ZipPathMeasure -Archive $archive -Destination $Destination
        # Only a failure that is about path length gets this guidance. Any
        # other error, such as a full disk, a locked file or a duplicate
        # entry, is rethrown with its own message.
        $tooLong = $inner -is [System.IO.PathTooLongException]
        if (-not $tooLong -and ($measure.LongestPath -ge $script:MaxPlainPathLength -or $measure.LongestName -gt $script:MaxPathNameLength)) {
            if ($inner -is [System.IO.IOException]) {
                # Windows reports a name or path past its limits as
                # ERROR_FILENAME_EXCED_RANGE (206), or as ERROR_INVALID_NAME
                # (123) for a single name over 255 characters.
                $code = $inner.HResult -band 0xFFFF
                $tooLong = ($code -eq 206 -or ($code -eq 123 -and $measure.LongestName -gt $script:MaxPathNameLength))
            }
            else {
                # A runtime that refuses long or extended-length paths
                # outright.
                $tooLong = ($inner -is [System.ArgumentException] -or $inner -is [System.NotSupportedException])
            }
        }
        if ($tooLong) {
            $name = [System.IO.Path]::GetFileName($Path)
            Write-Verbose "${name}: $($inner.GetType().Name): $($inner.Message)"
            throw (Get-LongPathGuidance -Source $name -Measure $measure)
        }
        throw
    }
    finally {
        $archive.Dispose()
    }
}
