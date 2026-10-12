# Paths this long or longer get the \\?\ prefix on Windows. Windows file
# APIs stop at 260 characters for a file and 248 for a folder unless long
# paths are turned on for the whole machine.
$script:ExtendedPathThreshold = 240

function ConvertTo-NormalizedPath {
    <#
    .SYNOPSIS
        Resolves a path to its full form and strips any trailing separator.
    .DESCRIPTION
        Resolves against the current PowerShell location, not the process
        working directory, and works for paths that do not exist yet.
        A trailing backslash is removed because a quoted argument ending in \"
        is mangled by Windows argument parsing. Drive roots keep their
        separator, since "C:" on its own means the current directory on C.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $full = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($Path)
    $trimmed = $full.TrimEnd('\', '/')

    if ($trimmed -match '^[A-Za-z]:$') {
        return $trimmed + '\'
    }
    if ($trimmed.Length -eq 0) {
        return $full
    }
    return $trimmed
}

function Test-PathIsWithin {
    <#
    .SYNOPSIS
        Returns true if Path is the same as, or nested under, Parent.
    .DESCRIPTION
        Both paths should already be normalised. Comparison is case-insensitive
        to match Windows file system behaviour.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Parent
    )

    $comparison = [System.StringComparison]::OrdinalIgnoreCase
    $p = $Path.TrimEnd('\', '/')
    $root = $Parent.TrimEnd('\', '/')

    if ($p.Equals($root, $comparison)) {
        return $true
    }
    return ($p.StartsWith($root + '\', $comparison) -or $p.StartsWith($root + '/', $comparison))
}

function Get-CollectionOutputPath {
    # Per-host output folder and file names under OutputRoot\<Collection>.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$OutputRoot,

        [Parameter(Mandatory)]
        [string]$Collection
    )

    $dir = Join-Path -Path $OutputRoot -ChildPath $Collection
    [pscustomobject]@{
        Directory = $dir
        Csv       = Join-Path -Path $dir -ChildPath "$($Collection)_timeline.csv"
        Html      = Join-Path -Path $dir -ChildPath "$($Collection)_report.html"
        Log       = Join-Path -Path $dir -ChildPath "$($Collection)_hayabusa.log"
    }
}

function Write-TextFileAtomic {
    <#
    .SYNOPSIS
        Writes a text file through a temporary file swapped into place.
    .DESCRIPTION
        A crash mid-write leaves the previous file intact. UTF-8, with a
        byte order mark only when -Bom is given.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text,

        [switch]$Bom
    )

    if (-not $PSCmdlet.ShouldProcess($Path, 'Write file')) {
        return
    }
    if (Test-Path -LiteralPath $Path -PathType Container) {
        throw "Cannot write $Path because a folder of that name is in the way."
    }

    $encoding = New-Object System.Text.UTF8Encoding($Bom.IsPresent)
    $temp = $Path + '.tmp'
    [System.IO.File]::WriteAllText($temp, $Text, $encoding)

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        try {
            [System.IO.File]::Replace($temp, $Path, $null)
        }
        catch {
            # File.Replace is not supported on every file system, for
            # example some network shares. Fall back to a plain move.
            Move-Item -LiteralPath $temp -Destination $Path -Force
        }
    }
    else {
        Move-Item -LiteralPath $temp -Destination $Path -Force
    }
}

function Get-ExtendedLengthPath {
    <#
    .SYNOPSIS
        Adds the \\?\ extended-length prefix on Windows when a path needs it.
    .DESCRIPTION
        With the prefix, Windows file APIs accept paths up to about 32,000
        characters whatever the machine's long path setting. A path shorter
        than the threshold, one already prefixed, and any path on another
        platform come back unchanged, unless -Always is given. The path must
        already be full and normalised, because the prefix also turns off
        Windows' own path normalisation.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [switch]$Always
    )

    if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
        return $Path
    }
    if ($Path.StartsWith('\\?\') -or $Path.StartsWith('\\.\')) {
        return $Path
    }
    if (-not $Always -and $Path.Length -lt $script:ExtendedPathThreshold) {
        return $Path
    }
    if ($Path.StartsWith('\\')) {
        return '\\?\UNC\' + $Path.Substring(2)
    }
    return '\\?\' + $Path
}

function ConvertFrom-ExtendedLengthPath {
    # Strips the prefix again, for paths shown to people or passed on.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if ($Path.StartsWith('\\?\UNC\')) {
        return '\\' + $Path.Substring(8)
    }
    if ($Path.StartsWith('\\?\')) {
        return $Path.Substring(4)
    }
    return $Path
}

function Remove-DirectoryTree {
    <#
    .SYNOPSIS
        Deletes a folder and everything in it, including paths past 260
        characters.
    .DESCRIPTION
        Deletes through the prefixed path on Windows, so a deep tree such as
        an extracted KAPE ZIP can be removed. Falls back to the plain path
        if this runtime refuses the prefix. Directory.Delete removes links
        rather than following them. Callers check the folder's bounds and
        ShouldProcess first.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Callers check ShouldProcess and the folder bounds first.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $long = Get-ExtendedLengthPath -Path $Path -Always
    if ($long -ne $Path) {
        try {
            [System.IO.Directory]::Delete($long, $true)
            return
        }
        catch [System.ArgumentException], [System.NotSupportedException] {
            Write-Verbose "This runtime refused the extended-length path for $Path. Deleting with the plain path."
        }
    }
    [System.IO.Directory]::Delete($Path, $true)
}

function Get-FileTree {
    <#
    .SYNOPSIS
        Lists every file under a folder, at any depth, including paths past
        260 characters.
    .DESCRIPTION
        Returns FullName, Name and Extension for each file, hidden and
        system files included, with FullName given without the prefix.
        Falls back to the plain path if this runtime refuses the prefix.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $all = [System.IO.SearchOption]::AllDirectories
    $files = $null
    $long = Get-ExtendedLengthPath -Path $Path -Always
    if ($long -ne $Path) {
        try {
            $files = [System.IO.Directory]::GetFiles($long, '*', $all)
        }
        catch [System.ArgumentException], [System.NotSupportedException] {
            Write-Verbose "This runtime refused the extended-length path for $Path. Listing with the plain path."
        }
    }
    if ($null -eq $files) {
        $files = [System.IO.Directory]::GetFiles($Path, '*', $all)
    }

    foreach ($f in $files) {
        $plain = ConvertFrom-ExtendedLengthPath -Path $f
        [pscustomobject]@{
            FullName  = $plain
            Name      = [System.IO.Path]::GetFileName($plain)
            Extension = [System.IO.Path]::GetExtension($plain)
        }
    }
}
