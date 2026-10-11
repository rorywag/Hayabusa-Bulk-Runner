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
