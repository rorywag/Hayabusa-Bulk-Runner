# ANSI escape sequences, stripped from log lines in case colour output is
# not fully disabled by the no-color flag.
$script:AnsiPattern = '\x1B\[[0-9;?]*[ -/]*[@-~]'

function Assert-HayabusaHost {
    [CmdletBinding()]
    param()

    if (-not (Test-IsWindowsHost)) {
        throw 'Running Hayabusa requires Windows.'
    }
}

function ConvertTo-PlainText {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text
    )

    return ($Text -replace $script:AnsiPattern, '')
}

function Assert-NativeArgument {
    <#
    .SYNOPSIS
        Refuses arguments that Windows PowerShell 5.1 would pass incorrectly.
    .DESCRIPTION
        5.1 builds a native command line from the argument array and only
        quotes arguments that contain whitespace. An empty argument is
        dropped, an embedded double quote is mangled, and an argument with
        whitespace that ends in a backslash becomes "...\" which escapes the
        closing quote. None of these can occur with paths this tool builds,
        so any of them is a bug and is refused rather than passed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Argument
    )

    for ($i = 0; $i -lt $Argument.Count; $i++) {
        $a = $Argument[$i]
        if ([string]::IsNullOrEmpty($a)) {
            throw "Hayabusa argument $i is empty."
        }
        if ($a.Contains('"')) {
            throw "Hayabusa argument $i contains a double quote: $a"
        }
        if ($a -match '\s' -and $a.EndsWith('\')) {
            throw "Hayabusa argument $i contains whitespace and ends in a backslash: $a"
        }
    }
}

function New-HayabusaArgument {
    <#
    .SYNOPSIS
        Builds the dfir-timeline argument array for one collection.
    .DESCRIPTION
        The result is passed to the binary with the call operator and
        splatting, never joined into a command string.

        Exactly one of -m (MinLevel) or -e (ExactLevel) is included. Tags
        are passed as one comma-separated value per flag, and at most one
        of --include-tag or --exclude-tag, since Hayabusa 4.1.0 refuses the
        pair. The time window and thread count are only included when set.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory array only.')]
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [string]$InputPath,

        [Parameter(Mandatory)]
        [string]$CsvPath,

        [Parameter(Mandatory)]
        [string]$HtmlPath,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Selection,

        [AllowNull()]
        [object]$Threads
    )

    $hasMin = -not [string]::IsNullOrEmpty([string]$Selection['MinLevel'])
    $hasExact = -not [string]::IsNullOrEmpty([string]$Selection['ExactLevel'])
    if ($hasMin -eq $hasExact) {
        throw 'Exactly one of MinLevel or ExactLevel must be set.'
    }

    $list = New-Object System.Collections.Generic.List[string]
    foreach ($a in @(
            'dfir-timeline'
            '-d', $InputPath
            '-w'
            '-K'
            '-p', [string]$Selection['Profile']
            '-U'
            '-t', 'csv'
            '-o', $CsvPath
            '-H', $HtmlPath
            '-s'
            '-X'
            '-C'
            '-r', [string]$Selection['RulesPath']
        )) {
        $list.Add($a)
    }

    if ($hasMin) {
        $list.Add('-m'); $list.Add([string]$Selection['MinLevel'])
    }
    else {
        $list.Add('-e'); $list.Add([string]$Selection['ExactLevel'])
    }

    if ($null -ne $Threads) {
        $list.Add('--threads'); $list.Add([string]$Threads)
    }

    $include = @($Selection['IncludeTags'] | Where-Object { -not [string]::IsNullOrEmpty($_) })
    $exclude = @($Selection['ExcludeTags'] | Where-Object { -not [string]::IsNullOrEmpty($_) })
    if ($include.Count -gt 0 -and $exclude.Count -gt 0) {
        throw 'Set IncludeTags or ExcludeTags, not both. Hayabusa 4.1.0 refuses --include-tag with --exclude-tag.'
    }
    if ($include.Count -gt 0) {
        $list.Add('--include-tag'); $list.Add(($include -join ','))
    }
    if ($exclude.Count -gt 0) {
        $list.Add('--exclude-tag'); $list.Add(($exclude -join ','))
    }

    if (-not [string]::IsNullOrEmpty([string]$Selection['TimelineStart'])) {
        $list.Add('--timeline-start'); $list.Add([string]$Selection['TimelineStart'])
    }
    if (-not [string]::IsNullOrEmpty([string]$Selection['TimelineEnd'])) {
        $list.Add('--timeline-end'); $list.Add([string]$Selection['TimelineEnd'])
    }

    $result = $list.ToArray()
    Assert-NativeArgument -Argument $result
    return $result
}

