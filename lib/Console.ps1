# Everything Invoke-BulkHayabusa.ps1 shows while it runs, from the run
# header to one block per host with a line for each step and the summary
# table at the end, along with the progress bars and the run log that keeps
# the same lines as plain text.
#
# Lines go out through Write-Information, so -InformationAction
# SilentlyContinue hides them and -InformationVariable still captures them.
# A line with a coloured word goes out through Write-Host instead, one
# piece at a time, since that's the only way the host colours part of a
# line on both Windows PowerShell 5.1 and PowerShell 7, and it's only used
# while information lines are on screen, so quiet mode stays quiet. No raw
# escape codes are ever written. Every value shown or logged passes through
# ConvertTo-ConsoleText first, progress bars included, since computer names,
# user names, network names and Hayabusa's own output all come from the
# evidence.

# Longest value a field shows, and the longest line the sanitiser lets
# through at all.
$script:ConsoleValueMaxLength = 200
$script:ConsoleLineMaxLength = 4000

# Fallback when the console width can't be read, and the narrowest layout.
$script:ConsoleDefaultWidth = 120
$script:ConsoleMinimumWidth = 60

# Progress bars are redrawn at most this often.
$script:ConsoleProgressIntervalMs = 250

# Step lines: indent, then the step name, then the result, then the time.
$script:ConsoleStepIndent = 6
$script:ConsoleStepNameWidth = 22
$script:ConsoleStepResultWidth = 28
$script:ConsoleStepTimeWidth = 6

# Header labels are padded to this width.
$script:ConsoleLabelWidth = 10

# Lines held back until the run log is open, at most this many.
$script:ConsolePendingMax = 5000

$script:ConsoleStatusColor = @{
    'complete'            = [System.ConsoleColor]::Green
    'completed'           = [System.ConsoleColor]::Green
    'partial'             = [System.ConsoleColor]::Yellow
    'completedwitherrors' = [System.ConsoleColor]::Yellow
    'noregistryhives'     = [System.ConsoleColor]::Yellow
    'failed'              = [System.ConsoleColor]::Red
    'changed'             = [System.ConsoleColor]::Red
    'skipped'             = [System.ConsoleColor]::DarkGray
}

$script:ConsoleState = $null

function ConvertTo-ConsoleText {
    <#
    .SYNOPSIS
        Makes a value safe to show on the console or write to the run log,
        progress bars included.
    .DESCRIPTION
        Removes escape sequences whole, CSI and OSC along with the other
        string sequences, so a crafted name can't rewrite what's already on
        screen or set the window title. Then removes every C0 and C1
        control character, DEL among them, along with every character in
        the Unicode format category, Cf. That takes out the bidi overrides
        and isolates, which could make text read in a different order than
        it's stored, and the invisible ones such as the zero-width space
        and the byte order mark, so a computer name with one hidden inside
        can't pass for the real one. Format characters outside
        the Basic Multilingual Plane, the tag characters among them, are
        taken out too. Line breaks and tabs become a space, and anything
        longer than MaxLength is cut, ending in "...".
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [object]$Text,

        [int]$MaxLength = $script:ConsoleValueMaxLength
    )

    if ($null -eq $Text) {
        return ''
    }
    $s = [string]$Text
    # String sequences: OSC, DCS, SOS, PM and APC, in their ESC and C1
    # forms, up to BEL or the string terminator, or the end if unterminated.
    $s = [regex]::Replace($s, '(?:\x1B[\]PX^_]|[\x90\x98\x9D\x9E\x9F])[^\x07\x1B\x9C]*(?:\x07|\x9C|\x1B\\)?', '')
    # CSI sequences, in their ESC [ and C1 forms.
    $s = [regex]::Replace($s, '(?:\x1B\[|\x9B)[\x30-\x3F]*[\x20-\x2F]*[\x40-\x7E]?', '')
    # Any other escape and the character after it.
    $s = [regex]::Replace($s, '\x1B[\x20-\x7E]?', '')
    $s = [regex]::Replace($s, '\r\n|[\r\n\t\v\f\u0085\u2028\u2029]', ' ')
    $s = [regex]::Replace($s, '[\x00-\x1F\x7F-\x9F\p{Cf}]', '')
    # The regex sees a character outside the Basic Multilingual Plane as two
    # surrogates, so a format character there is found by its category.
    if ($s -match '[\uD800-\uDBFF]') {
        $kept = New-Object System.Text.StringBuilder $s.Length
        for ($i = 0; $i -lt $s.Length; $i++) {
            if ([char]::IsSurrogatePair($s, $i)) {
                if ([System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($s, $i) -ne [System.Globalization.UnicodeCategory]::Format) {
                    [void]$kept.Append($s, $i, 2)
                }
                $i++
            }
            else {
                [void]$kept.Append($s[$i])
            }
        }
        $s = $kept.ToString()
    }
    if ($MaxLength -gt 3 -and $s.Length -gt $MaxLength) {
        $s = $s.Substring(0, $MaxLength - 3) + '...'
    }
    return $s
}

function Test-ConsoleColorWanted {
    # Colour is off when NO_COLOR is set to anything, or output is redirected.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$NoColor,

        [Parameter(Mandatory)]
        [bool]$Redirected
    )

    return ([string]::IsNullOrEmpty($NoColor) -and -not $Redirected)
}

