# Host identity from a collection's registry hives: the computer name,
# domain, OS, time zone, local users and IP addressing, read from SYSTEM,
# SOFTWARE and SAM with RECmd and the batch file beside this one. Each host
# gets its own identity object, saved as JSON in its output folder. This
# is separate from how hosts are named in the manifest and the dashboard,
# which comes from the Computer column of Hayabusa's output.

# The RECmd release this tool's batch file and parser were checked against.
# When a new release passes the compatibility test in
# tests\HostIdentity.Tests.ps1, raise this and the values between the
# tested-recmd-version markers in docs/USAGE.md. This is the only place the
# tested version is set, and a test checks the docs markers match it.
$script:TestedRECmdVersion = '2026.5.0'

$script:HostIdentitySchemaVersion = 1

# Deep enough for every nested object in the identity file.
$script:HostIdentityJsonDepth = 10

$script:HostIdentityBatchPath = Join-Path -Path $PSScriptRoot -ChildPath 'HostIdentity.reb'

# The machine hives read, in the order they are run.
$script:IdentityHiveNames = @('SYSTEM', 'SOFTWARE', 'SAM')

# How many folders down from the collection root the Windows folder may
# be: the root itself, a KAPE drive letter folder such as C, a folder
# holding that, such as HOST01\C, or a Velociraptor offline collection's
# data\uploads\auto\C%3A, four down, with a little to spare.
$script:HiveSearchDepth = 6

# RECmd reads a whole hive into memory. A real SOFTWARE hive is well under
# this, so a bigger file is not taken to be a hive.
$script:MaxHiveBytes = 2GB

# RECmd prints this at the start of every run, for example
# "RECmd version 2026.5.0".
$script:RECmdVersionPattern = 'RECmd version (\d+(?:\.\d+)+)'

# Printed when a hive is dirty and has no transaction logs beside it.
$script:RECmdNoLogPattern = 'no transaction logs were found|transaction logs were not found'

# The SAM columns kept for each user. Anything else the plugin writes,
# PasswordHint and ResetData among them, is never read into the object.
$script:UserFlagColumns = @(
    'AccountDisabled'
    'HomeDirectoryRequired'
    'PasswordNotRequired'
    'TempDuplicateAccount'
    'NormalUserAccount'
    'MnsLogonAccount'
    'InterdomainTrustAccount'
    'WorkstationTrustAccount'
    'ServerTrustAccount'
    'PasswordDoesNotExpire'
    'AutoLocked'
)

# The columns of RECmd's output this tool reads: the main CSV for each hive
# and the detail CSV of each plugin. The RECmd compatibility test checks a
# real RECmd still writes them.
$script:RECmdMainColumns = @('KeyPath', 'ValueName', 'ValueType', 'ValueData', 'Deleted')
$script:RECmdPluginColumns = [ordered]@{
    NetworkSettings = @('BatchKeyPath', 'IPAddress', 'SubnetMask', 'DHCPSubnetMask', 'DHCPServer', 'DHCPNameServer', 'DHCPIPAddress', 'DHCPDefaultGateway', 'LeaseObtainedTime', 'LeaseTerminatesTime', 'EnabledDHCP')
    DHCPNetworkHint = @('BatchKeyPath', 'NetworkHint', 'DHCPAddress', 'Interface', 'InterfaceSubkey')
    UserAccounts    = @('UserId', 'UserName', 'FullName', 'CreatedOn', 'LastLoginTime', 'LastPasswordChange', 'TotalLoginCount', 'InvalidLoginCount', 'Groups', 'Comment') + $script:UserFlagColumns
}

# Local accounts Windows or other software creates and manages, even with a
# RID of 1000 or more. WsiAccount is created by current Windows with a RID
# such as 1004 and the normal user account flag set. HelpAssistant is the
# Remote Assistance account on older hosts.
$script:SystemManagedUserPatterns = @(
    '^defaultuser\d+$'
    '^WDAGUtilityAccount$'
    '^WsiAccount$'
    '^HelpAssistant$'
    '^HomeGroupUser\$$'
    '^SUPPORT_388945a0$'
    '^__vmware_user__$'
    '^ASPNET$'
    '^IUSR_'
    '^IWAM_'
    '\$$'
)

$script:IdentityTimeFormat = 'yyyy-MM-ddTHH:mm:ssZ'

function Find-RegistryHive {
    <#
    .SYNOPSIS
        Finds SYSTEM, SOFTWARE and SAM under a collection root.
    .DESCRIPTION
        Looks for Windows\System32\config, in any case, at the root or up
        to six folders down. That covers the drive letter folder KAPE
        writes, such as C\Windows, and the deeper one a Velociraptor
        offline collection writes, data\uploads\auto\C%3A\Windows. Links
        are not followed. Each hive must
        start with the regf signature and be no bigger than a hive can be.
        Its .LOG, .LOG1 and .LOG2 files beside it are listed too. Nothing
        is written.

        Found is false when no config folder holds any of the three, as in
        a collection of event logs only. When more than one config folder
        holds hives, the one holding the most, nearest the root, is used
        and Notes names the others.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Root
    )

    $rootFull = ConvertTo-NormalizedPath -Path $Root
    $notes = New-Object System.Collections.Generic.List[string]
    $candidates = New-Object System.Collections.Generic.List[object]

    # Breadth first, one level at a time, stopping at the first level with
    # hives, so a folder of other drives beside it is still compared. A
    # Windows folder is never searched inside, since no other volume's
    # Windows folder sits in it.
    $level = @([System.IO.DirectoryInfo]$rootFull)
    for ($depth = 0; $depth -le $script:HiveSearchDepth -and $level.Count -gt 0; $depth++) {
        $next = New-Object System.Collections.Generic.List[object]
        foreach ($dir in $level) {
            foreach ($child in @(Get-IdentitySubdirectory -Directory $dir)) {
                if ($child.Name -ine 'Windows') {
                    $next.Add($child)
                    continue
                }
                foreach ($s in @(Get-IdentitySubdirectory -Directory $child | Where-Object { $_.Name -ieq 'System32' })) {
                    foreach ($c in @(Get-IdentitySubdirectory -Directory $s | Where-Object { $_.Name -ieq 'config' })) {
                        $candidates.Add((Get-HiveSet -ConfigDirectory $c -Depth $depth -Notes $notes))
                    }
                }
            }
        }
        if (@($candidates | Where-Object { $_.Count -gt 0 }).Count -gt 0) {
            break
        }
        $level = $next.ToArray()
    }

    $withHives = @($candidates | Where-Object { $_.Count -gt 0 } | Sort-Object -Property @{ Expression = 'Count'; Descending = $true }, @{ Expression = 'Depth'; Descending = $false }, @{ Expression = 'Path'; Descending = $false })

    $result = [pscustomobject]@{
        Found           = $false
        ConfigDirectory = $null
        Hives           = [ordered]@{}
        Logs            = [ordered]@{}
        Notes           = $notes
    }
    foreach ($name in $script:IdentityHiveNames) {
        $result.Hives[$name] = $null
        $result.Logs[$name] = @()
    }
    if ($withHives.Count -eq 0) {
        return $result
    }

    $chosen = $withHives[0]
    $result.Found = $true
    $result.ConfigDirectory = $chosen.Path
    foreach ($name in $script:IdentityHiveNames) {
        $result.Hives[$name] = $chosen.Hives[$name]
        $result.Logs[$name] = $chosen.Logs[$name]
    }
    if ($withHives.Count -gt 1) {
        $others = @($withHives | Select-Object -Skip 1 | ForEach-Object { Get-RelativeIdentityPath -Root $rootFull -Path $_.Path })
        $notes.Add(('More than one Windows\System32\config folder holds registry hives. Used {0}, not {1}.' -f (Get-RelativeIdentityPath -Root $rootFull -Path $chosen.Path), ($others -join ', ')))
    }
    return $result
}

