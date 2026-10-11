$script:DiskImageExtensions = @('.vhd', '.vhdx')

# Copy buffer for streaming extraction.
$script:ExtractBufferSize = 81920

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

    $ext = [System.IO.Path]::GetExtension($Name)
    return ($script:DiskImageExtensions -contains $ext.ToLowerInvariant())
}

function Get-ZipEntryInfo {
    <#
    .SYNOPSIS
        Lists a ZIP's entries from its central directory without extracting.
    .DESCRIPTION
        Returns entry counts, declared sizes, and the names of any disk
        images, evtx files and nested ZIPs inside. An archive that cannot be
        opened is returned with Readable set to false and the reason in
        ReadError, so the caller decides what to do with it.
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
        ReadError         = $null
        EntryCount        = 0
        UncompressedBytes = [long]0
        CompressedBytes   = [long]0
        ImageEntries      = @()
        EvtxEntryCount    = 0
        NestedZipEntries  = @()
    }

    $archive = $null
    try {
        $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
        $images = New-Object System.Collections.Generic.List[string]
        $nested = New-Object System.Collections.Generic.List[string]
        $evtx = 0
        $uncompressed = [long]0
        $compressed = [long]0

        foreach ($entry in $archive.Entries) {
            $uncompressed += $entry.Length
            $compressed += $entry.CompressedLength
            $ext = [System.IO.Path]::GetExtension($entry.FullName).ToLowerInvariant()
            if ($script:DiskImageExtensions -contains $ext) {
                $images.Add($entry.FullName)
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
        $info.ImageEntries = $images.ToArray()
        $info.EvtxEntryCount = $evtx
        $info.NestedZipEntries = $nested.ToArray()
    }
    catch {
        $info.ReadError = $_.Exception.Message
    }
    finally {
        if ($null -ne $archive) {
            $archive.Dispose()
        }
    }

    return $info
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
        hundreds of times smaller. Returns the declared uncompressed total.
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
            $problems.Add("'$($entry.FullName)': resolves outside the extraction folder")
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
                [System.IO.Directory]::CreateDirectory($target) | Out-Null
                continue
            }

            [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($target)) | Out-Null

            $in = $null
            $out = $null
            try {
                $in = $entry.Open()
                $out = New-Object System.IO.FileStream($target, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
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
            [System.IO.Directory]::Delete($Destination, $true)
        }
        throw
    }
    finally {
        $archive.Dispose()
    }
}