function Test-ConsoleRedirected {
    # True when stdout isn't a console, or that can't be told.
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    try {
        return [System.Console]::IsOutputRedirected
    }
    catch {
        return $true
    }
}

function Get-ConsoleWidth {
    # The console's width, or the fallback when it can't be read.
    [CmdletBinding()]
    [OutputType([int])]
    param()

    $width = 0
    try {
        $width = [int]$Host.UI.RawUI.WindowSize.Width
    }
    catch {
        $width = 0
    }
    if ($width -le 0) {
        return $script:ConsoleDefaultWidth
    }
    return [math]::Max($script:ConsoleMinimumWidth, $width)
}

function Initialize-ConsoleOutput {
    <#
    .SYNOPSIS
        Starts a fresh console state for a run.
    .DESCRIPTION
        Colour and width are worked out once here unless given. With
        BufferLog, lines are held until Open-ConsoleRunLog, so the log
        starts with everything the console showed.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Sets in-memory state only.')]
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Color = $null,

        [int]$Width = 0,

        [switch]$BufferLog
    )

    $useColor = $false
    if ($null -ne $Color) {
        $useColor = [bool]$Color
    }
    else {
        $useColor = Test-ConsoleColorWanted -NoColor $env:NO_COLOR -Redirected (Test-ConsoleRedirected)
    }
    if ($Width -le 0) {
        $Width = Get-ConsoleWidth
    }
    $pending = $null
    if ($BufferLog) {
        $pending = New-Object System.Collections.Generic.List[string]
    }
    $script:ConsoleState = @{
        Color         = $useColor
        Width         = $Width
        Log           = $null
        LogPath       = $null
        LogFailed     = $false
        Pending       = $pending
        Rows          = New-Object System.Collections.Generic.List[object]
        Host          = $null
        Step          = $null
        ProgressWatch = [System.Diagnostics.Stopwatch]::StartNew()
        LastProgress  = -1000000L
    }
}

function Get-ConsoleState {
    # The current state, made with the defaults on first use.
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    if ($null -eq $script:ConsoleState) {
        Initialize-ConsoleOutput
    }
    return $script:ConsoleState
}

function Get-ConsoleUsableWidth {
    # One less than the width, so a full line never wraps on its own.
    [CmdletBinding()]
    [OutputType([int])]
    param()

    return ((Get-ConsoleState).Width - 1)
}

function Test-ConsoleInformationShown {
    # True when information lines reach the screen.
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $p = [string]$InformationPreference
    return ($p -eq 'Continue' -or $p -eq 'Inquire')
}

function Format-ConsoleDuration {
    # 38s, 1m34s, 1h02m03s.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [double]$Seconds
    )

    $t = [long][math]::Round([math]::Max(0, $Seconds))
    if ($t -lt 60) {
        return ('{0}s' -f $t)
    }
    if ($t -lt 3600) {
        return ('{0}m{1:00}s' -f [long][math]::Floor($t / 60), ($t % 60))
    }
    return ('{0}h{1:00}m{2:00}s' -f [long][math]::Floor($t / 3600), [long][math]::Floor(($t % 3600) / 60), ($t % 60))
}

function Format-ConsoleByteSize {
    # 4.1 GB, 512 MB, 12 KB, 300 bytes.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [double]$Bytes
    )

    $invariant = [System.Globalization.CultureInfo]::InvariantCulture
    if ($Bytes -ge 1GB) {
        return ('{0} GB' -f ($Bytes / 1GB).ToString('0.0', $invariant))
    }
    if ($Bytes -ge 1MB) {
        return ('{0} MB' -f [math]::Round($Bytes / 1MB).ToString($invariant))
    }
    if ($Bytes -ge 1KB) {
        return ('{0} KB' -f [math]::Round($Bytes / 1KB).ToString($invariant))
    }
    return ('{0} bytes' -f $Bytes.ToString('0', $invariant))
}

function Format-ConsoleMiddle {
    # Shortens text to Width by cutting out its middle, as "start...end".
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [string]$Text,

        [Parameter(Mandatory)]
        [int]$Width
    )

    if ($Text.Length -le $Width) {
        return $Text
    }
    if ($Width -le 3) {
        return $Text.Substring(0, [math]::Max(0, $Width))
    }
    $keep = $Width - 3
    $head = [int][math]::Ceiling($keep / 2)
    $tail = $keep - $head
    return ($Text.Substring(0, $head) + '...' + $Text.Substring($Text.Length - $tail))
}

function Format-ConsoleEnd {
    # Shortens text to Width by cutting its end, ending in "...".
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [string]$Text,

        [Parameter(Mandatory)]
        [int]$Width
    )

    if ($Text.Length -le $Width) {
        return $Text
    }
    if ($Width -le 3) {
        return $Text.Substring(0, [math]::Max(0, $Width))
    }
    return ($Text.Substring(0, $Width - 3) + '...')
}