function Get-IdentitySubdirectory {
    # Child folders of a folder, links left out. An unreadable folder has none.
    [CmdletBinding()]
    [OutputType([System.IO.DirectoryInfo])]
    param(
        [Parameter(Mandatory)]
        [System.IO.DirectoryInfo]$Directory
    )

    try {
        $children = $Directory.GetDirectories()
    }
    catch {
        Write-Verbose "Could not list $($Directory.FullName): $($_.Exception.Message)"
        return
    }
    foreach ($child in $children) {
        if (($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) {
            $child
        }
    }
}

function Get-HiveSet {
    # The hives and transaction logs in one config folder.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.IO.DirectoryInfo]$ConfigDirectory,

        [Parameter(Mandatory)]
        [int]$Depth,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]]$Notes
    )

    $files = @()
    try {
        $files = @($ConfigDirectory.GetFiles() | Where-Object { ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0 })
    }
    catch {
        $Notes.Add("Could not list $($ConfigDirectory.FullName): $($_.Exception.Message)")
    }

    $set = [pscustomobject]@{
        Path  = $ConfigDirectory.FullName
        Depth = $Depth
        Count = 0
        Hives = @{}
        Logs  = @{}
    }
    foreach ($name in $script:IdentityHiveNames) {
        $set.Hives[$name] = $null
        $set.Logs[$name] = @()
        $hive = @($files | Where-Object { $_.Name -ieq $name }) | Select-Object -First 1
        if ($null -eq $hive) {
            continue
        }
        $problem = Get-HiveFileProblem -File $hive
        if ($null -ne $problem) {
            $Notes.Add("Skipped $($hive.FullName): $problem")
            continue
        }
        $set.Hives[$name] = $hive.FullName
        $set.Logs[$name] = @($files | Where-Object { $_.Name -imatch ('^' + [regex]::Escape($name) + '\.LOG[12]?$') -and $_.Length -gt 0 } | Sort-Object -Property Name | ForEach-Object { $_.FullName })
        $set.Count++
    }
    return $set
}

function Get-HiveFileProblem {
    # Why a file is not taken to be a registry hive, or null.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.IO.FileInfo]$File
    )

    if ($File.Length -lt 4096) {
        return 'too small to be a registry hive.'
    }
    if ($File.Length -gt $script:MaxHiveBytes) {
        return 'too big to be a registry hive.'
    }
    $stream = $null
    try {
        $stream = [System.IO.File]::Open($File.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $magic = New-Object byte[] 4
        $read = $stream.Read($magic, 0, 4)
        if ($read -ne 4 -or [System.Text.Encoding]::ASCII.GetString($magic) -cne 'regf') {
            return 'not a registry hive, the regf signature is missing.'
        }
    }
    catch {
        return "could not be read: $($_.Exception.Message)"
    }
    finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }
    return $null
}

function Get-RelativeIdentityPath {
    # A path below Root, relative to it, for the identity file.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$Path
    )

    if ([string]::IsNullOrEmpty($Path)) {
        return $null
    }
    $r = $Root.TrimEnd('\', '/')
    if ($Path.Length -gt $r.Length -and $Path.StartsWith($r, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $Path.Substring($r.Length).TrimStart('\', '/')
    }
    return $Path
}

function Assert-RECmdPath {
    <#
    .SYNOPSIS
        Checks a configured RECmd path and returns it in full.
    .DESCRIPTION
        The path must be a full path to an existing file named RECmd.exe,
        outside the collection being read, so a file planted in the
        evidence is never run. A path holding a double quote is refused,
        since it could not be passed as one argument on Windows
        PowerShell 5.1.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Path,

        [string]$CollectionRoot
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'RECmdPath is empty. Set it to the full path of RECmd.exe.'
    }
    if ($Path.Contains('"')) {
        throw "RECmdPath contains a double quote: $Path"
    }
    if (-not [System.IO.Path]::IsPathRooted($Path)) {
        throw "RECmdPath must be a full path to RECmd.exe: $Path"
    }
    $full = ConvertTo-NormalizedPath -Path $Path
    if ([System.IO.Path]::GetFileName($full) -ine 'RECmd.exe') {
        throw "RECmdPath must point to RECmd.exe: $full"
    }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        throw "RECmd not found: $full. Download RECmd from Eric Zimmerman's tools and set RECmdPath to RECmd.exe."
    }
    if (-not [string]::IsNullOrEmpty($CollectionRoot)) {
        $collection = ConvertTo-NormalizedPath -Path $CollectionRoot
        if (Test-PathIsWithin -Path $full -Parent $collection) {
            throw "RECmdPath $full is inside the collection being read. Point it at a copy of RECmd.exe outside the evidence."
        }
    }
    return $full
}

function Resolve-RECmdPath {
    <#
    .SYNOPSIS
        The RECmd path from an engagement config, checked, or null.
    .DESCRIPTION
        Null when the config is missing or doesn't set RECmdPath, so host
        identity is not read. A relative path is taken relative to the
        config file, like RulesPath.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [pscustomobject]$Config
    )

    if ($null -eq $Config -or -not $Config.Values.ContainsKey('RECmdPath')) {
        return $null
    }
    $path = [string]$Config.Values['RECmdPath']
    if ([string]::IsNullOrWhiteSpace($path)) {
        throw "Config file $($Config.Path) sets RECmdPath to an empty value. Set it to the full path of RECmd.exe, or remove the line."
    }
    if (-not [System.IO.Path]::IsPathRooted($path)) {
        $path = Join-Path -Path $Config.Directory -ChildPath $path
    }
    return (Assert-RECmdPath -Path $path)
}

function New-RECmdArgument {
    <#
    .SYNOPSIS
        Builds the RECmd argument list for one hive.
    .DESCRIPTION
        Deleted keys and values are not recovered, so only the hive's live
        content is read. NoTransactionLogs lets RECmd read a dirty hive
        that has no transaction logs beside it, which it otherwise refuses.
        Each path is passed as its own argument, never through a shell.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory array only.')]
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [string]$HivePath,

        [Parameter(Mandatory)]
        [string]$BatchPath,

        [Parameter(Mandatory)]
        [string]$OutputDirectory,

        [Parameter(Mandatory)]
        [string]$CsvName,

        [switch]$NoTransactionLogs
    )

    $arguments = @('-f', $HivePath, '--bn', $BatchPath, '--csv', $OutputDirectory, '--csvf', $CsvName, '--recover', 'false')
    if ($NoTransactionLogs) {
        $arguments += '--nl'
    }
    Assert-NativeArgument -Argument $arguments
    return $arguments
}

function Assert-RECmdHost {
    [CmdletBinding()]
    param()

    if (-not (Test-IsWindowsHost)) {
        throw 'Running RECmd requires Windows.'
    }
}

function Invoke-RECmd {
    <#
    .SYNOPSIS
        Runs RECmd once and returns its exit code and output lines.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$RECmdPath,

        [Parameter(Mandatory)]
        [string[]]$Argument
    )

    Assert-RECmdHost
    $lines = New-Object System.Collections.Generic.List[string]
    $exit = Invoke-NativeCapture -FilePath $RECmdPath -Argument $Argument -OnLine {
        param($line)
        $lines.Add($line)
    }
    return [pscustomobject]@{
        ExitCode = $exit
        Output   = $lines.ToArray()
    }
}

function Get-RECmdVersionNumber {
    # The version RECmd printed at the start of a run, or null.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Output
    )

    foreach ($line in @($Output)) {
        $m = [regex]::Match([string]$line, $script:RECmdVersionPattern)
        if ($m.Success) {
            return $m.Groups[1].Value
        }
    }
    return $null
}

