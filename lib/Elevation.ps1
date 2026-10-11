function Test-IsWindowsHost {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    # $IsWindows does not exist in Windows PowerShell 5.1.
    return ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
}

function Test-IsElevated {
    <#
    .SYNOPSIS
        Returns true if the current session is running as Administrator.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if (-not (Test-IsWindowsHost)) {
        throw 'Elevation can only be checked on Windows.'
    }

    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-CollectionNeedingMount {
    <#
    .SYNOPSIS
        Returns the discovered collections that will need a disk image mounted.
    .DESCRIPTION
        That is every Vhd and Vhdx collection, plus every Zip whose entry
        list, read without extracting, holds a .vhd or .vhdx at any depth.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Collections
    )

    foreach ($c in $Collections) {
        if ($c.InputType -eq 'Vhd' -or $c.InputType -eq 'Vhdx') {
            [pscustomobject]@{ Collection = $c; Reason = $c.Source }
        }
        elseif ($c.InputType -eq 'Zip' -and $null -ne $c.Zip -and @($c.Zip.ImageEntries).Count -gt 0) {
            [pscustomobject]@{ Collection = $c; Reason = "$($c.Source) (contains $(@($c.Zip.ImageEntries) -join ', '))" }
        }
    }
}

function Assert-ElevationForContainer {
    <#
    .SYNOPSIS
        Fails fast if any collection needs a mount and the session is not elevated.
    .DESCRIPTION
        Mount-DiskImage and diskpart need an elevated session. Checking at startup, before
        anything is extracted or written, stops a long run failing partway
        through on the first disk image. That includes images nested inside
        a ZIP, found by listing the archive's entries. Loose folders and ZIPs
        without a disk image do not need elevation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Collections
    )

    $needing = @(Get-CollectionNeedingMount -Collections $Collections)
    if ($needing.Count -eq 0) {
        Write-Verbose 'No disk images to mount. Elevation not required.'
        return
    }

    $names = ($needing | ForEach-Object { $_.Reason }) -join '; '

    if (-not (Test-IsWindowsHost)) {
        throw "InputRoot holds disk images that must be mounted: $names. Mounting them requires Windows."
    }

    if (-not (Test-IsElevated)) {
        throw ("InputRoot holds {0} collection(s) with disk images that must be mounted: {1}. " +
            'Mount-DiskImage and diskpart require an elevated session. Rerun from an ' +
            'Administrator PowerShell prompt.') -f $needing.Count, $names
    }

    Write-Verbose "Session is elevated. $($needing.Count) collection(s) need a disk image mounted."
}
