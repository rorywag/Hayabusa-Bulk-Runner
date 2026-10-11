# Teardown always runs in this order, whatever order the steps were added:
# remove the folder mount point, dismount the differencing child, remove the
# empty mount folder, delete the differencing child, then remove the extract.
# The parent image is never touched.
$script:TeardownOrder = @('RemoveAccessPath', 'Dismount', 'RemoveMountFolder', 'RemoveDiffChild', 'RemoveExtract')

# Steps skipped under -KeepArtifacts. The image is always dismounted.
$script:KeptArtifactKinds = @('RemoveDiffChild', 'RemoveExtract')

# Steps skipped when an image may still be mounted, because the files they
# remove could still be in use.
$script:NeedsDismountKinds = @('RemoveMountFolder', 'RemoveDiffChild', 'RemoveExtract')

function Add-TeardownStep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$Teardown,

        [Parameter(Mandatory)]
        [ValidateSet('RemoveAccessPath', 'Dismount', 'RemoveMountFolder', 'RemoveDiffChild', 'RemoveExtract')]
        [string]$Kind,

        [Parameter(Mandatory)]
        [string]$Target,

        [string]$Root,
        [int]$DiskNumber = -1,
        [int]$PartitionNumber = -1
    )

    $Teardown.Add([pscustomobject]@{
            Kind            = $Kind
            Target          = $Target
            Root            = $Root
            DiskNumber      = $DiskNumber
            PartitionNumber = $PartitionNumber
            Done            = $false
        })
}

function Remove-MountFolder {
    <#
    .SYNOPSIS
        Removes an empty mount folder, never recursively.
    .DESCRIPTION
        A folder that is still a mount point is refused. A non-recursive
        delete can never walk into a mounted volume.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$MountRoot
    )

    if (-not (Test-PathIsWithin -Path $Path -Parent $MountRoot) -or (Test-PathIsWithin -Path $MountRoot -Parent $Path)) {
        throw "Refusing to remove ${Path}: it is not a folder under $MountRoot."
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        throw "Refusing to remove ${Path}: it is still a mount point."
    }
    if ($PSCmdlet.ShouldProcess($Path, 'Remove empty mount folder')) {
        [System.IO.Directory]::Delete($Path, $false)
    }
}

function Remove-CollectionExtract {
    <#
    .SYNOPSIS
        Recursively removes an extract folder under WorkRoot.
    .DESCRIPTION
        Only a folder strictly inside WorkRoot is removed. Directory.Delete
        removes links rather than following them.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$WorkRoot
    )

    if (-not (Test-PathIsWithin -Path $Path -Parent $WorkRoot) -or (Test-PathIsWithin -Path $WorkRoot -Parent $Path)) {
        throw "Refusing to remove ${Path}: it is not a folder under $WorkRoot."
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }
    if ($PSCmdlet.ShouldProcess($Path, 'Remove extract')) {
        [System.IO.Directory]::Delete($Path, $true)
    }
}

function Invoke-CollectionCleanup {
    <#
    .SYNOPSIS
        Tears down whatever Resolve-CollectionInput set up for a collection.
    .DESCRIPTION
        Runs in a fixed order: remove the folder mount point, dismount the
        differencing child, remove the empty mount folder, delete the
        differencing child, remove the extract. With KeepArtifacts the
        differencing child and extract stay on disk, but the image is
        always dismounted.

        If removing the mount point or dismounting fails, the mount folder,
        differencing child and extract are left in place, since the image
        may still be in use.
        Every other step still runs. All failures are reported together at
        the end.

        Safe to call more than once. Steps already done are skipped.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [pscustomobject]$Resolved
    )

    if ($null -eq $Resolved) {
        return
    }

    $errors = New-Object System.Collections.Generic.List[string]
    $mountStillActive = $false

    foreach ($kind in $script:TeardownOrder) {
        foreach ($step in @($Resolved.Teardown | Where-Object { $_.Kind -eq $kind -and -not $_.Done })) {
            if ($script:KeptArtifactKinds -contains $kind -and $Resolved.KeepArtifacts) {
                Write-Verbose "Keeping $($step.Target) (-KeepArtifacts)."
                $step.Done = $true
                continue
            }
            if ($script:NeedsDismountKinds -contains $kind -and $mountStillActive) {
                $errors.Add("Left $($step.Target) in place because an image may still be mounted.")
                continue
            }

            try {
                switch ($kind) {
                    'RemoveAccessPath' {
                        Remove-CollectionAccessPath -DiskNumber $step.DiskNumber -PartitionNumber $step.PartitionNumber -AccessPath $step.Target
                    }
                    'Dismount' {
                        Dismount-CollectionImage -ImagePath $step.Target
                    }
                    'RemoveMountFolder' {
                        Remove-MountFolder -Path $step.Target -MountRoot $step.Root
                    }
                    'RemoveDiffChild' {
                        Remove-DifferencingChild -Path $step.Target -DiffRoot $step.Root
                    }
                    'RemoveExtract' {
                        Remove-CollectionExtract -Path $step.Target -WorkRoot $step.Root
                    }
                }
                $step.Done = $true
                Write-Verbose "Teardown: $kind $($step.Target)"
            }
            catch {
                $errors.Add("$kind $($step.Target) failed: $($_.Exception.Message)")
                if ($kind -eq 'RemoveAccessPath' -or $kind -eq 'Dismount') {
                    $mountStillActive = $true
                }
            }
        }
    }

    if ($errors.Count -gt 0) {
        throw ("Cleanup for collection {0} did not complete:`n  {1}" -f $Resolved.Collection, ($errors -join "`n  "))
    }
}