function ConvertTo-IdentityKeyPath {
    # A RECmd key path without its root key name, in lower case, for lookups.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$KeyPath
    )

    $p = ([string]$KeyPath).Trim().TrimEnd('\')
    $slash = $p.IndexOf('\')
    if ($slash -lt 0) {
        return ''
    }
    return $p.Substring($slash + 1).ToLowerInvariant()
}

function ConvertTo-IdentityText {
    # A trimmed string, or null when empty.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return $null
    }
    $s = ([string]$Value).Trim()
    if ($s.Length -eq 0) {
        return $null
    }
    return $s
}

function Get-RowValue {
    # One column of a CSV row, or null when the row has no such column.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [object]$Row,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($null -eq $Row) {
        return $null
    }
    $p = $Row.PSObject.Properties[$Name]
    if ($null -eq $p) {
        return $null
    }
    return [string]$p.Value
}

function ConvertTo-IdentityInt32 {
    <#
    .SYNOPSIS
        A REG_DWORD as RECmd writes it, unsigned decimal, as a signed
        32-bit number, or null.
    .DESCRIPTION
        A time zone bias of -600 is written as 4294966696.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [AllowNull()]
        [object]$Value
    )

    $text = ConvertTo-IdentityText -Value $Value
    if ($null -eq $text) {
        return $null
    }
    $n = [long]0
    if (-not [long]::TryParse($text, [System.Globalization.NumberStyles]::AllowLeadingSign, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$n)) {
        return $null
    }
    if ($n -gt [uint32]::MaxValue -or $n -lt [int]::MinValue) {
        return $null
    }
    if ($n -gt [int]::MaxValue) {
        $n -= 4294967296L
    }
    return [int]$n
}

function ConvertTo-IdentityBool {
    # True, false, or null for RECmd's True and False, or a DWORD of 1 or 0.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]
        [object]$Value
    )

    $text = ConvertTo-IdentityText -Value $Value
    if ($null -eq $text) {
        return $null
    }
    if ($text -ieq 'True' -or $text -eq '1') {
        return $true
    }
    if ($text -ieq 'False' -or $text -eq '0') {
        return $false
    }
    return $null
}

function ConvertTo-IdentityUtc {
    <#
    .SYNOPSIS
        A UTC time from RECmd output, as yyyy-MM-ddTHH:mm:ssZ, or null.
    .DESCRIPTION
        RECmd writes plugin times in UTC without a zone, as
        yyyy-MM-dd HH:mm:ss.fffffff. Unix seconds are taken as UTC too.
        Year 1601 and earlier means never set.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [object]$Value,

        [switch]$UnixSeconds
    )

    $text = ConvertTo-IdentityText -Value $Value
    if ($null -eq $text) {
        return $null
    }
    $invariant = [System.Globalization.CultureInfo]::InvariantCulture
    if ($UnixSeconds) {
        $seconds = [long]0
        if (-not [long]::TryParse($text, [System.Globalization.NumberStyles]::None, $invariant, [ref]$seconds) -or $seconds -le 0 -or $seconds -gt [uint32]::MaxValue) {
            return $null
        }
        return [System.DateTimeOffset]::FromUnixTimeSeconds($seconds).UtcDateTime.ToString($script:IdentityTimeFormat, $invariant)
    }
    $formats = [string[]]@('yyyy-MM-dd HH:mm:ss.fffffff', 'yyyy-MM-dd HH:mm:ss.FFFFFFF', 'yyyy-MM-dd HH:mm:ss', 'yyyy-MM-ddTHH:mm:ss.FFFFFFFZ', 'yyyy-MM-ddTHH:mm:ssZ')
    $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
    $parsed = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($text, $formats, $invariant, $styles, [ref]$parsed)) {
        return $null
    }
    if ($parsed.Year -le 1601) {
        return $null
    }
    return $parsed.ToString($script:IdentityTimeFormat, $invariant)
}

function ConvertTo-IdentityList {
    # A list of addresses or names split on commas and spaces, empties dropped.
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [AllowNull()]
        [object]$Value
    )

    $text = ConvertTo-IdentityText -Value $Value
    if ($null -eq $text) {
        return
    }
    $text -split '[,\s]+' | Where-Object { $_.Length -gt 0 }
}

function ConvertFrom-DhcpNetworkHint {
    <#
    .SYNOPSIS
        Decodes an interface's DhcpNetworkHint value into a network name.
    .DESCRIPTION
        Windows stores the name as hex with the two digits of each byte
        swapped. Decoded the same way RECmd's DHCPNetworkHint plugin does
        it: reverse the text, read it as hex bytes, decode them as code page
        1252, and reverse again. Null when the value is not that form.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Value
    )

    $text = ConvertTo-IdentityText -Value $Value
    if ($null -eq $text -or ($text.Length % 2) -ne 0 -or $text -notmatch '^[0-9A-Fa-f]+$') {
        return $null
    }
    $chars = $text.ToCharArray()
    [System.Array]::Reverse($chars)
    $reversed = -join $chars
    $bytes = New-Object byte[] ($reversed.Length / 2)
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        $bytes[$i] = [System.Convert]::ToByte($reversed.Substring($i * 2, 2), 16)
    }
    $decoded = ([System.Text.Encoding]::GetEncoding(1252).GetString($bytes)).ToCharArray()
    [System.Array]::Reverse($decoded)
    return (ConvertTo-IdentityText -Value (-join $decoded))
}

function Read-RECmdCsv {
    # Rows of one RECmd CSV, or none when the file is missing.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Path
    )

    if ([string]::IsNullOrEmpty($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return
    }
    Import-Csv -LiteralPath $Path -Encoding UTF8
}

function Find-RECmdDetailCsv {
    <#
    .SYNOPSIS
        The plugin detail CSVs for one hive and plugin under RECmd's output
        folder.
    .DESCRIPTION
        RECmd writes them to a folder named for the run's start time, as
        <hive>_<plugin>.csv. They are found by name under the output folder
        rather than through the PluginDetailFile column, which holds a path
        written by RECmd.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$OutputDirectory,

        [Parameter(Mandatory)]
        [string]$Hive,

        [Parameter(Mandatory)]
        [string]$Plugin
    )

    $name = "$($Hive)_$($Plugin).csv"
    foreach ($dir in @(Get-ChildItem -LiteralPath $OutputDirectory -Directory -ErrorAction SilentlyContinue | Sort-Object -Property Name)) {
        foreach ($f in @(Get-ChildItem -LiteralPath $dir.FullName -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ieq $name })) {
            $f.FullName
        }
    }
}

function Get-RECmdValueTable {
    <#
    .SYNOPSIS
        The raw values in RECmd's main CSV for one hive, by key and value.
    .DESCRIPTION
        Keys are the key path without the root key name, and value names,
        both in lower case. Plugin rows and deleted keys are left out. The
        first row for a key and value wins, so a repeated row changes
        nothing.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Row
    )

    $table = @{}
    foreach ($r in @($Row)) {
        if ($null -eq $r -or (Get-RowValue -Row $r -Name 'ValueType') -eq '(plugin)' -or (ConvertTo-IdentityBool -Value (Get-RowValue -Row $r -Name 'Deleted')) -eq $true) {
            continue
        }
        $key = ConvertTo-IdentityKeyPath -KeyPath (Get-RowValue -Row $r -Name 'KeyPath')
        if (-not $table.ContainsKey($key)) {
            $table[$key] = @{}
        }
        $name = ([string](Get-RowValue -Row $r -Name 'ValueName')).ToLowerInvariant()
        if ($name.Length -gt 0 -and -not $table[$key].ContainsKey($name)) {
            $table[$key][$name] = Get-RowValue -Row $r -Name 'ValueData'
        }
    }
    return $table
}