function Format-ConsolePath {
    <#
    .SYNOPSIS
        Shortens a path to Width in the middle, keeping the start and the
        whole leaf, as C:\Tools\...\RECmd.exe.
    .DESCRIPTION
        The leaf is never cut, so a leaf longer than Width comes back whole.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [string]$Path,

        [Parameter(Mandatory)]
        [int]$Width
    )

    $p = ConvertTo-ConsoleText -Text $Path -MaxLength $script:ConsoleLineMaxLength
    if ($p.Length -le $Width) {
        return $p
    }
    $cut = $p.TrimEnd('\', '/').LastIndexOfAny([char[]]@('\', '/'))
    if ($cut -lt 0) {
        return $p
    }
    $sep = $p.Substring($cut, 1)
    $leaf = $p.Substring($cut + 1)
    $budget = $Width - $leaf.Length - 5
    if ($budget -le 0) {
        return ('...' + $sep + $leaf)
    }
    $head = $p.Substring(0, [math]::Min($budget, $cut))
    $lastSep = $head.LastIndexOfAny([char[]]@('\', '/'))
    if ($lastSep -gt 0) {
        $head = $head.Substring(0, $lastSep)
    }
    return ($head + $sep + '...' + $sep + $leaf)
}

function Get-ConsoleStatusColor {
    # The colour for a status word, or null for one shown plain.
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Word
    )

    if ([string]::IsNullOrEmpty($Word)) {
        return $null
    }
    $key = $Word.ToLowerInvariant()
    if ($script:ConsoleStatusColor.ContainsKey($key)) {
        return $script:ConsoleStatusColor[$key]
    }
    return $null
}

function Split-ConsoleStatus {
    <#
    .SYNOPSIS
        Splits a result into its leading status word, coloured, and the
        rest, plain, for Write-ConsoleLine.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [AllowEmptyString()]
        [string]$Text
    )

    $m = [regex]::Match($Text, '^([A-Za-z]+)(.*)$')
    if ($m.Success) {
        $color = Get-ConsoleStatusColor -Word $m.Groups[1].Value
        if ($null -ne $color) {
            return @(@{ Text = $m.Groups[1].Value; Color = $color }, @{ Text = $m.Groups[2].Value; Color = $null })
        }
    }
    return @(@{ Text = $Text; Color = $null })
}

function Get-ConsoleTimestamp {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    return [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Write-ConsoleLogLine {
    <#
    .SYNOPSIS
        Adds one line to the run log, timestamped in UTC.
    .DESCRIPTION
        Held back while the log isn't open yet, if the run asked for that.
        A failure to write warns once and the run carries on without a log.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$Text
    )

    $state = Get-ConsoleState
    if ($state.LogFailed -or [string]::IsNullOrEmpty($Text)) {
        return
    }
    $line = (Get-ConsoleTimestamp) + ' ' + (ConvertTo-ConsoleText -Text $Text -MaxLength $script:ConsoleLineMaxLength)
    if ($null -ne $state.Log) {
        try {
            $state.Log.WriteLine($line)
            $state.Log.Flush()
        }
        catch {
            Stop-ConsoleRunLog -Reason $_.Exception.Message
        }
        return
    }
    if ($null -ne $state.Pending -and $state.Pending.Count -lt $script:ConsolePendingMax) {
        $state.Pending.Add($line)
    }
}

function Stop-ConsoleRunLog {
    # Gives up on the run log after a failure, warning once.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Closes the run log only.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Reason
    )

    $state = Get-ConsoleState
    if ($state.LogFailed) {
        return
    }
    $state.LogFailed = $true
    $state.Pending = $null
    if ($null -ne $state.Log) {
        try {
            $state.Log.Dispose()
        }
        catch {
            Write-Verbose "Could not close the run log: $($_.Exception.Message)"
        }
        $state.Log = $null
    }
    $where = 'the run log'
    if (-not [string]::IsNullOrEmpty($state.LogPath)) {
        $where = "the run log at $($state.LogPath)"
    }
    Write-Warning (ConvertTo-ConsoleText -Text "Couldn't write $where, so this run carries on without one. $Reason" -MaxLength $script:ConsoleLineMaxLength)
}

function Get-RunLogPath {
    # OutputRoot\_runs\run_<utc-stamp>_<RunId>.log, the stamp and RunId
    # matching the run's run-meta file.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$OutputRoot,

        [Parameter(Mandatory)]
        [datetime]$StartedUtc,

        [Parameter(Mandatory)]
        [string]$RunId
    )

    $stamp = $StartedUtc.ToUniversalTime().ToString('yyyyMMddTHHmmssZ', [System.Globalization.CultureInfo]::InvariantCulture)
    return (Join-Path -Path (Join-Path -Path $OutputRoot -ChildPath '_runs') -ChildPath "run_$($stamp)_$RunId.log")
}