function Invoke-NativeCapture {
    <#
    .SYNOPSIS
        Runs a native command and hands each output line to a scriptblock.
    .DESCRIPTION
        Error action is relaxed to Continue for the call because Windows
        PowerShell 5.1, with Stop in effect, turns the first stderr line of
        a redirected native command into a terminating error. Console output
        encoding is set to UTF-8 for the call and restored after. Lines from
        stderr are prefixed with [stderr] and ANSI codes are stripped.
        Returns the exit code.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Argument,

        [Parameter(Mandatory)]
        [scriptblock]$OnLine
    )

    $ErrorActionPreference = 'Continue'
    $previousEncoding = $null
    try {
        $previousEncoding = [Console]::OutputEncoding
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    }
    catch {
        $previousEncoding = $null
    }

    try {
        & $FilePath @Argument 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) {
                $line = '[stderr] ' + $_.ToString()
            }
            else {
                $line = [string]$_
            }
            & $OnLine (ConvertTo-PlainText -Text $line) | Out-Null
        }
        return [int]$LASTEXITCODE
    }
    finally {
        if ($null -ne $previousEncoding) {
            try {
                [Console]::OutputEncoding = $previousEncoding
            }
            catch {
                Write-Verbose 'Could not restore console output encoding.'
            }
        }
    }
}

function Invoke-HayabusaProcess {
    <#
    .SYNOPSIS
        Runs Hayabusa with an argument array and writes a per-host log.
    .DESCRIPTION
        The log starts with the time, the binary and the exact argument
        list, one per line, for the record. Hayabusa's stdout and stderr
        follow as they arrive, then the exit code. Returns the exit code.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [string]$HayabusaPath,

        [Parameter(Mandatory)]
        [string[]]$Argument,

        [Parameter(Mandatory)]
        [string]$LogPath
    )

    Assert-HayabusaHost

    if (-not $PSCmdlet.ShouldProcess($HayabusaPath, 'Run Hayabusa')) {
        return
    }

    $encoding = New-Object System.Text.UTF8Encoding($false)
    $writer = New-Object System.IO.StreamWriter($LogPath, $false, $encoding)
    try {
        $writer.WriteLine("Started (UTC): $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture))")
        $writer.WriteLine("Binary: $HayabusaPath")
        $writer.WriteLine('Arguments:')
        foreach ($a in $Argument) {
            $writer.WriteLine("  $a")
        }
        $writer.WriteLine('--- output ---')
        $writer.Flush()

        $exit = Invoke-NativeCapture -FilePath $HayabusaPath -Argument $Argument -OnLine {
            param($line)
            $writer.WriteLine($line)
        }

        $writer.WriteLine('--- end ---')
        $writer.WriteLine("Exit code: $exit")
        $writer.WriteLine("Finished (UTC): $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture))")
        return $exit
    }
    finally {
        $writer.Dispose()
    }
}