function Get-IdentityValue {
    # One raw value from a value table, or null.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Table,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Key,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $k = $Key.ToLowerInvariant()
    if (-not $Table.ContainsKey($k)) {
        return $null
    }
    $n = $Name.ToLowerInvariant()
    if (-not $Table[$k].ContainsKey($n)) {
        return $null
    }
    return (ConvertTo-IdentityText -Value $Table[$k][$n])
}

function Get-ActiveControlSet {
    <#
    .SYNOPSIS
        The active control set, such as ControlSet002, from Select\Current.
    .DESCRIPTION
        Falls back to the only control set in the output when Select has no
        Current value. Name is null when neither works.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$System
    )

    $current = ConvertTo-IdentityInt32 -Value (Get-IdentityValue -Table $System -Key 'select' -Name 'Current')
    if ($null -ne $current -and $current -ge 1 -and $current -le 999) {
        return [pscustomobject]@{ Name = ('ControlSet{0:D3}' -f $current); Source = 'Select\Current'; Note = $null }
    }
    $sets = @($System.Keys | ForEach-Object { if ($_ -match '^(controlset\d{3})(\\|$)') { $Matches[1] } } | Sort-Object -Unique)
    if ($sets.Count -eq 1) {
        $name = 'ControlSet' + $sets[0].Substring(10)
        return [pscustomobject]@{ Name = $name; Source = 'OnlyControlSet'; Note = "SYSTEM has no Select\Current value, so the only control set, $name, was used." }
    }
    return [pscustomobject]@{ Name = $null; Source = $null; Note = 'SYSTEM has no Select\Current value and more than one control set, so the active one is not known. The computer name, time zone, domain and interfaces were not read.' }
}

function Get-IdentityTimeZone {
    # The time zone from TimeZoneInformation, biases as signed minutes.
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$System,

        [Parameter(Mandatory)]
        [string]$ControlSet
    )

    $key = "$ControlSet\Control\TimeZoneInformation"
    $bias = ConvertTo-IdentityInt32 -Value (Get-IdentityValue -Table $System -Key $key -Name 'Bias')
    $active = ConvertTo-IdentityInt32 -Value (Get-IdentityValue -Table $System -Key $key -Name 'ActiveTimeBias')
    return [ordered]@{
        KeyName                    = Get-IdentityValue -Table $System -Key $key -Name 'TimeZoneKeyName'
        StandardName               = Get-IdentityValue -Table $System -Key $key -Name 'StandardName'
        DaylightName               = Get-IdentityValue -Table $System -Key $key -Name 'DaylightName'
        BiasMinutes                = $bias
        ActiveTimeBiasMinutes      = $active
        StandardUtcOffset          = ConvertTo-UtcOffsetText -BiasMinutes $bias
        ActiveUtcOffset            = ConvertTo-UtcOffsetText -BiasMinutes $active
        DynamicDaylightDisabled = ConvertTo-IdentityBool -Value (Get-IdentityValue -Table $System -Key $key -Name 'DynamicDaylightTimeDisabled')
    }
}

function ConvertTo-UtcOffsetText {
    # A Windows bias, minutes to add to local time for UTC, as +HH:mm.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [object]$BiasMinutes
    )

    if ($null -eq $BiasMinutes) {
        return $null
    }
    $offset = -[int]$BiasMinutes
    $sign = '+'
    if ($offset -lt 0) {
        $sign = '-'
        $offset = -$offset
    }
    return ('{0}{1:D2}:{2:D2}' -f $sign, [int][math]::Floor($offset / 60), ($offset % 60))
}

function Get-IdentityDomain {
    <#
    .SYNOPSIS
        Domain evidence from SYSTEM and SOFTWARE.
    .DESCRIPTION
        Membership is Domain when Winlogon's CachePrimaryDomain names a
        domain other than the computer itself. The name of a workgroup is
        kept in the SECURITY hive, which is not read, so a computer with no
        domain evidence is NoDomainEvidence, not a named workgroup.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$System,

        [Parameter(Mandatory)]
        [hashtable]$Software,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$ControlSet,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$ComputerName
    )

    $dns = $null
    $nv = $null
    if (-not [string]::IsNullOrEmpty($ControlSet)) {
        $tcpip = "$ControlSet\Services\Tcpip\Parameters"
        $dns = Get-IdentityValue -Table $System -Key $tcpip -Name 'Domain'
        $nv = Get-IdentityValue -Table $System -Key $tcpip -Name 'NV Domain'
    }
    $winlogon = 'Microsoft\Windows NT\CurrentVersion\Winlogon'
    $primary = Get-IdentityValue -Table $Software -Key $winlogon -Name 'CachePrimaryDomain'
    $membership = 'NoDomainEvidence'
    if ($null -ne $primary -and $primary -ine [string]$ComputerName) {
        $membership = 'Domain'
    }
    return [ordered]@{
        Membership         = $membership
        DnsDomain          = $dns
        NvDomain           = $nv
        CachePrimaryDomain = $primary
        DefaultDomainName  = Get-IdentityValue -Table $Software -Key $winlogon -Name 'DefaultDomainName'
    }
}

function Get-IdentityOperatingSystem {
    # The OS from SOFTWARE\Microsoft\Windows NT\CurrentVersion.
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Software
    )

    $key = 'Microsoft\Windows NT\CurrentVersion'
    $build = Get-IdentityValue -Table $Software -Key $key -Name 'CurrentBuild'
    if ($null -eq $build) {
        $build = Get-IdentityValue -Table $Software -Key $key -Name 'CurrentBuildNumber'
    }
    $version = Get-IdentityValue -Table $Software -Key $key -Name 'DisplayVersion'
    if ($null -eq $version) {
        $version = Get-IdentityValue -Table $Software -Key $key -Name 'ReleaseId'
    }
    return [ordered]@{
        ProductName            = Get-IdentityValue -Table $Software -Key $key -Name 'ProductName'
        EditionId              = Get-IdentityValue -Table $Software -Key $key -Name 'EditionID'
        Version                = $version
        Build                  = $build
        InstallDateUtc         = ConvertTo-IdentityUtc -Value (Get-IdentityValue -Table $Software -Key $key -Name 'InstallDate') -UnixSeconds
        RegisteredOwner        = Get-IdentityValue -Table $Software -Key $key -Name 'RegisteredOwner'
        RegisteredOrganization = Get-IdentityValue -Table $Software -Key $key -Name 'RegisteredOrganization'
    }
}

function Get-UserAccountType {
    <#
    .SYNOPSIS
        Interactive, BuiltIn or System for one SAM user, and why.
    .DESCRIPTION
        Interactive is a RID of 1000 or more on a normal user account that
        Windows or other software doesn't manage. BuiltIn is a RID under
        1000, such as Administrator and Guest. System is the rest: trust
        and logon accounts, and accounts such as defaultuser0.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [object]$Rid,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$UserName,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Flags
    )

    if ($null -eq $Rid) {
        return [pscustomobject]@{ Type = 'System'; Reason = 'No RID.' }
    }
    if ([int]$Rid -lt 1000) {
        return [pscustomobject]@{ Type = 'BuiltIn'; Reason = 'RID under 1000.' }
    }
    foreach ($flag in @('WorkstationTrustAccount', 'ServerTrustAccount', 'InterdomainTrustAccount', 'MnsLogonAccount', 'TempDuplicateAccount')) {
        if ($Flags[$flag] -eq $true) {
            return [pscustomobject]@{ Type = 'System'; Reason = "$flag is set." }
        }
    }
    if ($Flags['NormalUserAccount'] -ne $true) {
        return [pscustomobject]@{ Type = 'System'; Reason = 'NormalUserAccount is not set.' }
    }
    foreach ($pattern in $script:SystemManagedUserPatterns) {
        if ([string]$UserName -imatch $pattern) {
            return [pscustomobject]@{ Type = 'System'; Reason = 'An account Windows or other software manages.' }
        }
    }
    return [pscustomobject]@{ Type = 'Interactive'; Reason = 'RID 1000 or more on a normal user account.' }
}

