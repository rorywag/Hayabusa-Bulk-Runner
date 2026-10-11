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
        are passed as one comma-separated value per flag. The time window
        and thread count are only included when set.
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
    if ($include.Count -gt 0) {
        $list.Add('--include-tag'); $list.Add(($include -join ','))
    }
    $exclude = @($Selection['ExcludeTags'] | Where-Object { -not [string]::IsNullOrEmpty($_) })
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
        $writer.WriteLine("Started (UTC): $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))")
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
        $writer.WriteLine("Finished (UTC): $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))")
        return $exit
    }
    finally {
        $writer.Dispose()
    }
}

function Get-HayabusaVersion {
    <#
    .SYNOPSIS
        Runs hayabusa --version once at startup and returns its output.
    .DESCRIPTION
        The output is stored verbatim: Version is the first non-empty line
        and Output is every non-empty line. If the call fails, Version is
        null and Error says why. The run carries on either way.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$HayabusaPath
    )

    $result = [pscustomobject]@{
        Version  = $null
        Output   = @()
        ExitCode = $null
        Error    = $null
    }

    try {
        Assert-HayabusaHost
        $lines = New-Object System.Collections.Generic.List[string]
        $exit = Invoke-NativeCapture -FilePath $HayabusaPath -Argument @('--version') -OnLine {
            param($line)
            if (-not [string]::IsNullOrWhiteSpace($line)) {
                $lines.Add($line.TrimEnd())
            }
        }
        $result.ExitCode = $exit
        $result.Output = $lines.ToArray()
        if ($lines.Count -gt 0) {
            $result.Version = $lines[0]
        }
        if ($exit -ne 0) {
            $result.Error = "hayabusa --version exited with code $exit"
        }
    }
    catch {
        $result.Error = $_.Exception.Message
    }

    return $result
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
        $newest = ($files | Sort-Object -Property LastWriteTimeUtc -Descending | Select-Object -First 1).LastWriteTimeUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
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