function Clear-StaleExtract {
    # Removes an extract left by an earlier run, after checking no image
    # inside it is still attached.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$WorkRoot
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    if (Test-IsWindowsHost) {
        $images = @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
                Where-Object { Test-DiskImageName -Name $_.Name })
        foreach ($image in $images) {
            if (Test-ImageAttached -ImagePath $image.FullName) {
                throw "Leftover extract $Path holds $($image.FullName), which is still attached. Dismount it and rerun."
            }
        }
    }

    Write-Verbose "Removing leftover extract $Path."
    Remove-CollectionExtract -Path $Path -WorkRoot $WorkRoot
}

function Resolve-CollectionInput {
    <#
    .SYNOPSIS
        Turns a discovered collection into a path Hayabusa can read with -d.
    .DESCRIPTION
        Loose: the folder as is.
        Vhd or Vhdx: mounted through a differencing child under
        OutputRoot\_diff, so the evidence image is never written.
        Zip: extracted to OutputRoot\_work\<collection> after safety checks.
        If the extract holds exactly one disk image, that image is mounted
        the same way. Otherwise the extract is used as a loose folder.
        Nothing deeper than this one level is unpacked.

        Returns Collection, Source, InputType, SourcePath, Path, ImagePath,
        ChildPath, ExtractPath, MountPath, Warnings, Teardown and
        KeepArtifacts.
        Warnings holds what was found at resolve time. Discovery warnings
        stay on the discovered collection.

        Call Invoke-CollectionCleanup on the result in a finally block. If
        resolution fails partway, the steps done so far are undone before
        the error is rethrown.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Collection,

        [Parameter(Mandatory)]
        [string]$OutputRoot,

        [Parameter(Mandatory)]
        [long]$MaxUncompressedBytes,

        [Parameter(Mandatory)]
        [double]$MaxRatio,

        [switch]$KeepArtifacts
    )

    $workRoot = Join-Path -Path $OutputRoot -ChildPath '_work'
    $mountRoot = Join-Path -Path $OutputRoot -ChildPath '_mnt'
    $diffRoot = Join-Path -Path $OutputRoot -ChildPath '_diff'
    $teardown = New-Object System.Collections.Generic.List[object]
    $warnings = New-Object System.Collections.Generic.List[string]

    $result = [pscustomobject]@{
        Collection    = $Collection.Collection
        Source        = $Collection.Source
        InputType     = $Collection.InputType
        SourcePath    = $Collection.SourcePath
        Path          = $null
        ImagePath     = $null
        ChildPath     = $null
        ExtractPath   = $null
        MountPath     = $null
        Warnings      = $warnings
        Teardown      = $teardown
        KeepArtifacts = $KeepArtifacts.IsPresent
    }

    try {
        switch ($Collection.InputType) {
            'Loose' {
                $result.Path = $Collection.SourcePath
            }
            { $_ -eq 'Vhd' -or $_ -eq 'Vhdx' } {
                $mount = Mount-CollectionImage -ImagePath $Collection.SourcePath -MountRoot $mountRoot -DiffRoot $diffRoot -Collection $Collection.Collection -Teardown $teardown
                $result.ImagePath = $Collection.SourcePath
                $result.ChildPath = $mount.ChildPath
                $result.MountPath = $mount.MountPath
                $result.Path = $mount.Path
            }
            'Zip' {
                $extract = Join-Path -Path $workRoot -ChildPath $Collection.Collection
                Clear-StaleExtract -Path $extract -WorkRoot $workRoot
                if (-not (Test-Path -LiteralPath $workRoot)) {
                    New-Item -ItemType Directory -Path $workRoot -Force | Out-Null
                }

                Add-TeardownStep -Teardown $teardown -Kind 'RemoveExtract' -Target $extract -Root $workRoot
                Expand-ZipArchiveSafe -Path $Collection.SourcePath -Destination $extract -MaxUncompressedBytes $MaxUncompressedBytes -MaxRatio $MaxRatio | Out-Null
                $result.ExtractPath = $extract

                $files = @(Get-ChildItem -LiteralPath $extract -Recurse -File -Force)
                $images = @($files | Where-Object { Test-DiskImageName -Name $_.Name })
                $nested = @($files | Where-Object { $_.Extension -eq '.zip' })

                if ($nested.Count -gt 0) {
                    $warnings.Add("Nested ZIP(s) not opened: $(($nested | ForEach-Object { $_.FullName.Substring($extract.Length + 1) }) -join ', ')")
                }

                if ($images.Count -gt 1) {
                    throw "ZIP holds $($images.Count) disk images. Only one is supported per collection: $(($images | ForEach-Object { $_.Name }) -join ', ')"
                }

                if ($images.Count -eq 1) {
                    $evtx = @($files | Where-Object { $_.Extension -eq '.evtx' })
                    if ($evtx.Count -gt 0) {
                        $warnings.Add("Skipped evidence: $($evtx.Count) loose evtx file(s) beside the disk image were not processed.")
                    }
                    $mount = Mount-CollectionImage -ImagePath $images[0].FullName -MountRoot $mountRoot -DiffRoot $diffRoot -Collection $Collection.Collection -Teardown $teardown
                    $result.ImagePath = $images[0].FullName
                    $result.ChildPath = $mount.ChildPath
                    $result.MountPath = $mount.MountPath
                    $result.Path = $mount.Path
                }
                else {
                    $result.Path = $extract
                }
            }
        }
    }
    catch {
        $original = $_
        try {
            Invoke-CollectionCleanup -Resolved $result
        }
        catch {
            Write-Warning $_.Exception.Message
        }
        throw $original
    }

    return $result
}