function Get-IdentityUser {
    <#
    .SYNOPSIS
        Local users from the SAM UserAccounts plugin rows.
    .DESCRIPTION
        Only the columns listed here are read. PasswordHint and ResetData,
        which can hold a password hint and the answers to security
        questions, are never read. Users are de-duplicated by RID and
        ordered by it.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Row
    )

    $seen = @{}
    $users = New-Object System.Collections.Generic.List[object]
    foreach ($r in @($Row)) {
        if ($null -eq $r) {
            continue
        }
        $rid = ConvertTo-IdentityInt32 -Value (Get-RowValue -Row $r -Name 'UserId')
        $name = ConvertTo-IdentityText -Value (Get-RowValue -Row $r -Name 'UserName')
        $dedupe = if ($null -ne $rid) { "rid:$rid" } else { "name:$([string]$name)".ToLowerInvariant() }
        if ($seen.ContainsKey($dedupe)) {
            continue
        }
        $seen[$dedupe] = $true

        $flags = [ordered]@{}
        foreach ($f in $script:UserFlagColumns) {
            $flags[$f] = ConvertTo-IdentityBool -Value (Get-RowValue -Row $r -Name $f)
        }
        $type = Get-UserAccountType -Rid $rid -UserName $name -Flags $flags
        $groups = @()
        $groupText = ConvertTo-IdentityText -Value (Get-RowValue -Row $r -Name 'Groups')
        if ($null -ne $groupText) {
            $groups = @($groupText -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_.Length -gt 0 })
        }

        $users.Add([ordered]@{
                UserName              = $name
                FullName              = ConvertTo-IdentityText -Value (Get-RowValue -Row $r -Name 'FullName')
                Rid                   = $rid
                AccountType           = $type.Type
                AccountTypeReason     = $type.Reason
                CreatedUtc            = ConvertTo-IdentityUtc -Value (Get-RowValue -Row $r -Name 'CreatedOn')
                LastLoginUtc          = ConvertTo-IdentityUtc -Value (Get-RowValue -Row $r -Name 'LastLoginTime')
                LastPasswordChangeUtc = ConvertTo-IdentityUtc -Value (Get-RowValue -Row $r -Name 'LastPasswordChange')
                TotalLoginCount       = ConvertTo-IdentityInt32 -Value (Get-RowValue -Row $r -Name 'TotalLoginCount')
                InvalidLoginCount     = ConvertTo-IdentityInt32 -Value (Get-RowValue -Row $r -Name 'InvalidLoginCount')
                Groups                = [string[]]$groups
                Comment               = ConvertTo-IdentityText -Value (Get-RowValue -Row $r -Name 'Comment')
                Flags                 = $flags
            })
    }
    $users | Sort-Object -Property @{ Expression = { if ($null -eq $_.Rid) { [int]::MaxValue } else { $_.Rid } } }
}

function Get-InterfaceGuid {
    # The interface GUID from a key path directly under Interfaces, or null.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$KeyPath,

        [Parameter(Mandatory)]
        [string]$InterfacesKey
    )

    $prefix = $InterfacesKey.ToLowerInvariant() + '\'
    if (-not $KeyPath.StartsWith($prefix)) {
        return $null
    }
    $rest = $KeyPath.Substring($prefix.Length)
    if ($rest.Length -eq 0 -or $rest.Contains('\')) {
        return $null
    }
    return $rest
}

function Get-IdentityInterface {
    <#
    .SYNOPSIS
        Every network interface in the active control set, newest lease
        first.
    .DESCRIPTION
        Built from the NetworkSettings plugin rows and the raw values of
        each Interfaces subkey, de-duplicated by interface GUID. Address is
        the DHCP address on an interface with DHCP turned on, otherwise the
        first static address that isn't 0.0.0.0, and whichever is set when
        only one is. NameServer and DefaultGateway set on the interface win
        over the ones DHCP gave, as they do in Windows. NetworkName comes
        from the DHCP network hint for the interface's current lease.

        Interfaces with a lease come first, newest first, then those with
        an address, then the rest. LikelyActive marks the interface with an
        address and a network name with the newest lease, or the only one
        with an address and a network name. When no interface with an
        address has a network name, it marks the newest leased interface
        with an address, or the only interface with an address. Virtual
        interfaces, such as Hyper-V, WSL and VPN adapters, are all kept,
        and since they have no network name, one is only marked when no
        named interface has an address.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$System,

        [Parameter(Mandatory)]
        [string]$ControlSet,

        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$SettingRow,

        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$HintRow
    )

    $interfacesKey = "$ControlSet\Services\Tcpip\Parameters\Interfaces"

    $settings = @{}
    foreach ($r in @($SettingRow)) {
        if ($null -eq $r) {
            continue
        }
        $guid = Get-InterfaceGuid -KeyPath (ConvertTo-IdentityKeyPath -KeyPath (Get-RowValue -Row $r -Name 'BatchKeyPath')) -InterfacesKey $interfacesKey
        if ($null -ne $guid -and -not $settings.ContainsKey($guid)) {
            $settings[$guid] = $r
        }
    }

    $hints = @{}
    foreach ($r in @($HintRow)) {
        if ($null -eq $r) {
            continue
        }
        $path = ConvertTo-IdentityKeyPath -KeyPath (Get-RowValue -Row $r -Name 'BatchKeyPath')
        if (-not $path.StartsWith($interfacesKey.ToLowerInvariant() + '\')) {
            continue
        }
        $guid = ([string](Get-RowValue -Row $r -Name 'Interface')).ToLowerInvariant()
        if (-not $hints.ContainsKey($guid)) {
            $hints[$guid] = New-Object System.Collections.Generic.List[object]
        }
        $hints[$guid].Add($r)
    }

    $guids = New-Object System.Collections.Generic.List[string]
    foreach ($g in @($settings.Keys) + @($System.Keys | ForEach-Object { Get-InterfaceGuid -KeyPath $_ -InterfacesKey $interfacesKey })) {
        if ($null -ne $g -and -not $guids.Contains($g)) {
            $guids.Add($g)
        }
    }

    $list = New-Object System.Collections.Generic.List[object]
    foreach ($guid in $guids) {
        $key = "$interfacesKey\$guid"
        $field = @{ Setting = $settings[$guid]; Table = $System; Key = $key }

        $dhcpEnabled = ConvertTo-IdentityBool -Value (Get-InterfaceField @field -Raw 'EnableDHCP')
        if ($null -eq $dhcpEnabled) {
            $dhcpEnabled = ConvertTo-IdentityBool -Value (Get-InterfaceField @field -Column 'EnabledDHCP')
        }

        $static = @(ConvertTo-IdentityList -Value (Get-InterfaceField @field -Column 'IPAddress' -Raw 'IPAddress') | Where-Object { $_ -ne '0.0.0.0' })
        $dhcpAddress = Get-InterfaceField @field -Column 'DHCPIPAddress' -Raw 'DhcpIPAddress'
        if ($dhcpAddress -eq '0.0.0.0') {
            $dhcpAddress = $null
        }

        $source = $null
        if ($dhcpEnabled -eq $true -and $null -ne $dhcpAddress) {
            $source = 'DHCP'
        }
        elseif ($static.Count -gt 0) {
            $source = 'Static'
        }
        elseif ($null -ne $dhcpAddress) {
            $source = 'DHCP'
        }
        $address = $null
        $mask = $null
        if ($source -eq 'DHCP') {
            $address = $dhcpAddress
            $mask = Get-InterfaceField @field -Column 'DHCPSubnetMask' -Raw 'DhcpSubnetMask'
        }
        elseif ($source -eq 'Static') {
            $address = $static[0]
            $mask = @(ConvertTo-IdentityList -Value (Get-InterfaceField @field -Column 'SubnetMask' -Raw 'SubnetMask')) | Select-Object -First 1
        }

        $gateway = @(ConvertTo-IdentityList -Value (Get-InterfaceField @field -Raw 'DefaultGateway'))
        if ($gateway.Count -eq 0) {
            $gateway = @(ConvertTo-IdentityList -Value (Get-InterfaceField @field -Column 'DHCPDefaultGateway' -Raw 'DhcpDefaultGateway'))
        }
        $nameServer = @(ConvertTo-IdentityList -Value (Get-InterfaceField @field -Raw 'NameServer'))
        if ($nameServer.Count -eq 0) {
            $nameServer = @(ConvertTo-IdentityList -Value (Get-InterfaceField @field -Column 'DHCPNameServer' -Raw 'DhcpNameServer'))
        }

        $obtained = ConvertTo-IdentityUtc -Value (Get-InterfaceField @field -Column 'LeaseObtainedTime')
        if ($null -eq $obtained) {
            $obtained = ConvertTo-IdentityUtc -Value (Get-InterfaceField @field -Raw 'LeaseObtainedTime') -UnixSeconds
        }
        $terminates = ConvertTo-IdentityUtc -Value (Get-InterfaceField @field -Column 'LeaseTerminatesTime')
        if ($null -eq $terminates) {
            $terminates = ConvertTo-IdentityUtc -Value (Get-InterfaceField @field -Raw 'LeaseTerminatesTime') -UnixSeconds
        }

        $networkName = Get-InterfaceNetworkName -Guid $guid -Address $address -Hint $hints[$guid] -RawHint (Get-InterfaceField @field -Raw 'DhcpNetworkHint')

        $list.Add([ordered]@{
                Guid               = $guid.ToUpperInvariant()
                Address            = $address
                AddressSource      = $source
                StaticAddresses    = [string[]]$static
                SubnetMask         = $mask
                DefaultGateway     = [string[]]$gateway
                NameServer         = [string[]]$nameServer
                DhcpEnabled        = $dhcpEnabled
                DhcpServer         = Get-InterfaceField @field -Column 'DHCPServer' -Raw 'DhcpServer'
                DhcpDomain         = Get-InterfaceField @field -Raw 'DhcpDomain'
                NetworkName        = $networkName
                LeaseObtainedUtc   = $obtained
                LeaseTerminatesUtc = $terminates
                LikelyActive       = $false
            })
    }

    $ordered = @($list | Sort-Object -Property @(
            @{ Expression = { if ($null -ne $_.LeaseObtainedUtc) { 0 } elseif ($null -ne $_.Address) { 1 } else { 2 } } }
            @{ Expression = { [string]$_.LeaseObtainedUtc }; Descending = $true }
            @{ Expression = { $_.Guid } }
        ))

    # A network name marks a real connection. Hyper-V, WSL and other
    # virtual adapters have none, however new their lease, so a named one
    # is preferred. The list stays in lease order either way.
    $addressed = @($ordered | Where-Object { $null -ne $_.Address })
    $named = @($addressed | Where-Object { $null -ne $_.NetworkName })
    $active = $null
    $namedLeased = @($named | Where-Object { $null -ne $_.LeaseObtainedUtc })
    if ($namedLeased.Count -gt 0) {
        $active = $namedLeased[0]
    }
    elseif ($named.Count -eq 1) {
        $active = $named[0]
    }
    if ($null -eq $active) {
        $active = @($addressed | Where-Object { $null -ne $_.LeaseObtainedUtc }) | Select-Object -First 1
    }
    if ($null -eq $active -and $addressed.Count -eq 1) {
        $active = $addressed[0]
    }
    if ($null -ne $active) {
        $active.LikelyActive = $true
    }
    foreach ($i in $ordered) {
        $i
    }
}