function Open-ConsoleRunLog {
    <#
    .SYNOPSIS
        Opens the run log for append and writes the lines held back so far.
    .DESCRIPTION
        UTF-8 without a BOM, shared for reading so it can be watched while
        the run goes. A _runs folder or log file that is a link or junction
        is refused, since writing through it could land anywhere. Any
        failure warns once and the run carries on without a log.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $state = Get-ConsoleState
    $state.LogPath = $Path
    $state.LogFailed = $false
    $link = [System.IO.FileAttributes]::ReparsePoint
    try {
        $dir = Split-Path -Path $Path -Parent
        if (Test-Path -LiteralPath $dir) {
            if (([System.IO.File]::GetAttributes($dir) -band $link) -ne 0) {
                throw "$dir is a link or junction."
            }
        }
        else {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        if ((Test-Path -LiteralPath $Path) -and (([System.IO.File]::GetAttributes($Path) -band $link) -ne 0)) {
            throw "$Path is a link or junction."
        }
        $stream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
        $state.Log = New-Object System.IO.StreamWriter($stream, (New-Object System.Text.UTF8Encoding($false)))
        if ($null -ne $state.Pending) {
            foreach ($line in $state.Pending) {
                $state.Log.WriteLine($line)
            }
            $state.Log.Flush()
        }
    }
    catch {
        Stop-ConsoleRunLog -Reason $_.Exception.Message
    }
    $state.Pending = $null
}

function Close-ConsoleRunLog {
    # Closes the run log, if one is open.
    [CmdletBinding()]
    param()

    $state = Get-ConsoleState
    if ($null -ne $state.Log) {
        try {
            $state.Log.Dispose()
        }
        catch {
            Write-Verbose "Could not close the run log: $($_.Exception.Message)"
        }
        $state.Log = $null
    }
}

function Write-ConsoleLine {
    <#
    .SYNOPSIS
        Writes one line to the console and the run log.
    .DESCRIPTION
        Segment is a list of strings, or of hashtables with Text and Color.
        Each piece is sanitised. With colour on, information lines on
        screen and a coloured piece in the line, it goes out through
        Write-Host one piece at a time, so only that piece is coloured, and
        each piece is its own information record. Otherwise it goes out as
        one plain Write-Information record. NoLog leaves it out of the log.

        Write-Host isn't used in quiet mode, since it prints even when
        asked not to, so -InformationAction SilentlyContinue always hides
        every line.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'The only way to colour part of a line on 5.1 and 7. Used only while information lines are shown, with InformationAction passed, so the lines still reach -InformationVariable.')]
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [object[]]$Segment = @(),

        [switch]$NoLog
    )

    $parts = New-Object System.Collections.Generic.List[object]
    foreach ($s in $Segment) {
        if ($s -is [System.Collections.IDictionary]) {
            $parts.Add(@{ Text = (ConvertTo-ConsoleText -Text $s['Text'] -MaxLength $script:ConsoleLineMaxLength); Color = $s['Color'] })
        }
        else {
            $parts.Add(@{ Text = (ConvertTo-ConsoleText -Text $s -MaxLength $script:ConsoleLineMaxLength); Color = $null })
        }
    }
    $plain = -join @($parts | ForEach-Object { $_.Text })
    if (-not $NoLog) {
        Write-ConsoleLogLine -Text $plain.TrimEnd()
    }
    $state = Get-ConsoleState
    $colored = $state.Color -and (@($parts | Where-Object { $null -ne $_.Color }).Count -gt 0) -and (Test-ConsoleInformationShown)
    if (-not $colored) {
        Write-Information -MessageData $plain.TrimEnd()
        return
    }
    for ($i = 0; $i -lt $parts.Count; $i++) {
        $piece = @{
            Object            = $parts[$i].Text
            NoNewline         = ($i -lt $parts.Count - 1)
            InformationAction = 'Continue'
        }
        if ($null -ne $parts[$i].Color) {
            $piece.ForegroundColor = $parts[$i].Color
        }
        Write-Host @piece
    }
}

function Write-RunWarning {
    <#
    .SYNOPSIS
        A warning that also goes in the run log, prefixed WARNING.
    .DESCRIPTION
        The text is sanitised first, since a warning can carry a value from
        the evidence, then written with Write-Warning, so -WarningVariable
        and -WarningAction work as they always have.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message
    )

    $text = ConvertTo-ConsoleText -Text $Message -MaxLength $script:ConsoleLineMaxLength
    Write-ConsoleLogLine -Text "WARNING $text"
    Write-Warning $text
}

function Write-HeldWarning {
    <#
    .SYNOPSIS
        Writes warnings that were recorded but not shown, for a run that
        stops before it gets to show them.
    .DESCRIPTION
        Each one goes through Write-RunWarning, so it's sanitised and goes
        in the run log. A warning that can't be written, as with
        -WarningAction Stop, is passed over, so the error that stopped the
        run is the one the caller sees.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Record
    )

    foreach ($r in @($Record | Where-Object { $null -ne $_ })) {
        $message = $r
        if ($r -is [System.Management.Automation.WarningRecord]) {
            $message = $r.Message
        }
        try {
            Write-RunWarning -Message ([string]$message)
        }
        catch {
            Write-Verbose 'A held warning could not be written.'
        }
    }
}

function Write-ConsoleHeader {
    <#
    .SYNOPSIS
        The run header, a title line then one labelled line per field.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Title,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Field
    )

    Write-ConsoleLine -Segment @($Title)
    foreach ($k in $Field.Keys) {
        Write-ConsoleLine -Segment @(([string]$k).PadRight($script:ConsoleLabelWidth), [string]$Field[$k])
    }
}

function Write-ConsoleSection {
    # A blank line, then the section's title.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Title
    )

    Write-ConsoleLine -Segment @('') -NoLog
    Write-ConsoleLine -Segment @($Title)
}

