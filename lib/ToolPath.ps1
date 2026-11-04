# Where the tools the run executes, and the rules Hayabusa loads, really
# live. A path given for Hayabusa, RECmd or the rules is followed through
# every link to its final target, and the run refuses one that ends up
# inside the evidence or the output, or on a network share, since anything
# there could have been put in place by someone else and would run with the
# analyst's rights.

# On Windows the final path comes from an open handle, which accounts for
# junctions, symbolic links, subst drives and mapped drives in one call.
$script:FinalPathSource = @'
namespace HayabusaBulkRunner
{
    using System;
    using System.ComponentModel;
    using System.Runtime.InteropServices;
    using System.Text;
    using Microsoft.Win32.SafeHandles;

    public static class FinalPathNative
    {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint GetFinalPathNameByHandleW(SafeFileHandle handle, StringBuilder path, uint length, uint flags);

        // No access rights are asked for, only the name, and every kind of
        // sharing is allowed, so nothing else using the file is disturbed.
        // Backup semantics is what lets a folder be opened at all.
        public static string Get(string path)
        {
            using (SafeFileHandle handle = CreateFileW(path, 0, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero))
            {
                if (handle.IsInvalid)
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
                StringBuilder buffer = new StringBuilder(1024);
                uint length = GetFinalPathNameByHandleW(handle, buffer, (uint)buffer.Capacity, 0);
                if (length > buffer.Capacity)
                {
                    buffer = new StringBuilder((int)length + 1);
                    length = GetFinalPathNameByHandleW(handle, buffer, (uint)buffer.Capacity, 0);
                }
                if (length == 0)
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
                return buffer.ToString();
            }
        }
    }
}
'@

# Links followed in one path before it's taken to loop.
$script:MaxLinkHops = 40

function Initialize-FinalPathType {
    [CmdletBinding()]
    param()

    if (-not ('HayabusaBulkRunner.FinalPathNative' -as [type])) {
        Add-Type -TypeDefinition $script:FinalPathSource -Language CSharp
    }
}

function ConvertFrom-FinalPathPrefix {
    # \\?\C:\x becomes C:\x and \\?\UNC\server\share becomes \\server\share.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if ($Path.StartsWith('\\?\UNC\', [System.StringComparison]::OrdinalIgnoreCase)) {
        return '\\' + $Path.Substring(8)
    }
    if ($Path.StartsWith('\\?\') -and $Path.Length -ge 6 -and $Path[5] -eq ':') {
        return $Path.Substring(4)
    }
    return $Path
}

function Get-PathLinkTarget {
    # Where a link points, as a full path, or null when Path isn't a link.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-PathIsLink -Path $Path)) {
        return $null
    }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    $target = $null
    if ($null -ne $item.PSObject.Properties['LinkTarget']) {
        $target = $item.LinkTarget
    }
    if ([string]::IsNullOrEmpty($target) -and $null -ne $item.PSObject.Properties['Target']) {
        $target = @($item.Target | Where-Object { -not [string]::IsNullOrEmpty($_) } | Select-Object -First 1)
        if ($target.Count -eq 0) {
            $target = $null
        }
        else {
            $target = [string]$target[0]
        }
    }
    if ([string]::IsNullOrEmpty($target)) {
        # A reparse point that isn't a link, such as a cloud placeholder,
        # names no target and is taken as it is.
        return $null
    }
    if (-not [System.IO.Path]::IsPathRooted($target)) {
        $target = Join-Path -Path (Split-Path -Path $Path -Parent) -ChildPath $target
    }
    return [System.IO.Path]::GetFullPath((ConvertFrom-FinalPathPrefix -Path $target))
}

