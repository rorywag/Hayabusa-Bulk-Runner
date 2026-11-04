# How long to wait for a freshly mounted image's volumes, and then for
# Windows to assign a drive letter, before falling back to a mount folder.
$script:VolumeWaitSeconds = 10
$script:DriveLetterWaitSeconds = 3
$script:PollMilliseconds = 500

# Each image hash reads this much at a time.
$script:ImageHashBlockBytes = 4MB

# KAPE VHD and VHDX containers are dirty on creation, so a read-only mount
# surfaces no disk and no volume. Each image is mounted through a
# differencing child instead: the child is mounted read-write, the journal
# replays into the child, and the parent image is never written.
#
# The Windows-only calls are kept in the small wrapper functions below so
# the orchestration in Mount-CollectionImage can be tested without them.

function Assert-MountSupported {
    [CmdletBinding()]
    param()

    if (-not (Test-IsWindowsHost)) {
        throw 'Mounting disk images requires Windows.'
    }
    if ($null -eq (Get-Command -Name Mount-DiskImage -ErrorAction SilentlyContinue)) {
        throw 'Mount-DiskImage is not available. The Storage module is required.'
    }
}

function Get-DiskpartPath {
    # Full path, so a diskpart.exe earlier on PATH is never picked up.
    [CmdletBinding()]
    [OutputType([string])]
    param()

    return [System.IO.Path]::Combine($env:SystemRoot, 'System32', 'diskpart.exe')
}

function Get-DifferencingChildScript {
    <#
    .SYNOPSIS
        Returns the diskpart script that creates a differencing child.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$ParentPath,

        [Parameter(Mandatory)]
        [string]$ChildPath
    )

    foreach ($p in @($ParentPath, $ChildPath)) {
        if ($p.Contains('"')) {
            throw "Path contains a double quote and cannot be passed to diskpart: $p"
        }
        # diskpart misreads non-ASCII characters in a piped script, so it is
        # refused here with a clear message instead of diskpart failing to
        # find the path.
        if ($p -match '[^\x20-\x7E]') {
            throw "Path can't be passed to diskpart, which can't reliably read non-ASCII characters: $p. To mount disk images, use InputRoot and OutputRoot paths with only ASCII characters."
        }
    }
    return "create vdisk file=`"$ChildPath`" parent=`"$ParentPath`""
}

function Test-ImageAttached {
    # True if Windows reports the image file as attached.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$ImagePath
    )

    Assert-MountSupported
    $state = Get-DiskImage -ImagePath $ImagePath -ErrorAction SilentlyContinue
    return ($null -ne $state -and [bool]$state.Attached)
}

function New-DifferencingChild {
    <#
    .SYNOPSIS
        Creates a differencing child of an image with diskpart.
    .DESCRIPTION
        diskpart rather than New-VHD, so Hyper-V is not needed. The script
        is piped to diskpart's standard input as ASCII. A path with any
        non-ASCII character is refused first with a clear message, since
        diskpart misreads it. Success is checked twice:
        diskpart's exit code, and that the child file now exists. On failure
        diskpart's output is included in the error.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$ParentPath,

        [Parameter(Mandatory)]
        [string]$ChildPath
    )

    Assert-MountSupported
    $script = Get-DifferencingChildScript -ParentPath $ParentPath -ChildPath $ChildPath

    if (-not $PSCmdlet.ShouldProcess($ChildPath, "Create differencing child of $ParentPath")) {
        return
    }

    $ErrorActionPreference = 'Continue'
    # PowerShell encodes text piped to a native program with $OutputEncoding.
    # The script is plain ASCII, checked above, so it is sent as ASCII on
    # every PowerShell.
    $OutputEncoding = [System.Text.Encoding]::ASCII
    $output = @($script | & (Get-DiskpartPath) 2>&1 | ForEach-Object { [string]$_ })
    $exit = $LASTEXITCODE

    if ($exit -ne 0 -or -not (Test-Path -LiteralPath $ChildPath -PathType Leaf)) {
        $detail = (($output | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ' | ')
        throw "diskpart did not create the differencing child $ChildPath (exit code $exit). $detail"
    }
}

function Mount-ImageFile {
    # Mounts the differencing child read-write. Never called on a parent.
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$ImagePath
    )

    Assert-MountSupported
    if ($PSCmdlet.ShouldProcess($ImagePath, 'Mount read-write')) {
        Mount-DiskImage -ImagePath $ImagePath -Access ReadWrite -ErrorAction Stop | Out-Null
    }
}