function Split-ConsoleWrap {
    # Breaks text into lines no wider than Width, at spaces.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [string]$Text,

        [Parameter(Mandatory)]
        [int]$Width
    )

    $Width = [math]::Max(20, $Width)
    $lines = New-Object System.Collections.Generic.List[string]
    $current = ''
    foreach ($word in ($Text -split ' ')) {
        if ($word.Length -eq 0) {
            continue
        }
        while ($word.Length -gt $Width) {
            if ($current.Length -gt 0) {
                $lines.Add($current)
                $current = ''
            }
            $lines.Add($word.Substring(0, $Width))
            $word = $word.Substring($Width)
        }
        if ($current.Length -eq 0) {
            $current = $word
        }
        elseif ($current.Length + 1 + $word.Length -le $Width) {
            $current = "$current $word"
        }
        else {
            $lines.Add($current)
            $current = $word
        }
    }
    if ($current.Length -gt 0 -or $lines.Count -eq 0) {
        $lines.Add($current)
    }
    foreach ($line in $lines) {
        $line
    }
}

function Write-ConsoleNote {
    <#
    .SYNOPSIS
        A note under a section, indented, with long text wrapped under it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text,

        [int]$Indent = 2,

        [string]$Marker = ''
    )

    $clean = ConvertTo-ConsoleText -Text $Text -MaxLength $script:ConsoleLineMaxLength
    $first = (' ' * $Indent) + $Marker
    $rest = ' ' * ($Indent + $Marker.Length)
    $lines = @(Split-ConsoleWrap -Text $clean -Width ((Get-ConsoleUsableWidth) - $first.Length))
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $lead = $rest
        if ($i -eq 0) {
            $lead = $first
        }
        Write-ConsoleLine -Segment @($lead + $lines[$i])
    }
}

function Write-ConsoleNotice {
    <#
    .SYNOPSIS
        A warning shown as a "!" note before the run.
    .DESCRIPTION
        The warning text goes in the run log. When information lines are
        on screen, the short Display text is shown as a note and the
        warning is recorded without being shown, so -WarningVariable still
        has it and nothing is said twice. When they're hidden, as with
        -InformationAction SilentlyContinue, the warning is shown as one.
        Recorded is for a warning already written, such as one from
        discovery, which then only goes in the log and the note.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Warning,

        [AllowEmptyString()]
        [string]$Display,

        [switch]$Recorded
    )

    $text = ConvertTo-ConsoleText -Text $Warning -MaxLength $script:ConsoleLineMaxLength
    if ([string]::IsNullOrEmpty($Display)) {
        $Display = $text
    }
    Write-ConsoleLogLine -Text "WARNING $text"
    if (Test-ConsoleInformationShown) {
        $clean = ConvertTo-ConsoleText -Text $Display -MaxLength $script:ConsoleLineMaxLength
        $lines = @(Split-ConsoleWrap -Text $clean -Width ((Get-ConsoleUsableWidth) - 4))
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $lead = '    '
            if ($i -eq 0) {
                $lead = '  ! '
            }
            Write-ConsoleLine -Segment @($lead + $lines[$i]) -NoLog
        }
        if (-not $Recorded) {
            Write-Warning $text -WarningAction SilentlyContinue
        }
    }
    elseif (-not $Recorded) {
        Write-Warning $text
    }
}

function Write-ConsoleProgress {
    # Write-Progress, at most once per interval unless Force, and not at
    # all when progress is turned off.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$Id,

        [Parameter(Mandatory)]
        [string]$Activity,

        [string]$Status = ' ',

        [int]$Percent = -1,

        [int]$ParentId = -1,

        [switch]$Force
    )

    $p = [string]$ProgressPreference
    if ($p -eq 'SilentlyContinue' -or $p -eq 'Ignore') {
        return
    }
    $state = Get-ConsoleState
    $now = $state.ProgressWatch.ElapsedMilliseconds
    if (-not $Force -and ($now - $state.LastProgress) -lt $script:ConsoleProgressIntervalMs) {
        return
    }
    $state.LastProgress = $now
    $width = (Get-ConsoleUsableWidth) - 10
    $progress = @{
        Id       = $Id
        Activity = (Format-ConsoleEnd -Text (ConvertTo-ConsoleText -Text $Activity) -Width $width)
        Status   = (Format-ConsoleEnd -Text (ConvertTo-ConsoleText -Text $Status) -Width $width)
    }
    if ([string]::IsNullOrEmpty($progress.Status)) {
        $progress.Status = ' '
    }
    if ($Percent -ge 0) {
        $progress.PercentComplete = [math]::Min(100, $Percent)
    }
    if ($ParentId -ge 0) {
        $progress.ParentId = $ParentId
    }
    try {
        Write-Progress @progress
    }
    catch {
        Write-Verbose "Could not show progress: $($_.Exception.Message)"
    }
}

function Complete-ConsoleProgress {
    # Takes both progress bars down. Safe to call at any time.
    [CmdletBinding()]
    param()

    foreach ($id in @(2, 1)) {
        try {
            Write-Progress -Id $id -Activity 'Hayabusa-Bulk-Runner' -Completed
        }
        catch {
            Write-Verbose "Could not clear progress: $($_.Exception.Message)"
        }
    }
}

