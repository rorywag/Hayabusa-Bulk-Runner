# Where the tools the run executes, and the rules Hayabusa loads, may be.
# Hayabusa and RECmd run with the analyst's rights, so a tool or rules
# folder inside the evidence or the output, or on a share, is refused at
# startup, before anything is written. The check compares the paths as
# given, after normalising them.

function Test-PathIsUnc {
    # True for a UNC path, written as \\server\share, //server/share,
    # \\?\UNC\server\share or \\.\UNC\server\share.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $comparison = [System.StringComparison]::OrdinalIgnoreCase
    if ($Path.StartsWith('\\?\UNC\', $comparison) -or $Path.StartsWith('\\.\UNC\', $comparison)) {
        return $true
    }
    if ($Path.StartsWith('\\?\') -or $Path.StartsWith('\\.\')) {
        return $false
    }
    return ($Path.StartsWith('\\') -or $Path.StartsWith('//'))
}

function Assert-ToolPathAllowed {
    <#
    .SYNOPSIS
        Refuses a tool or rules path inside InputRoot or OutputRoot, or on
        a network share.
    .DESCRIPTION
        Name is the setting's name for the message, and Use says what the
        run would do with it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$InputRoot,

        [Parameter(Mandatory)]
        [string]$OutputRoot,

        [ValidateSet('Run', 'Load')]
        [string]$Use = 'Run'
    )

    $verb = 'run it'
    if ($Use -eq 'Load') {
        $verb = 'load rules from it'
    }
    if (Test-PathIsUnc -Path $Path) {
        throw "$Name $Path is on a network share, so the tool won't $verb. Copy it to a local drive and point $Name there."
    }
    $normalized = ConvertTo-NormalizedPath -Path $Path
    foreach ($pair in @(@('InputRoot', $InputRoot), @('OutputRoot', $OutputRoot))) {
        if (Test-PathIsWithin -Path $normalized -Parent (ConvertTo-NormalizedPath -Path $pair[1])) {
            throw "$Name $Path is inside $($pair[0]), so the tool won't $verb. Keep the tools and rules outside the evidence and the output."
        }
    }
}

function Get-ToolFileSha256 {
    # The SHA-256 of a tool's executable for run-meta, or null if unread.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Path
    )

    if ([string]::IsNullOrEmpty($Path)) {
        return $null
    }
    try {
        return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
    }
    catch {
        Write-Verbose "Could not hash ${Path}: $($_.Exception.Message)"
        return $null
    }
}