function Dismount-CollectionImage {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$ImagePath
    )

    Assert-MountSupported

    if (-not $PSCmdlet.ShouldProcess($ImagePath, 'Dismount')) {
        return
    }

    Dismount-DiskImage -ImagePath $ImagePath -ErrorAction Stop | Out-Null
    if (Test-ImageAttached -ImagePath $ImagePath) {
        throw "$ImagePath is still attached after Dismount-DiskImage."
    }
}

function Get-ImageVolumeCandidate {
    <#
    .SYNOPSIS
        Lists partitions of a mounted image that carry a file system.
    .DESCRIPTION
        Follows the association chain Get-DiskImage | Get-Disk |
        Get-Partition | Get-Volume. The image's Number property does not
        resolve reliably for a mounted image, so it is not used.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ImagePath
    )

    Assert-MountSupported

    $disk = Get-DiskImage -ImagePath $ImagePath -ErrorAction Stop | Get-Disk -ErrorAction SilentlyContinue
    if ($null -eq $disk) {
        return
    }

    foreach ($partition in @($disk | Get-Partition -ErrorAction SilentlyContinue)) {
        $volume = $partition | Get-Volume -ErrorAction SilentlyContinue
        if ($null -eq $volume -or [string]::IsNullOrEmpty($volume.FileSystem)) {
            continue
        }
        $letter = $null
        if ($partition.DriveLetter -and [char]::IsLetter([char]$partition.DriveLetter)) {
            $letter = [string]$partition.DriveLetter
        }
        [pscustomobject]@{
            DiskNumber      = $partition.DiskNumber
            PartitionNumber = $partition.PartitionNumber
            DriveLetter     = $letter
            VolumePath      = $volume.Path
            FileSystem      = $volume.FileSystem
        }
    }
}

function Add-CollectionAccessPath {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [int]$DiskNumber,

        [Parameter(Mandatory)]
        [int]$PartitionNumber,

        [Parameter(Mandatory)]
        [string]$AccessPath
    )

    Assert-MountSupported

    if ($PSCmdlet.ShouldProcess($AccessPath, 'Add partition access path')) {
        Add-PartitionAccessPath -DiskNumber $DiskNumber -PartitionNumber $PartitionNumber -AccessPath $AccessPath -ErrorAction Stop
    }
}

function Remove-CollectionAccessPath {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [int]$DiskNumber,

        [Parameter(Mandatory)]
        [int]$PartitionNumber,

        [Parameter(Mandatory)]
        [string]$AccessPath
    )

    Assert-MountSupported

    if ($PSCmdlet.ShouldProcess($AccessPath, 'Remove partition access path')) {
        Remove-PartitionAccessPath -DiskNumber $DiskNumber -PartitionNumber $PartitionNumber -AccessPath $AccessPath -ErrorAction Stop
    }
}

function Remove-DifferencingChild {
    <#
    .SYNOPSIS
        Deletes a differencing child file.
    .DESCRIPTION
        Only a .vhd or .vhdx file directly inside DiffRoot is deleted. The
        caller has already dismounted it.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$DiffRoot
    )

    $parent = Split-Path -Path $Path -Parent
    $sameRoot = $parent.TrimEnd('\', '/').Equals($DiffRoot.TrimEnd('\', '/'), [System.StringComparison]::OrdinalIgnoreCase)
    if (-not $sameRoot -or -not (Test-DiskImageName -Name $Path)) {
        throw "Refusing to delete ${Path}: it is not a differencing child directly under $DiffRoot."
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }
    if ($PSCmdlet.ShouldProcess($Path, 'Delete differencing child')) {
        [System.IO.File]::Delete($Path)
    }
}

function Test-VolumeHasEventLog {
    # True if Windows\System32\winevt\Logs sits at the volume root or one
    # folder down, which is how KAPE lays out its C\Windows\... tree.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$VolumePath
    )

    $rel = [System.IO.Path]::Combine('Windows', 'System32', 'winevt', 'Logs')
    try {
        if ([System.IO.Directory]::Exists([System.IO.Path]::Combine($VolumePath, $rel))) {
            return $true
        }
        foreach ($dir in [System.IO.Directory]::GetDirectories($VolumePath)) {
            if ([System.IO.Directory]::Exists([System.IO.Path]::Combine($dir, $rel))) {
                return $true
            }
        }
    }
    catch {
        Write-Verbose "Could not inspect volume ${VolumePath}: $($_.Exception.Message)"
    }
    return $false
}