function Get-ConsoleCollectionDetail {
    # What a host is, for its header, a folder or a ZIP or the image type and size.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Collection
    )

    switch ([string]$Collection.InputType) {
        'Loose' {
            return 'folder'
        }
        'Zip' {
            $zip = $null
            if ($null -ne $Collection.PSObject.Properties['Zip']) {
                $zip = $Collection.Zip
            }
            if ($null -ne $zip -and $null -ne $zip.PSObject.Properties['ImageEntries'] -and @($zip.ImageEntries).Count -gt 0) {
                return 'ZIP holding a disk image'
            }
            return 'ZIP'
        }
        default {
            $type = ([string]$Collection.InputType).ToUpperInvariant()
            try {
                $size = (Get-Item -LiteralPath $Collection.SourcePath -Force).Length
                return "$type, $(Format-ConsoleByteSize -Bytes $size)"
            }
            catch {
                return $type
            }
        }
    }
}

function Start-ConsoleHost {
    <#
    .SYNOPSIS
        Writes a host's header line as it starts, and its progress bar.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Writes console output and progress only.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$Index,

        [Parameter(Mandatory)]
        [int]$Total,

        [Parameter(Mandatory)]
        [string]$Name,

        [AllowEmptyString()]
        [string]$Detail = ''
    )

    $state = Get-ConsoleState
    $state.Step = $null
    $clean = ConvertTo-ConsoleText -Text $Name
    $prefix = "[$Index/$Total] "
    $room = (Get-ConsoleUsableWidth) - $prefix.Length - $Detail.Length - 2
    $shown = Format-ConsoleMiddle -Text $clean -Width ([math]::Max(12, $room))
    $state.Host = @{
        Index      = $Index
        Total      = $Total
        Name       = $clean
        Watch      = [System.Diagnostics.Stopwatch]::StartNew()
        FailedStep = $false
    }
    $line = $prefix + $shown
    if ($Detail.Length -gt 0) {
        $line += "  $Detail"
    }
    Write-ConsoleLine -Segment @($line)
    Write-ConsoleProgress -Id 1 -Activity "Host $Index of $Total, $clean" -Status 'Starting' -Force
}

function Write-ConsoleSkip {
    # One line for a host that isn't run, such as one already finished.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$Index,

        [Parameter(Mandatory)]
        [int]$Total,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Text
    )

    $shown = Format-ConsoleMiddle -Text (ConvertTo-ConsoleText -Text $Name) -Width ([math]::Max(12, (Get-ConsoleUsableWidth) - $Text.Length - 12))
    Write-ConsoleLine -Segment (@("[$Index/$Total] $shown  ") + @(Split-ConsoleStatus -Text $Text))
}

function Start-ConsoleStep {
    <#
    .SYNOPSIS
        Starts timing a step and shows it in the progress bars.
    .DESCRIPTION
        Its line is written when it finishes, by Complete-ConsoleStep. A
        step still open when the next one starts is closed as failed.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Writes console output and progress only.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    $state = Get-ConsoleState
    if ($null -ne $state.Step) {
        Complete-ConsoleStep -Failed
    }
    $state.Step = @{
        Name  = $Name
        Watch = [System.Diagnostics.Stopwatch]::StartNew()
    }
    $activity = $Name
    if ($null -ne $state.Host) {
        $activity = "Host $($state.Host.Index) of $($state.Host.Total), $($state.Host.Name)"
        Write-ConsoleProgress -Id 1 -Activity $activity -Status $Name -Force
    }
    Write-ConsoleProgress -Id 2 -ParentId 1 -Activity $Name -Status 'Starting' -Force
}

function Update-ConsoleStep {
    <#
    .SYNOPSIS
        Updates the current step's progress bar, at most four times a
        second.
    .DESCRIPTION
        With Done and Total, shows bytes done and the percent. With Elapsed,
        starts the status with the time the step has run. Does nothing when
        no step is open.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Writes console output and progress only.')]
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$Status = '',

        [long]$Done = -1,

        [long]$Total = -1,

        [switch]$Elapsed
    )

    $state = Get-ConsoleState
    if ($null -eq $state.Step) {
        return
    }
    if (($state.ProgressWatch.ElapsedMilliseconds - $state.LastProgress) -lt $script:ConsoleProgressIntervalMs) {
        return
    }
    $percent = -1
    $text = ConvertTo-ConsoleText -Text $Status
    if ($Done -ge 0 -and $Total -gt 0) {
        $percent = [int][math]::Floor(($Done * 100) / $Total)
        $text = "$(Format-ConsoleByteSize -Bytes $Done) of $(Format-ConsoleByteSize -Bytes $Total), $percent%"
    }
    if ($Elapsed) {
        $when = Format-ConsoleDuration -Seconds $state.Step.Watch.Elapsed.TotalSeconds
        if ($text.Length -gt 0) {
            $text = "$when, $text"
        }
        else {
            $text = $when
        }
    }
    Write-ConsoleProgress -Id 2 -ParentId 1 -Activity $state.Step.Name -Status $text -Percent $percent
}