function Get-HayabusaLogStderr {
    # The stderr lines Invoke-HayabusaProcess recorded in a run's log,
    # without their [stderr] prefix.
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [string]$LogPath
    )

    if (-not (Test-Path -LiteralPath $LogPath -PathType Leaf)) {
        return [string[]]@()
    }
    $lines = @(Get-Content -LiteralPath $LogPath -Encoding UTF8 | Where-Object { $_ -like '`[stderr`] *' } | ForEach-Object { $_.Substring(9) })
    return [string[]]$lines
}

function Get-HayabusaLogError {
    <#
    .SYNOPSIS
        Hayabusa's own error message from a run's log, or null.
    .DESCRIPTION
        Hayabusa reports a failed run on stderr as "[ERROR] <message>",
        sometimes with exit code 0. The [ERROR] lines are returned without
        that prefix, or, if there are none, the other stderr lines, up to
        three joined with " / ". Null when stderr was empty.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$LogPath
    )

    # PowerShell 7 records a blank native stderr line as the name of the
    # exception type, so those are dropped with the blank ones.
    $text = @(Get-HayabusaLogStderr -LogPath $LogPath | ForEach-Object { $_.Trim() } | Where-Object { $_.Length -gt 0 -and $_ -ne 'System.Management.Automation.RemoteException' })
    $errors = @($text | ForEach-Object { if ($_ -match '^\[ERROR\]\s*(.+)$') { $Matches[1].Trim() } })
    if ($errors.Count -gt 0) {
        $text = $errors
    }
    if ($text.Count -eq 0) {
        return $null
    }
    return (@($text | Select-Object -First 3) -join ' / ')
}

# Hayabusa 4.1.0 has no --version flag. The version is the banner line
# printed by help, for example "Hayabusa v4.1.0 - Suzumushi Release".
$script:VersionLinePattern = '^\s*Hayabusa v\d+\.\d+'

# The Hayabusa release this tool's flags, CSV handling and severity levels
# were checked against. Test-HayabusaCompatibility.ps1 checks a new release;
# when it passes, raise this and the values between the tested-version
# markers in README.md and docs/USAGE.md. This is the only place the tested
# version is set: the tests and the fake Hayabusa take it from here, and a
# test checks the docs markers match it.
$script:TestedHayabusaVersion = '4.2.0'

function Get-HayabusaVersion {
    <#
    .SYNOPSIS
        Runs hayabusa help once at startup and returns its version line.
    .DESCRIPTION
        Version is the first output line that starts with "Hayabusa v"
        and a dotted version number, stored verbatim apart from surrounding
        whitespace and colour codes. Matching the pattern, not just taking
        the first line, keeps a logo printed above the banner from being
        taken as the version, and anchoring it to the start of the line
        keeps a mention of the name later in the help text from matching. If no
        line matches or the call fails, Version is null and Error says why.
        The run carries on either way.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$HayabusaPath
    )

    $result = [pscustomobject]@{
        Version  = $null
        ExitCode = $null
        Error    = $null
    }

    try {
        Assert-HayabusaHost
        $lines = New-Object System.Collections.Generic.List[string]
        $exit = Invoke-NativeCapture -FilePath $HayabusaPath -Argument @('help') -OnLine {
            param($line)
            $lines.Add($line)
        }
        $result.ExitCode = $exit

        foreach ($line in $lines) {
            if ($line -match $script:VersionLinePattern) {
                $result.Version = $line.Trim()
                break
            }
        }

        if ($null -eq $result.Version) {
            $result.Error = "No line matching 'Hayabusa v<version>' in hayabusa help output (exit code $exit)."
        }
        elseif ($exit -ne 0) {
            $result.Error = "hayabusa help exited with code $exit. Version line was still read."
        }
    }
    catch {
        $result.Error = $_.Exception.Message
    }

    return $result
}

function Get-HayabusaVersionNumber {
    <#
    .SYNOPSIS
        The dotted version number from a Hayabusa version line, or null.
    .DESCRIPTION
        "Hayabusa v4.1.0 - Suzumushi Release" gives 4.1.0.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$VersionLine
    )

    $m = [regex]::Match([string]$VersionLine, '\bv(\d+(?:\.\d+)+)')
    if ($m.Success) {
        return $m.Groups[1].Value
    }
    return $null
}