function Resolve-ImageVolume {
    <#
    .SYNOPSIS
        Picks the volume to point Hayabusa at on a mounted image.
    .DESCRIPTION
        One volume with a file system is used as is. With several, the one
        holding Windows\System32\winevt\Logs at its root or one folder down
        is used. None, or more than one match, is an error listing the
        volumes, since guessing would risk processing the wrong partition.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$ImagePath
    )

    $deadline = (Get-Date).AddSeconds($script:VolumeWaitSeconds)
    $candidates = @()
    while ($true) {
        $candidates = @(Get-ImageVolumeCandidate -ImagePath $ImagePath)
        if ($candidates.Count -gt 0 -or (Get-Date) -ge $deadline) {
            break
        }
        Start-Sleep -Milliseconds $script:PollMilliseconds
    }

    if ($candidates.Count -eq 0) {
        throw "No readable volume found on $ImagePath. It may be encrypted, unformatted or damaged."
    }

    $chosen = $null
    if ($candidates.Count -eq 1) {
        $chosen = $candidates[0]
    }
    else {
        $withLogs = @($candidates | Where-Object { Test-VolumeHasEventLog -VolumePath $_.VolumePath })
        if ($withLogs.Count -ne 1) {
            $list = ($candidates | ForEach-Object { "partition $($_.PartitionNumber) $($_.FileSystem)" }) -join ', '
            throw "Could not pick one volume on ${ImagePath}: $($withLogs.Count) of $($candidates.Count) volumes hold event logs ($list)."
        }
        $chosen = $withLogs[0]
    }

    # Windows can assign the letter a moment after the volume appears.
    $letterDeadline = (Get-Date).AddSeconds($script:DriveLetterWaitSeconds)
    while ($null -eq $chosen.DriveLetter -and (Get-Date) -lt $letterDeadline) {
        Start-Sleep -Milliseconds $script:PollMilliseconds
        $again = @(Get-ImageVolumeCandidate -ImagePath $ImagePath | Where-Object { $_.PartitionNumber -eq $chosen.PartitionNumber })
        if ($again.Count -eq 1) {
            $chosen = $again[0]
        }
    }

    return $chosen
}

function Get-ImageSha256 {
    <#
    .SYNOPSIS
        The SHA-256 of an evidence image, read in full.
    .DESCRIPTION
        Read in 4 MB blocks from a stream opened read-only, sharing only
        reads, so nothing can write to the image while it's hashed, and
        marked for sequential reading. The bytes done are reported to the
        current console step as it goes. The hash is the same as
        Get-FileHash gives, uppercase hex.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $stream = $null
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = New-Object System.IO.FileStream((Get-ExtendedLengthPath -Path $Path), [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read, 4096, [System.IO.FileOptions]::SequentialScan)
        $total = $stream.Length
        $buffer = New-Object byte[] $script:ImageHashBlockBytes
        $done = 0L
        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            [void]$sha.TransformBlock($buffer, 0, $read, $null, 0)
            $done += $read
            Update-ConsoleStep -Done $done -Total $total
        }
        [void]$sha.TransformFinalBlock((New-Object byte[] 0), 0, 0)
        return ([System.BitConverter]::ToString($sha.Hash)).Replace('-', '')
    }
    finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
        $sha.Dispose()
    }
}