function Format-ConsoleStepLine {
    <#
    .SYNOPSIS
        The pieces of a step line: indent and name, the result with its
        status word coloured, and the time right-aligned.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [AllowEmptyString()]
        [string]$Result,

        [Parameter(Mandatory)]
        [double]$Seconds,

        [int]$Width = (Get-ConsoleUsableWidth)
    )

    $lead = (' ' * $script:ConsoleStepIndent) + $Name.PadRight($script:ConsoleStepNameWidth - 1) + ' '
    $time = (Format-ConsoleDuration -Seconds $Seconds).PadLeft($script:ConsoleStepTimeWidth)
    $room = [math]::Max(10, $Width - $lead.Length - $time.Length)
    $text = Format-ConsoleEnd -Text (ConvertTo-ConsoleText -Text $Result) -Width $room
    $pad = ''
    if ($text.Length -lt $script:ConsoleStepResultWidth) {
        $pad = ' ' * ($script:ConsoleStepResultWidth - $text.Length)
    }
    $pieces = New-Object System.Collections.Generic.List[object]
    $pieces.Add($lead)
    foreach ($p in (Split-ConsoleStatus -Text $text)) {
        $pieces.Add($p)
    }
    $pieces.Add($pad + $time)
    return $pieces.ToArray()
}

function Complete-ConsoleStep {
    <#
    .SYNOPSIS
        Writes the current step's line with its result and time.
    .DESCRIPTION
        Failed writes "failed" with the short Reason. Does nothing when no
        step is open.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$Result = 'done',

        [switch]$Failed,

        [AllowEmptyString()]
        [string]$Reason = ''
    )

    $state = Get-ConsoleState
    if ($null -eq $state.Step) {
        return
    }
    $step = $state.Step
    $state.Step = $null
    $seconds = $step.Watch.Elapsed.TotalSeconds
    if ($Failed) {
        $Result = 'failed'
        $why = ConvertTo-ConsoleText -Text $Reason
        if ($why.Length -gt 0) {
            $Result = "failed, $why"
        }
        if ($null -ne $state.Host) {
            $state.Host.FailedStep = $true
        }
    }
    Write-ConsoleLine -Segment (Format-ConsoleStepLine -Name $step.Name -Result $Result -Seconds $seconds)
    try {
        Write-Progress -Id 2 -Activity $step.Name -Completed
    }
    catch {
        Write-Verbose "Could not clear progress: $($_.Exception.Message)"
    }
}

function Complete-ConsoleHost {
    <#
    .SYNOPSIS
        Writes a host's closing line, its status and how long it took, and
        takes its progress bars down.
    .DESCRIPTION
        Reason follows the status, as "Failed, ZIP not extracted". NoTime
        leaves the time out. A step still open is closed as failed first.
        Returns the host's time in seconds.
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory)]
        [string]$Status,

        [AllowEmptyString()]
        [string]$Reason = '',

        [switch]$NoTime
    )

    $state = Get-ConsoleState
    if ($null -ne $state.Step) {
        Complete-ConsoleStep -Failed
    }
    $seconds = 0.0
    if ($null -ne $state.Host) {
        $seconds = $state.Host.Watch.Elapsed.TotalSeconds
    }
    $tail = ''
    if (-not $NoTime) {
        $tail = " in $(Format-ConsoleDuration -Seconds $seconds)"
    }
    $why = ConvertTo-ConsoleText -Text $Reason
    if ($why.Length -gt 0) {
        $tail += ", $why"
    }
    $color = Get-ConsoleStatusColor -Word $Status
    Write-ConsoleLine -Segment @((' ' * $script:ConsoleStepIndent), @{ Text = $Status; Color = $color }, $tail)
    $state.Host = $null
    Complete-ConsoleProgress
    return $seconds
}

function Clear-ConsoleSummary {
    # Starts the summary table afresh, for a new batch.
    [CmdletBinding()]
    param()

    (Get-ConsoleState).Rows.Clear()
}

function Add-ConsoleSummaryRow {
    # One collection's row in the summary table.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Collection,

        [AllowEmptyString()]
        [string]$Status = '',

        [AllowNull()]
        [object]$Detections = $null,

        [AllowEmptyString()]
        [string]$Identity = '',

        [AllowEmptyString()]
        [string]$Computer = '',

        [AllowNull()]
        [object]$Seconds = $null
    )

    (Get-ConsoleState).Rows.Add([pscustomobject]@{
            Collection = (ConvertTo-ConsoleText -Text $Collection)
            Status     = (ConvertTo-ConsoleText -Text $Status)
            Detections = $Detections
            Identity   = (ConvertTo-ConsoleText -Text $Identity)
            Computer   = (ConvertTo-ConsoleText -Text $Computer)
            Seconds    = $Seconds
        })
}

function Get-ConsoleSummaryRow {
    # The summary rows recorded so far.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    foreach ($r in (Get-ConsoleState).Rows) {
        $r
    }
}

