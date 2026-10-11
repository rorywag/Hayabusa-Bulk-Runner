# How long to wait for a freshly mounted image's volumes, and then for
# Windows to assign a drive letter, before falling back to a mount folder.
$script:VolumeWaitSeconds = 10
$script:DriveLetterWaitSeconds = 3
$script:PollMilliseconds = 500

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

function Test-VolumeHasEventLog {
    # True if Windows\System32\winevt\Logs sits at the volume root or one
    # folder down, which is how KAPE lays out its C\Windows\... tree.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$VolumePath
    )

    $rel = 'Windows\System32\winevt\Logs'
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

function Get-ImageVolumeCandidate {
    # Lists partitions of a mounted image that carry a file system.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ImagePath
    )

    $image = Get-DiskImage -ImagePath $ImagePath -ErrorAction Stop
    if ($null -eq $image.Number) {
        return
    }

    foreach ($partition in @(Get-Partition -DiskNumber $image.Number -ErrorAction SilentlyContinue)) {
        $volume = $partition | Get-Volume -ErrorAction SilentlyContinue
        if ($null -eq $volume -or [string]::IsNullOrEmpty($volume.FileSystem)) {
            continue
        }
        $letter = $null
        if ($partition.DriveLetter -and [char]::IsLetter([char]$partition.DriveLetter)) {
            $letter = [string]$partition.DriveLetter
        }
        [pscustomobject]@{
            DiskNumber      = $image.Number
            PartitionNumber = $partition.PartitionNumber
            DriveLetter     = $letter
            VolumePath      = $volume.Path
            FileSystem      = $volume.FileSystem
        }
    }
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

function Mount-CollectionImage {
    <#
    .SYNOPSIS
        Mounts a disk image read-only and returns the path to hand to -d.
    .DESCRIPTION
        Mount-DiskImage is read-write by default, so -Access ReadOnly is
        always passed. The drive letter Windows assigns is used. If none is
        assigned, the volume is attached to an empty folder under MountRoot
        with Add-PartitionAccessPath instead. That folder lives on the output
        volume, not on the evidence.

        An image that is already attached is refused rather than reused or
        dismounted, since this run did not mount it.

        Each step that needs undoing is added to Teardown as soon as it
        succeeds, so Invoke-CollectionCleanup can undo a partial mount.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$ImagePath,

        [Parameter(Mandatory)]
        [string]$MountRoot,

        [Parameter(Mandatory)]
        [string]$Collection,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$Teardown
    )

    Assert-MountSupported

    if (-not $PSCmdlet.ShouldProcess($ImagePath, 'Mount read-only')) {
        return
    }

    $existing = Get-DiskImage -ImagePath $ImagePath -ErrorAction SilentlyContinue
    if ($null -ne $existing -and $existing.Attached) {
        throw "$ImagePath is already attached. Dismount it first. It was not mounted by this run, so it is left alone."
    }

    Mount-DiskImage -ImagePath $ImagePath -Access ReadOnly -ErrorAction Stop | Out-Null
    Add-TeardownStep -Teardown $Teardown -Kind 'Dismount' -Target $ImagePath

    $volume = Resolve-ImageVolume -ImagePath $ImagePath

    if ($null -ne $volume.DriveLetter) {
        return [pscustomobject]@{
            Path        = "$($volume.DriveLetter):\"
            DriveLetter = $volume.DriveLetter
            MountPath   = $null
        }
    }

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
    Add-PartitionAccessPath -DiskNumber $volume.DiskNumber -PartitionNumber $volume.PartitionNumber -AccessPath $accessPath -ErrorAction Stop
    Add-TeardownStep -Teardown $Teardown -Kind 'RemoveAccessPath' -Target $accessPath -DiskNumber $volume.DiskNumber -PartitionNumber $volume.PartitionNumber

    return [pscustomobject]@{
        Path        = $mountDir
        DriveLetter = $null
        MountPath   = $mountDir
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
    $after = Get-DiskImage -ImagePath $ImagePath -ErrorAction SilentlyContinue
    if ($null -ne $after -and $after.Attached) {
        throw "$ImagePath is still attached after Dismount-DiskImage."
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
