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

function Get-DiskImageContainer {
    <#
    .SYNOPSIS
        Lists VHDX and VHD files at the top level of InputRoot.
    .DESCRIPTION
        Only the top level is checked, the same depth host discovery uses.
        Nothing is opened or mounted.
    #>
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo])]
    param(
        [Parameter(Mandatory)]
        [string]$InputRoot
    )

    Get-ChildItem -LiteralPath $InputRoot -File -Force |
        Where-Object { $_.Extension -eq '.vhdx' -or $_.Extension -eq '.vhd' }
}

function Assert-ElevationForContainer {
    <#
    .SYNOPSIS
        Fails fast if InputRoot holds disk images and the session is not elevated.
    .DESCRIPTION
        Mount-DiskImage needs an elevated session. Checking at startup stops a
        long run from failing partway through on the first VHDX. ZIP and loose
        folders do not need elevation, so runs without disk images pass
        regardless.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$InputRoot
    )

    $images = @(Get-DiskImageContainer -InputRoot $InputRoot)
    if ($images.Count -eq 0) {
        Write-Verbose 'No VHDX or VHD containers found. Elevation not required.'
        return
    }

    $names = ($images | ForEach-Object { $_.Name }) -join ', '

    if (-not (Test-IsWindowsHost)) {
        throw "InputRoot contains disk images ($names). Mounting them requires Windows."
    }

    if (-not (Test-IsElevated)) {
        throw ("InputRoot contains {0} disk image(s) that must be mounted: {1}. " +
            'Mount-DiskImage requires an elevated session. Rerun from an ' +
            'Administrator PowerShell prompt.') -f $images.Count, $names
    }

    Write-Verbose "Session is elevated. $($images.Count) disk image(s) can be mounted."
}