function Get-HayabusaVersionNotice {
    <#
    .SYNOPSIS
        A one-line notice when the detected Hayabusa is not the tested
        release, or null.
    .DESCRIPTION
        Nothing is returned when the versions match or the version could
        not be read, since a failed read is already warned about.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$VersionLine
    )

    $number = Get-HayabusaVersionNumber -VersionLine $VersionLine
    if ($null -eq $number -or $number -eq $script:TestedHayabusaVersion) {
        return $null
    }
    return "Hayabusa $number is not the version this tool was tested with ($script:TestedHayabusaVersion). Run Test-HayabusaCompatibility.ps1 against it to check the flags, output columns and severity levels this tool relies on."
}

# The columns every triage view reads from a Hayabusa CSV. An output profile
# is only usable if its column headers include all three.
$script:ProfileRequiredColumns = @('Level', 'Computer', 'RuleTitle')

# Used when config\profiles.yaml beside hayabusa.exe can't be read: the two
# profiles every Hayabusa release this tool has been checked against offers.
$script:FallbackOutputProfiles = @('standard', 'verbose')

function Read-HayabusaProfileFile {
    <#
    .SYNOPSIS
        Reads the profile names and their column headers from a Hayabusa
        profiles.yaml.
    .DESCRIPTION
        The file is a top-level key per profile, each with one indented
        "Header: value" line per output column, for example
        'RuleTitle: "%RuleTitle%"'. Only the header, the left side, is
        kept, since the CSV's column names are the headers: a profile can
        carry %RuleTitle% as a value under a header with another name,
        which the triage views can't read. Comments and blank lines are
        skipped. Anything else is not a format this
        reader knows, so it throws rather than guess. Returns an ordered
        dictionary of profile name to its headers.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $profiles = [ordered]@{}
    $current = $null
    $lineNumber = 0
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        $lineNumber++
        $text = $line.TrimEnd()
        if ($text.Length -eq 0 -or $text.TrimStart().StartsWith('#')) {
            continue
        }
        $profileMatch = [regex]::Match($text, '^([A-Za-z0-9][A-Za-z0-9_.-]*):$')
        if ($profileMatch.Success) {
            $current = New-Object System.Collections.Generic.List[string]
            $profiles[$profileMatch.Groups[1].Value] = $current
            continue
        }
        $columnMatch = [regex]::Match($text, '^\s+("?)([^":#]+)\1:\s*(\S.*)?$')
        if ($columnMatch.Success -and $null -ne $current) {
            $current.Add($columnMatch.Groups[2].Value.Trim())
            continue
        }
        throw "line $lineNumber is not a profile name or an indented column: $text"
    }
    if ($profiles.Count -eq 0) {
        throw 'it defines no profiles'
    }

    $result = [ordered]@{}
    foreach ($name in $profiles.Keys) {
        $result[$name] = [string[]]$profiles[$name].ToArray()
    }
    return $result
}