function Get-InterfaceField {
    <#
    .SYNOPSIS
        One field of an interface: the NetworkSettings plugin column when
        it is set, otherwise the raw value of the interface's key.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [object]$Setting,

        [Parameter(Mandatory)]
        [hashtable]$Table,

        [Parameter(Mandatory)]
        [string]$Key,

        [string]$Column,

        [string]$Raw
    )

    if (-not [string]::IsNullOrEmpty($Column)) {
        $v = ConvertTo-IdentityText -Value (Get-RowValue -Row $Setting -Name $Column)
        if ($null -ne $v) {
            return $v
        }
    }
    if (-not [string]::IsNullOrEmpty($Raw)) {
        return (Get-IdentityValue -Table $Table -Key $Key -Name $Raw)
    }
    return $null
}

function Get-InterfaceNetworkName {
    <#
    .SYNOPSIS
        The network name for an interface's current address, or null.
    .DESCRIPTION
        Taken from the DHCPNetworkHint row for the interface key itself,
        then the interface's own DhcpNetworkHint value, then a row for one
        of its network subkeys whose DHCP address is the interface's
        address. Used only to label which address belongs to which network.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Guid,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$Address,

        [AllowNull()]
        [object]$Hint,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$RawHint
    )

    $rows = @($Hint | Where-Object { $null -ne $_ })
    $own = @($rows | Where-Object { (Get-RowValue -Row $_ -Name 'InterfaceSubkey') -ieq $Guid }) | Select-Object -First 1
    if ($null -ne $own) {
        $name = ConvertTo-IdentityText -Value (Get-RowValue -Row $own -Name 'NetworkHint')
        if ($null -ne $name) {
            return $name
        }
    }
    $decoded = ConvertFrom-DhcpNetworkHint -Value $RawHint
    if ($null -ne $decoded) {
        return $decoded
    }
    if (-not [string]::IsNullOrEmpty($Address)) {
        $match = @($rows | Where-Object { (ConvertTo-IdentityText -Value (Get-RowValue -Row $_ -Name 'DHCPAddress')) -eq $Address -and $null -ne (ConvertTo-IdentityText -Value (Get-RowValue -Row $_ -Name 'NetworkHint')) }) | Select-Object -First 1
        if ($null -ne $match) {
            return (ConvertTo-IdentityText -Value (Get-RowValue -Row $match -Name 'NetworkHint'))
        }
    }
    return $null
}