function Format-ConsoleTable {
    <#
    .SYNOPSIS
        The summary table as lines of pieces, header first, to fit Width.
    .DESCRIPTION
        Columns are Collection, then Status and Detections when ShowStatus
        is given, Identity and Computer when ShowIdentity is, and Time.
        Collection names are shortened in the middle so the table fits, and
        a computer name is cut at 24 characters. Status and Identity are
        coloured by their word.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Row,

        [switch]$ShowStatus,

        [switch]$ShowIdentity,

        [int]$Width = (Get-ConsoleUsableWidth)
    )

    $rows = @($Row)
    $columns = New-Object System.Collections.Generic.List[object]
    $columns.Add(@{ Name = 'Collection'; Key = 'Collection'; Right = $false; Color = $false; Max = 0 })
    if ($ShowStatus) {
        $columns.Add(@{ Name = 'Status'; Key = 'Status'; Right = $false; Color = $true; Max = 0 })
        $columns.Add(@{ Name = 'Detections'; Key = 'Detections'; Right = $true; Color = $false; Max = 0 })
    }
    if ($ShowIdentity) {
        $columns.Add(@{ Name = 'Identity'; Key = 'Identity'; Right = $false; Color = $true; Max = 0 })
        $columns.Add(@{ Name = 'Computer'; Key = 'Computer'; Right = $false; Color = $false; Max = 24 })
    }
    $columns.Add(@{ Name = 'Time'; Key = 'Seconds'; Right = $true; Color = $false; Max = 0 })

    $cell = {
        param($r, $c)
        $v = $r.($c.Key)
        if ($null -eq $v) {
            return ''
        }
        if ($c.Key -eq 'Seconds') {
            return (Format-ConsoleDuration -Seconds ([double]$v))
        }
        $t = [string]$v
        if ($c.Max -gt 0) {
            $t = Format-ConsoleEnd -Text $t -Width $c.Max
        }
        return $t
    }
    $cells = @(foreach ($r in $rows) {
            , @(foreach ($c in $columns) { & $cell $r $c })
        })

    $widths = New-Object int[] $columns.Count
    for ($i = 0; $i -lt $columns.Count; $i++) {
        $widths[$i] = $columns[$i].Name.Length
        foreach ($line in $cells) {
            $widths[$i] = [math]::Max($widths[$i], ([string]$line[$i]).Length)
        }
    }
    $indent = 2
    $gap = 2
    $others = 0
    for ($i = 1; $i -lt $columns.Count; $i++) {
        $others += $widths[$i] + $gap
    }
    # Collection names are cut only when the table wouldn't fit, and never
    # narrower than 12.
    $room = $Width - $indent - $others
    if ($widths[0] -gt $room) {
        $widths[0] = [math]::Max(12, $room)
    }

    $render = {
        param([string[]]$values, [bool]$isHeader)
        $pieces = New-Object System.Collections.Generic.List[object]
        $pieces.Add(' ' * $indent)
        for ($i = 0; $i -lt $columns.Count; $i++) {
            $v = [string]$values[$i]
            if ($i -eq 0) {
                $v = Format-ConsoleMiddle -Text $v -Width $widths[0]
            }
            $padded = $v.PadRight($widths[$i])
            if ($columns[$i].Right) {
                $padded = $v.PadLeft($widths[$i])
            }
            if ($i -lt $columns.Count - 1) {
                $padded += ' ' * $gap
            }
            $color = $null
            if (-not $isHeader -and $columns[$i].Color) {
                $color = Get-ConsoleStatusColor -Word $v
            }
            if ($null -ne $color) {
                $pieces.Add(@{ Text = $v; Color = $color })
                $pieces.Add($padded.Substring($v.Length))
            }
            else {
                $pieces.Add($padded)
            }
        }
        return , $pieces.ToArray()
    }

    $out = New-Object System.Collections.Generic.List[object]
    $out.Add((& $render @($columns | ForEach-Object { $_.Name }) $true))
    foreach ($line in $cells) {
        $out.Add((& $render $line $false))
    }
    return , $out.ToArray()
}

function Write-ConsoleSummary {
    # The summary section, one row per collection in this run.
    [CmdletBinding()]
    param(
        [switch]$ShowStatus,

        [switch]$ShowIdentity
    )

    Write-ConsoleSection -Title 'Summary'
    $rows = @(Get-ConsoleSummaryRow)
    if ($rows.Count -eq 0) {
        Write-ConsoleLine -Segment @('  No collections in this run.')
        return
    }
    foreach ($line in (Format-ConsoleTable -Row $rows -ShowStatus:$ShowStatus -ShowIdentity:$ShowIdentity)) {
        Write-ConsoleLine -Segment $line
    }
}

function Get-ConsoleRunLogPath {
    # The run log's path while it's being written, or null.
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $state = Get-ConsoleState
    if ($state.LogFailed -or ($null -eq $state.Log -and $null -eq $state.Pending)) {
        return $null
    }
    return $state.LogPath
}

function Get-ConsoleInputSummary {
    # "5 collections, 1 ZIP, 1 folder, 1 VHD, 2 VHDX", for the run header.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Collections
    )

    $all = @($Collections)
    $text = "$($all.Count) collections"
    if ($all.Count -eq 1) {
        $text = '1 collection'
    }
    $kinds = @(
        @{ Type = 'Zip'; One = 'ZIP'; Many = 'ZIPs' }
        @{ Type = 'Loose'; One = 'folder'; Many = 'folders' }
        @{ Type = 'Vhd'; One = 'VHD'; Many = 'VHDs' }
        @{ Type = 'Vhdx'; One = 'VHDX'; Many = 'VHDX' }
    )
    foreach ($k in $kinds) {
        $n = @($all | Where-Object { $_.InputType -eq $k.Type }).Count
        if ($n -eq 1) {
            $text += ", 1 $($k.One)"
        }
        elseif ($n -gt 1) {
            $text += ", $n $($k.Many)"
        }
    }
    return $text
}
