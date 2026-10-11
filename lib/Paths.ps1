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