function ConvertFrom-RECmdOutput {
    <#
    .SYNOPSIS
        Parses RECmd's output for SYSTEM, SOFTWARE and SAM into the parts
        of a host identity.
    .DESCRIPTION
        OutputDirectory holds SYSTEM.csv, SOFTWARE.csv and SAM.csv from
        this tool's batch file and RECmd's folder of plugin detail CSVs.
        A missing file leaves its parts empty. Every time is UTC, as
        yyyy-MM-ddTHH:mm:ssZ, in a field whose name ends in Utc.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [string]$OutputDirectory
    )

    $notes = New-Object System.Collections.Generic.List[string]
    $system = Get-RECmdValueTable -Row @(Read-RECmdCsv -Path (Join-Path -Path $OutputDirectory -ChildPath 'SYSTEM.csv'))
    $software = Get-RECmdValueTable -Row @(Read-RECmdCsv -Path (Join-Path -Path $OutputDirectory -ChildPath 'SOFTWARE.csv'))

    $controlSet = $null
    $hostname = $null
    $timeZone = $null
    $interfaces = @()
    if ($system.Count -gt 0) {
        $cs = Get-ActiveControlSet -System $system
        $controlSet = $cs.Name
        if ($null -ne $cs.Note) {
            $notes.Add($cs.Note)
        }
        if ($null -ne $controlSet) {
            $hostname = Get-IdentityValue -Table $system -Key "$controlSet\Control\ComputerName\ComputerName" -Name 'ComputerName'
            $timeZone = Get-IdentityTimeZone -System $system -ControlSet $controlSet
            $settingRows = @(Find-RECmdDetailCsv -OutputDirectory $OutputDirectory -Hive 'SYSTEM' -Plugin 'NetworkSettings' | ForEach-Object { Read-RECmdCsv -Path $_ })
            $hintRows = @(Find-RECmdDetailCsv -OutputDirectory $OutputDirectory -Hive 'SYSTEM' -Plugin 'DHCPNetworkHint' | ForEach-Object { Read-RECmdCsv -Path $_ })
            $interfaces = @(Get-IdentityInterface -System $system -ControlSet $controlSet -SettingRow $settingRows -HintRow $hintRows)
        }
    }

    $domain = $null
    if ($system.Count -gt 0 -or $software.Count -gt 0) {
        $domain = Get-IdentityDomain -System $system -Software $software -ControlSet $controlSet -ComputerName $hostname
    }

    $os = $null
    if ($software.Count -gt 0) {
        $os = Get-IdentityOperatingSystem -Software $software
        $buildNumber = 0
        if ([int]::TryParse([string]$os.Build, [ref]$buildNumber) -and $buildNumber -ge 22000 -and [string]$os.ProductName -like 'Windows 10*') {
            $notes.Add("ProductName says $($os.ProductName), but build $buildNumber is Windows 11. Windows 11 keeps the Windows 10 product name in the registry.")
        }
    }

    $users = @(Get-IdentityUser -Row @(Find-RECmdDetailCsv -OutputDirectory $OutputDirectory -Hive 'SAM' -Plugin 'UserAccounts' | ForEach-Object { Read-RECmdCsv -Path $_ }))

    return [ordered]@{
        ControlSet = $controlSet
        Hostname   = $hostname
        Domain     = $domain
        Os         = $os
        TimeZone   = $timeZone
        Users      = $users
        Interfaces = $interfaces
        Notes      = $notes.ToArray()
    }
}

function Invoke-RECmdHive {
    <#
    .SYNOPSIS
        Runs RECmd against one copied hive, retrying without transaction
        logs when the hive is dirty and has none.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$RECmdPath,

        [Parameter(Mandatory)]
        [string]$HivePath,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$OutputDirectory
    )

    $csv = Join-Path -Path $OutputDirectory -ChildPath "$Name.csv"
    $arguments = New-RECmdArgument -HivePath $HivePath -BatchPath $script:HostIdentityBatchPath -OutputDirectory $OutputDirectory -CsvName "$Name.csv"
    $run = Invoke-RECmd -RECmdPath $RECmdPath -Argument $arguments
    $output = @($run.Output)
    $noLogs = $false
    if (-not (Test-Path -LiteralPath $csv -PathType Leaf) -and (@($output | Where-Object { $_ -match $script:RECmdNoLogPattern }).Count -gt 0)) {
        $noLogs = $true
        $arguments = New-RECmdArgument -HivePath $HivePath -BatchPath $script:HostIdentityBatchPath -OutputDirectory $OutputDirectory -CsvName "$Name.csv" -NoTransactionLogs
        $run = Invoke-RECmd -RECmdPath $RECmdPath -Argument $arguments
        $output += @($run.Output)
    }
    return [pscustomobject]@{
        ExitCode          = $run.ExitCode
        Output            = $output
        Produced          = (Test-Path -LiteralPath $csv -PathType Leaf)
        NoTransactionLogs = $noLogs
    }
}

function Copy-IdentityFile {
    # Copies a hive or log into the work folder, as a plain writable file.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Source,

        [Parameter(Mandatory)]
        [string]$Destination
    )

    $target = Get-ExtendedLengthPath -Path $Destination
    [System.IO.File]::Copy((Get-ExtendedLengthPath -Path $Source), $target)
    [System.IO.File]::SetAttributes($target, [System.IO.FileAttributes]::Normal)
}

function New-HostIdentityRecord {
    <#
    .SYNOPSIS
        An empty host identity, the shape every identity file has.
    .DESCRIPTION
        Status and Note are given for a collection whose hives could not be
        reached at all, such as a ZIP that would not extract, so the
        identity dashboard shows why rather than a blank row.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory object only.')]
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [string]$Collection,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$RECmdPath,

        [string]$Status,

        [string[]]$Note = @()
    )

    $recmd = $null
    if (-not [string]::IsNullOrEmpty($RECmdPath)) {
        $recmd = $RECmdPath
    }
    $state = $null
    if (-not [string]::IsNullOrEmpty($Status)) {
        $state = $Status
    }
    return [ordered]@{
        SchemaVersion = $script:HostIdentitySchemaVersion
        Collection    = $Collection
        ExtractedUtc  = [datetime]::UtcNow.ToString($script:IdentityTimeFormat, [System.Globalization.CultureInfo]::InvariantCulture)
        Status        = $state
        Notes         = [string[]]@($Note)
        Source        = [ordered]@{
            ConfigDirectory    = $null
            Hives              = [ordered]@{}
            RECmdPath          = $recmd
            RECmdVersion       = $null
            TestedRECmdVersion = $script:TestedRECmdVersion
        }
        ControlSet    = $null
        Hostname      = $null
        Domain        = $null
        Os            = $null
        TimeZone      = $null
        Users         = @()
        Interfaces    = @()
    }
}