function Mount-CollectionImage {
    <#
    .SYNOPSIS
        Mounts an image through a differencing child and returns the path
        to hand to -d.
    .DESCRIPTION
        1. Refuses if the parent image is already attached: it was not
           mounted by this run, so it is left alone. Then reads the image's
           own format headers and refuses a differencing disk, or one whose
           headers don't parse cleanly, before anything is created, hashed
           or mounted.
        2. Hashes the parent with SHA-256, and adds a teardown step that
           hashes it again once the child is dismounted and deleted. The
           record of both is added to ImageHashRecord, if given, so the
           caller has it even when the mount fails partway.
        3. Creates a differencing child at DiffRoot\<Collection>.<ext>, the
           extension matching the parent. A leftover child from an earlier
           run is replaced, unless it is still attached.
        4. Mounts the child read-write. The journal replays into the child
           and the parent is never written.
        5. Picks the volume through the disk association chain, uses the
           drive letter Windows assigns, and falls back to an empty folder
           under MountRoot attached with Add-PartitionAccessPath when no
           letter is assigned.

        Each step that needs undoing is added to Teardown as soon as it
        succeeds, so Invoke-CollectionCleanup can undo a partial mount.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$ImagePath,

        [Parameter(Mandatory)]
        [string]$MountRoot,

        [Parameter(Mandatory)]
        [string]$DiffRoot,

        [Parameter(Mandatory)]
        [string]$Collection,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$Teardown,

        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$ImageHashRecord
    )

    Assert-MountSupported

    if (-not (Test-DiskImageName -Name $ImagePath)) {
        throw "Not a .vhd or .vhdx image: $ImagePath"
    }
    if (Test-ImageAttached -ImagePath $ImagePath) {
        throw "$ImagePath is already attached. Dismount it first. It was not mounted by this run, so it is left alone."
    }
    Assert-ImageHasNoParent -ImagePath $ImagePath

    if (-not (Test-Path -LiteralPath $DiffRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $DiffRoot -Force | Out-Null
    }
    $extension = [System.IO.Path]::GetExtension($ImagePath).ToLowerInvariant()
    $child = Join-Path -Path $DiffRoot -ChildPath "$Collection$extension"

    if (Test-Path -LiteralPath $child) {
        if (Test-ImageAttached -ImagePath $child) {
            throw "Differencing child $child from an earlier run is still attached. Dismount it and rerun."
        }
        Write-Verbose "Replacing leftover differencing child $child."
        Remove-DifferencingChild -Path $child -DiffRoot $DiffRoot
    }

    # Hashed just before the child is created, and again by the teardown
    # step once the child is dismounted and deleted.
    Start-ConsoleStep -Name 'Hash before mount'
    try {
        $before = Get-ImageSha256 -Path $ImagePath
    }
    catch {
        Complete-ConsoleStep -Failed -Reason $_.Exception.Message
        throw
    }
    Complete-ConsoleStep -Result 'done'
    $record = [pscustomobject]@{
        ImagePath = $ImagePath
        Before    = $before
        After     = $null
        Match     = $null
    }
    if ($null -ne $ImageHashRecord) {
        $ImageHashRecord.Add($record)
    }
    Add-TeardownStep -Teardown $Teardown -Kind 'CheckImageHash' -Target $ImagePath -Record $record

    Start-ConsoleStep -Name 'Mount'
    try {
        New-DifferencingChild -ParentPath $ImagePath -ChildPath $child
        Add-TeardownStep -Teardown $Teardown -Kind 'RemoveDiffChild' -Target $child -Root $DiffRoot

        Mount-ImageFile -ImagePath $child
        Add-TeardownStep -Teardown $Teardown -Kind 'Dismount' -Target $child

        $volume = Resolve-ImageVolume -ImagePath $child

        if ($null -ne $volume.DriveLetter) {
            $mounted = [pscustomobject]@{
                Path        = "$($volume.DriveLetter):\"
                DriveLetter = $volume.DriveLetter
                MountPath   = $null
                ChildPath   = $child
                ImageHash   = $record
            }
        }
        else {
            $mountDir = Join-Path -Path $MountRoot -ChildPath $Collection
            if (Test-Path -LiteralPath $mountDir) {
                $item = Get-Item -LiteralPath $mountDir -Force
                if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                    throw "$mountDir is still a mount point from an earlier run. Remove it with 'mountvol $mountDir /D' and rerun."
                }
                if (@(Get-ChildItem -LiteralPath $mountDir -Force).Count -gt 0) {
                    throw "$mountDir is not empty and cannot be used as a mount folder."
                }
            }
            else {
                New-Item -ItemType Directory -Path $mountDir -Force | Out-Null
            }
            Add-TeardownStep -Teardown $Teardown -Kind 'RemoveMountFolder' -Target $mountDir -Root $MountRoot

            $accessPath = $mountDir.TrimEnd('\') + '\'
            Add-CollectionAccessPath -DiskNumber $volume.DiskNumber -PartitionNumber $volume.PartitionNumber -AccessPath $accessPath
            Add-TeardownStep -Teardown $Teardown -Kind 'RemoveAccessPath' -Target $accessPath -DiskNumber $volume.DiskNumber -PartitionNumber $volume.PartitionNumber

            $mounted = [pscustomobject]@{
                Path        = $mountDir
                DriveLetter = $null
                MountPath   = $mountDir
                ChildPath   = $child
                ImageHash   = $record
            }
        }
    }
    catch {
        Complete-ConsoleStep -Failed -Reason $_.Exception.Message
        throw
    }
    Complete-ConsoleStep -Result 'done'
    return $mounted
}