function Get-HayabusaProfileSet {
    <#
    .SYNOPSIS
        The output profiles a Hayabusa binary offers, and which of them the
        triage views can read.
    .DESCRIPTION
        Reads config\profiles.yaml from the folder beside HayabusaPath. A
        profile is usable if its column headers include Level, Computer and
        RuleTitle. The others are listed in Unusable with the columns they
        lack. If the file is missing or can't be read, Read is false, Error
        says why, and only standard and verbose are usable, as before this
        list was read from the binary.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$HayabusaPath
    )

    $path = Join-Path -Path (Join-Path -Path (Split-Path -Path $HayabusaPath -Parent) -ChildPath 'config') -ChildPath 'profiles.yaml'
    $set = [pscustomobject]@{
        Path     = $path
        Read     = $false
        Error    = $null
        Usable   = [string[]]$script:FallbackOutputProfiles
        Unusable = [ordered]@{}
    }

    $profiles = $null
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $set.Error = 'the file is not there'
        return $set
    }
    try {
        $profiles = Read-HayabusaProfileFile -Path $path
    }
    catch {
        $set.Error = $_.Exception.Message
        return $set
    }

    $usable = New-Object System.Collections.Generic.List[string]
    foreach ($name in $profiles.Keys) {
        $missing = @($script:ProfileRequiredColumns | Where-Object { $profiles[$name] -notcontains $_ })
        if ($missing.Count -eq 0) {
            $usable.Add($name)
        }
        else {
            $set.Unusable[$name] = [string[]]$missing
        }
    }
    $set.Read = $true
    $set.Usable = [string[]]$usable.ToArray()
    return $set
}

function Resolve-OutputProfile {
    <#
    .SYNOPSIS
        Accepts the chosen output profile, or refuses it with a plain reason.
    .DESCRIPTION
        The one place a profile is turned away. A name the binary doesn't
        offer is refused, naming the ones it does. A profile it offers whose
        headers lack one of the columns the triage views read is refused
        too, for now, naming the missing column. If running such a profile
        and skipping the dashboard is ever wanted, this is where to change.
        Returns the profile name as Hayabusa spells it.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Name,

        [Parameter(Mandatory)]
        [pscustomobject]$ProfileSet
    )

    $wanted = $Name.Trim()
    $choices = $ProfileSet.Usable -join ', '
    foreach ($p in $ProfileSet.Usable) {
        if ($p -ieq $wanted) {
            return $p
        }
    }
    foreach ($p in $ProfileSet.Unusable.Keys) {
        if ($p -ieq $wanted) {
            # Named from the profile's own headers, whatever it calls them instead.
            $missing = @($ProfileSet.Unusable[$p])
            $columns = "$($missing[0]) column, which"
            if ($missing.Count -gt 1) {
                $columns = "$((@($missing | Select-Object -First ($missing.Count - 1))) -join ', ') or $($missing[-1]) columns, which"
            }
            throw ("Profile '{0}' has no {1} the triage dashboard needs, so it isn't available yet. Use one of: {2}" -f $p, $columns, $choices)
        }
    }
    if ($ProfileSet.Read) {
        throw ("Profile '{0}' isn't one this Hayabusa offers. Use one of: {1}" -f $Name, $choices)
    }
    throw ("Profile '{0}' can't be checked, because the list of profiles couldn't be read. Use one of: {1}" -f $Name, $choices)
}

function Get-RulesVersion {
    <#
    .SYNOPSIS
        Describes the rule set by its newest rule file and its rule count.
    .DESCRIPTION
        Counts .yml and .yaml files under RulesPath, or the single file if
        RulesPath is a file, and takes the newest last-write time in UTC.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$RulesPath
    )

    $files = @()
    if (Test-Path -LiteralPath $RulesPath -PathType Leaf) {
        $files = @(Get-Item -LiteralPath $RulesPath)
    }
    elseif (Test-Path -LiteralPath $RulesPath -PathType Container) {
        $files = @(Get-ChildItem -LiteralPath $RulesPath -Recurse -File -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -eq '.yml' -or $_.Extension -eq '.yaml' })
    }

    $newest = $null
    if ($files.Count -gt 0) {
        $newest = ($files | Sort-Object -Property LastWriteTimeUtc -Descending | Select-Object -First 1).LastWriteTimeUtc.ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
    }

    $summary = 'no rule files found'
    if ($null -ne $newest) {
        $summary = "newest rule file $newest, $($files.Count) rule files"
    }

    [pscustomobject]@{
        NewestRuleFileUtc = $newest
        RuleFileCount     = $files.Count
        Summary           = $summary
    }
}