function Get-HostIdentity {
    <#
    .SYNOPSIS
        Reads one collection's host identity from its registry hives.
    .DESCRIPTION
        Finds SYSTEM, SOFTWARE and SAM under CollectionRoot and copies each,
        with its transaction logs, to a folder of its own under
        OutputRoot\_work. RECmd runs against the copies, so the evidence is
        only ever read. It applies the logs in memory and leaves the files
        as they are. The work folder, which holds the copy of SAM and
        RECmd's full output for it, is removed when done, whatever happens.

        Status is Complete when all three hives were read, Partial when
        only some were, NoRegistryHives when the collection has none, as
        in a collection of event logs only, and Failed when RECmd read
        none of them. Notes says what was missing and why.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [string]$Collection,

        [Parameter(Mandatory)]
        [string]$CollectionRoot,

        [Parameter(Mandatory)]
        [string]$OutputRoot,

        [Parameter(Mandatory)]
        [string]$RECmdPath
    )

    $root = ConvertTo-NormalizedPath -Path $CollectionRoot
    $recmd = Assert-RECmdPath -Path $RECmdPath -CollectionRoot $root
    $notes = New-Object System.Collections.Generic.List[string]

    $identity = New-HostIdentityRecord -Collection $Collection -RECmdPath $recmd

    $found = Find-RegistryHive -Root $root
    foreach ($n in $found.Notes) {
        $notes.Add($n)
    }
    if (-not $found.Found) {
        $identity.Status = 'NoRegistryHives'
        $notes.Add('No SYSTEM, SOFTWARE or SAM hive was found under Windows\System32\config, so there is no host identity to read. This is expected for a collection of event logs only.')
        $identity.Notes = $notes.ToArray()
        return $identity
    }
    $identity.Source.ConfigDirectory = Get-RelativeIdentityPath -Root $root -Path $found.ConfigDirectory

    $workParent = Join-Path -Path (ConvertTo-NormalizedPath -Path $OutputRoot) -ChildPath '_work'
    $work = Join-Path -Path $workParent -ChildPath ('identity_' + [guid]::NewGuid().ToString('N'))
    $hivesDir = Join-Path -Path $work -ChildPath 'hives'
    $outDir = Join-Path -Path $work -ChildPath 'out'
    $read = 0
    $present = 0
    try {
        New-Item -ItemType Directory -Path $hivesDir -Force | Out-Null
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
        foreach ($name in $script:IdentityHiveNames) {
            $source = $found.Hives[$name]
            $entry = [ordered]@{
                Path              = Get-RelativeIdentityPath -Root $root -Path $source
                Sha256            = $null
                TransactionLogs   = @($found.Logs[$name] | ForEach-Object { [System.IO.Path]::GetFileName($_) })
                Read              = $false
                NoTransactionLogs = $false
            }
            $identity.Source.Hives[$name] = $entry
            if ($null -eq $source) {
                $notes.Add("No $name hive was found.")
                continue
            }
            $present++

            # Each hive gets its own folder, so RECmd finds only its own logs.
            # A copy keeps its source's ReadOnly attribute, which every file
            # on a mounted image has, and Windows won't delete a read-only
            # file, so it's cleared on each copy for the work folder to come
            # down. Only the copies are touched, never the evidence.
            $hiveDir = New-Item -ItemType Directory -Path (Join-Path -Path $hivesDir -ChildPath $name) -Force
            $copy = Join-Path -Path $hiveDir.FullName -ChildPath $name
            Copy-IdentityFile -Source $source -Destination $copy
            foreach ($log in $found.Logs[$name]) {
                $logCopy = Join-Path -Path $hiveDir.FullName -ChildPath ($name + [System.IO.Path]::GetExtension($log).ToUpperInvariant())
                Copy-IdentityFile -Source $log -Destination $logCopy
            }
            $entry.Sha256 = (Get-FileHash -LiteralPath $copy -Algorithm SHA256).Hash

            try {
                $run = Invoke-RECmdHive -RECmdPath $recmd -HivePath $copy -Name $name -OutputDirectory $outDir
            }
            catch {
                $notes.Add("RECmd could not be run on $name. $($_.Exception.Message)")
                continue
            }
            if ($null -eq $identity.Source.RECmdVersion) {
                $identity.Source.RECmdVersion = Get-RECmdVersionNumber -Output $run.Output
            }
            $entry.NoTransactionLogs = $run.NoTransactionLogs
            if ($run.NoTransactionLogs) {
                $notes.Add("$name is dirty and has no transaction logs, so it was read without them. Changes Windows had not yet written to it are missing.")
            }
            if ($run.Produced) {
                $entry.Read = $true
                $read++
            }
            else {
                $notes.Add("RECmd read nothing from $name. It exited with code $($run.ExitCode).")
            }
        }

        $parsed = ConvertFrom-RECmdOutput -OutputDirectory $outDir
        foreach ($part in @('ControlSet', 'Hostname', 'Domain', 'Os', 'TimeZone', 'Users', 'Interfaces')) {
            $identity[$part] = $parsed[$part]
        }
        foreach ($n in $parsed.Notes) {
            $notes.Add($n)
        }
    }
    finally {
        if ((Test-Path -LiteralPath $work -PathType Container) -and (Test-PathIsWithin -Path $work -Parent $workParent)) {
            try {
                Remove-DirectoryTree -Path $work
            }
            catch {
                Write-Warning "Could not remove the host identity work folder $work. Delete it by hand: it holds copies of $Collection's hives, SAM included, and RECmd's full output. $($_.Exception.Message)"
            }
        }
    }

    $v = $identity.Source.RECmdVersion
    if ($null -ne $v -and $v -ne $script:TestedRECmdVersion) {
        $notes.Add("RECmd $v is not the version this tool was tested with, which is $script:TestedRECmdVersion. Run the RECmd compatibility test against it to check the columns this tool reads.")
    }

    if ($read -eq 0) {
        $identity.Status = 'Failed'
    }
    elseif ($read -lt $script:IdentityHiveNames.Count) {
        $identity.Status = 'Partial'
    }
    else {
        $identity.Status = 'Complete'
    }
    Write-Verbose ("Host identity for {0}: {1}, {2} of {3} hives found and {4} read." -f $Collection, $identity.Status, $present, $script:IdentityHiveNames.Count, $read)
    $identity.Notes = $notes.ToArray()
    return $identity
}

function Get-HostIdentityPath {
    # OutputRoot\<Collection>\<Collection>_identity.json
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$OutputRoot,

        [Parameter(Mandatory)]
        [string]$Collection
    )

    $dir = (Get-CollectionOutputPath -OutputRoot $OutputRoot -Collection $Collection).Directory
    return (Join-Path -Path $dir -ChildPath "$($Collection)_identity.json")
}

function Save-HostIdentity {
    <#
    .SYNOPSIS
        Writes a host identity as UTF-8 JSON without a BOM, in the host's
        output folder.
    .DESCRIPTION
        Goes through a temporary file swapped into place, so a run
        interrupted mid-write keeps the previous file whole.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$OutputRoot,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Identity
    )

    $path = Get-HostIdentityPath -OutputRoot $OutputRoot -Collection ([string]$Identity['Collection'])
    if (-not $PSCmdlet.ShouldProcess($path, 'Write host identity')) {
        return
    }
    $dir = Split-Path -Path $path -Parent
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $json = ConvertTo-Json -InputObject $Identity -Depth $script:HostIdentityJsonDepth
    Write-TextFileAtomic -Path $path -Text $json
    return $path
}

function Read-HostIdentity {
    <#
    .SYNOPSIS
        Reads a collection's saved identity file.
    .DESCRIPTION
        Exists is false when there is no file. Error says why a file that
        exists could not be used: it isn't valid JSON, or it has a schema
        version this tool doesn't know. Identity is the parsed object
        otherwise. Nothing is written.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$OutputRoot,

        [Parameter(Mandatory)]
        [string]$Collection
    )

    $path = Get-HostIdentityPath -OutputRoot $OutputRoot -Collection $Collection
    $result = [pscustomobject]@{
        Path     = $path
        Exists   = $false
        Identity = $null
        Error    = $null
    }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $result
    }
    $result.Exists = $true
    try {
        $parsed = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    }
    catch {
        $result.Error = "Its identity file could not be read: $($_.Exception.Message)"
        return $result
    }
    $versionProp = $null
    if ($null -ne $parsed) {
        $versionProp = $parsed.PSObject.Properties['SchemaVersion']
    }
    if ($null -eq $versionProp -or [string]$versionProp.Value -ne [string]$script:HostIdentitySchemaVersion) {
        $result.Error = "Its identity file has a schema version this tool doesn't read."
        return $result
    }
    $result.Identity = $parsed
    return $result
}

function Invoke-CollectionIdentity {
    <#
    .SYNOPSIS
        Reads and saves one collection's host identity from a path that is
        already extracted or mounted.
    .DESCRIPTION
        Called with the path the collection was resolved to for this run,
        so a ZIP is never extracted, or an image mounted, a second time.
        Never throws: if reading fails outright, a Failed identity saying
        why is saved instead, and if saving fails, that is warned about.
        Returns the identity.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [string]$Collection,

        [Parameter(Mandatory)]
        [string]$CollectionRoot,

        [Parameter(Mandatory)]
        [string]$OutputRoot,

        [Parameter(Mandatory)]
        [string]$RECmdPath
    )

    try {
        $identity = Get-HostIdentity -Collection $Collection -CollectionRoot $CollectionRoot -OutputRoot $OutputRoot -RECmdPath $RECmdPath
    }
    catch {
        $identity = New-HostIdentityRecord -Collection $Collection -RECmdPath $RECmdPath -Status 'Failed' -Note @("Host identity could not be read: $($_.Exception.Message)")
    }
    try {
        Save-HostIdentity -OutputRoot $OutputRoot -Identity $identity | Out-Null
    }
    catch {
        Write-Warning "${Collection}: could not save the host identity: $($_.Exception.Message)"
    }
    return $identity
}