function Resolve-FinalPathByWalk {
    <#
    .SYNOPSIS
        Follows every link in a path, one component at a time.
    .DESCRIPTION
        Used where no handle can give the final path, such as off Windows
        or for a path that doesn't exist yet. A link's target is itself
        walked again from the start, and more than MaxLinkHops links in
        one path is taken as a loop and refused. The part of the path that
        doesn't exist is kept as given.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [int]$Hops = 0
    )

    if ($Hops -gt $script:MaxLinkHops) {
        throw "$Path goes through more than $script:MaxLinkHops links, so it may loop."
    }
    $full = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($full)
    $segments = @($full.Substring($root.Length).Split([char[]]@('\', '/'), [System.StringSplitOptions]::RemoveEmptyEntries))
    $current = $root
    for ($i = 0; $i -lt $segments.Count; $i++) {
        $candidate = Join-Path -Path $current -ChildPath $segments[$i]
        if (-not (Test-Path -LiteralPath $candidate)) {
            # Nothing further down exists, so nothing further down is a link.
            $rest = @($segments | Select-Object -Skip $i)
            return [System.IO.Path]::GetFullPath((Join-Path -Path $current -ChildPath ($rest -join [System.IO.Path]::DirectorySeparatorChar)))
        }
        $target = Get-PathLinkTarget -Path $candidate
        if ($null -ne $target) {
            $rest = @($segments | Select-Object -Skip ($i + 1))
            $next = $target
            if ($rest.Count -gt 0) {
                $next = Join-Path -Path $target -ChildPath ($rest -join [System.IO.Path]::DirectorySeparatorChar)
            }
            return (Resolve-FinalPathByWalk -Path $next -Hops ($Hops + 1))
        }
        $current = $candidate
    }
    return $current
}

function Resolve-FinalPath {
    <#
    .SYNOPSIS
        A path's final target, with every link along it followed.
    .DESCRIPTION
        On Windows the final path of an open handle, which also sees
        through subst and mapped drives. Where that can't be had, for a
        path that doesn't exist or off Windows, each component is followed
        in turn. A path that doesn't exist resolves as far as it does
        exist, and the rest is kept as given.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $full = [System.IO.Path]::GetFullPath($Path)
    if ((Test-IsWindowsHost) -and (Test-Path -LiteralPath $full)) {
        Initialize-FinalPathType
        try {
            return (ConvertFrom-FinalPathPrefix -Path ([HayabusaBulkRunner.FinalPathNative]::Get($full)))
        }
        catch {
            Write-Verbose "No final path from a handle for ${full}: $($_.Exception.Message). Following its links one at a time."
        }
    }
    return (Resolve-FinalPathByWalk -Path $full)
}

function Test-PathOnNetworkShare {
    <#
    .SYNOPSIS
        True when a path is on a network share.
    .DESCRIPTION
        A UNC path, a \\?\UNC\ path or a path on a mapped network drive.
        Give it the path as written and its final path both, since a link
        or a mapped drive can lead from a local-looking path to a share.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $p = $Path
    if ($p.StartsWith('\\?\UNC\', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    if ($p.StartsWith('\\?\') -or $p.StartsWith('\\.\')) {
        $p = $p.Substring(4)
    }
    elseif ($p.StartsWith('\\') -or $p.StartsWith('//')) {
        return $true
    }
    if ($p -match '^[A-Za-z]:') {
        try {
            $drive = New-Object System.IO.DriveInfo($p.Substring(0, 1))
            if ($drive.DriveType -eq [System.IO.DriveType]::Network) {
                return $true
            }
        }
        catch {
            Write-Verbose "Could not tell what kind of drive $($p.Substring(0, 2)) is: $($_.Exception.Message)"
        }
    }
    return $false
}

function Assert-ToolPathAllowed {
    <#
    .SYNOPSIS
        Refuses a tool or rules path inside InputRoot or OutputRoot, or on a
        network share, judged by where it really leads.
    .DESCRIPTION
        Both the path as given and its final target are checked, against
        InputRoot and OutputRoot as given and as resolved, so a link,
        junction, subst or mapped drive can't carry it past. Name is the
        setting's name for the message, and Use says what the run would do
        with it.
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
    $share = "so the tool won't $verb. Copy it to a local drive and point $Name there."
    if (Test-PathOnNetworkShare -Path $Path) {
        throw "$Name $Path is on a network share, $share"
    }
    $final = Resolve-FinalPath -Path $Path
    $via = ''
    if (-not $final.Equals($Path.TrimEnd('\', '/'), [System.StringComparison]::OrdinalIgnoreCase)) {
        $via = ", through a link to $final"
    }
    if (Test-PathOnNetworkShare -Path $final) {
        throw "$Name $Path is on a network share$via, $share"
    }
    foreach ($pair in @(@('InputRoot', $InputRoot), @('OutputRoot', $OutputRoot))) {
        $rootFinal = Resolve-FinalPath -Path $pair[1]
        foreach ($candidate in @($Path, $final)) {
            if ((Test-PathIsWithin -Path $candidate -Parent $pair[1]) -or (Test-PathIsWithin -Path $candidate -Parent $rootFinal)) {
                throw "$Name $Path is inside $($pair[0])$via, so the tool won't $verb. Keep the tools and rules outside the evidence and the output."
            }
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
