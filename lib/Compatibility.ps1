# Hayabusa compatibility self-test. Builds a tiny event log at run time,
# runs the binary over it with the exact arguments New-HayabusaArgument
# builds for real runs, and checks what the rollup relies on: the flags are
# accepted and applied, the CSV has the columns it reads, and every Level
# maps to one of the six known severities.

# Columns the rollup reads from a Hayabusa CSV.
$script:CompatibilityRequiredColumns = @('Level', 'Computer', 'RuleTitle')

# The sample is one Security 1102 (audit log cleared) event. Hayabusa's own
# stable rule "Log Cleared" (Sec_1102_High_SecLogCleared.yml, level high,
# tag attack.defense-evasion) matches on Channel and EventID alone, so the
# sample trips one detection with any Hayabusa rule set.
$script:CompatibilitySampleComputer = 'COMPAT-TEST'
$script:CompatibilitySampleTimeUtc = '2026-01-15T12:00:00.0000000Z'
$script:CompatibilitySampleTag = 'attack.defense-evasion'

# A tag the sample's rule doesn't carry, so including only it must drop the
# sample's detection.
$script:CompatibilityOtherTag = 'attack.impact'

# The time window passed in the check, with the sample event inside it.
$script:CompatibilityTimelineStart = '2026-01-01 00:00:00 +00:00'
$script:CompatibilityTimelineEnd = '2026-12-31 23:59:59 +00:00'

# Reversed IEEE polynomial 0xEDB88320, written in decimal because a hex
# literal that large is a negative Int32 in PowerShell.
$script:Crc32Polynomial = [uint32]3988292384
$script:Crc32Table = $null

function Get-Crc32 {
    <#
    .SYNOPSIS
        CRC-32 (IEEE 802.3) of a byte range, as EVTX headers use.
    #>
    [CmdletBinding()]
    [OutputType([uint32])]
    param(
        [Parameter(Mandatory)]
        [byte[]]$Bytes,

        [int]$Offset = 0,

        [int]$Count = -1
    )

    if ($null -eq $script:Crc32Table) {
        $table = New-Object 'uint32[]' 256
        for ($n = 0; $n -lt 256; $n++) {
            [uint32]$c = $n
            for ($k = 0; $k -lt 8; $k++) {
                if (($c -band 1) -ne 0) {
                    $c = [uint32]($script:Crc32Polynomial -bxor ($c -shr 1))
                }
                else {
                    $c = [uint32]($c -shr 1)
                }
            }
            $table[$n] = $c
        }
        $script:Crc32Table = $table
    }

    if ($Count -lt 0) {
        $Count = $Bytes.Length - $Offset
    }
    [uint32]$crc = [uint32]::MaxValue
    $end = $Offset + $Count
    for ($i = $Offset; $i -lt $end; $i++) {
        $crc = [uint32]($script:Crc32Table[($crc -bxor $Bytes[$i]) -band 0xFF] -bxor ($crc -shr 8))
    }
    return [uint32]($crc -bxor [uint32]::MaxValue)
}

function Add-EvtxByte {
    # Appends bytes to a list. Callers pass integers through BitConverter,
    # which is little-endian on every platform PowerShell runs on.
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[byte]]$Buffer,

        [Parameter(Mandatory)]
        [byte[]]$Bytes
    )

    $Buffer.AddRange($Bytes)
}

function Write-EvtxUInt32 {
    # Overwrites four bytes at Offset with a little-endian value.
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[byte]]$Buffer,

        [Parameter(Mandatory)]
        [int]$Offset,

        [Parameter(Mandatory)]
        [uint32]$Value
    )

    $b = [BitConverter]::GetBytes($Value)
    for ($i = 0; $i -lt 4; $i++) {
        $Buffer[$Offset + $i] = $b[$i]
    }
}

function Add-EvtxName {
    # A name reference followed by the name itself, inline. The reference
    # points at the bytes right after it, which is how a name is defined the
    # first time a chunk uses it.
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[byte]]$Buffer,

        [Parameter(Mandatory)]
        [string]$Name
    )

    Add-EvtxByte $Buffer ([BitConverter]::GetBytes([uint32]($Buffer.Count + 4)))
    Add-EvtxByte $Buffer ([BitConverter]::GetBytes([uint32]0))
    Add-EvtxByte $Buffer ([BitConverter]::GetBytes([uint16]0))
    Add-EvtxByte $Buffer ([BitConverter]::GetBytes([uint16]$Name.Length))
    Add-EvtxByte $Buffer ([System.Text.Encoding]::Unicode.GetBytes($Name))
    Add-EvtxByte $Buffer ([byte[]](0, 0))
}

function Add-EvtxText {
    # A value token holding a UTF-16 string.
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[byte]]$Buffer,

        [Parameter(Mandatory)]
        [string]$Text
    )

    Add-EvtxByte $Buffer ([byte[]](0x05, 0x01))
    Add-EvtxByte $Buffer ([BitConverter]::GetBytes([uint16]$Text.Length))
    Add-EvtxByte $Buffer ([System.Text.Encoding]::Unicode.GetBytes($Text))
}

function Add-EvtxElement {
    <#
    .SYNOPSIS
        Appends one BinXML element, written out in full rather than through
        a template.
    .DESCRIPTION
        Attributes is an ordered dictionary of name to string value. Content
        is a string, or an array of hashtables with Name, Attributes and
        Content for child elements, or null for an empty element.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[byte]]$Buffer,

        [Parameter(Mandatory)]
        [string]$Name,

        [System.Collections.IDictionary]$Attributes = @{},

        [object]$Content = $null
    )

    $hasAttributes = $Attributes.Count -gt 0
    if ($hasAttributes) {
        Add-EvtxByte $Buffer ([byte[]](0x41))
    }
    else {
        Add-EvtxByte $Buffer ([byte[]](0x01))
    }
    Add-EvtxByte $Buffer ([BitConverter]::GetBytes([uint16]0xFFFF))
    $sizeAt = $Buffer.Count
    Add-EvtxByte $Buffer ([BitConverter]::GetBytes([uint32]0))
    Add-EvtxName $Buffer $Name

    if ($hasAttributes) {
        $listSizeAt = $Buffer.Count
        Add-EvtxByte $Buffer ([BitConverter]::GetBytes([uint32]0))
        $keys = @($Attributes.Keys)
        for ($i = 0; $i -lt $keys.Count; $i++) {
            if ($i -lt $keys.Count - 1) {
                Add-EvtxByte $Buffer ([byte[]](0x46))
            }
            else {
                Add-EvtxByte $Buffer ([byte[]](0x06))
            }
            Add-EvtxName $Buffer ([string]$keys[$i])
            Add-EvtxText $Buffer ([string]$Attributes[$keys[$i]])
        }
        Write-EvtxUInt32 -Buffer $Buffer -Offset $listSizeAt -Value ([uint32]($Buffer.Count - $listSizeAt - 4))
    }

    if ($null -eq $Content) {
        Add-EvtxByte $Buffer ([byte[]](0x03))
    }
    else {
        Add-EvtxByte $Buffer ([byte[]](0x02))
        if ($Content -is [string]) {
            Add-EvtxText $Buffer $Content
        }
        else {
            foreach ($child in @($Content)) {
                $childAttributes = @{}
                if ($child.ContainsKey('Attributes')) {
                    $childAttributes = $child['Attributes']
                }
                Add-EvtxElement -Buffer $Buffer -Name $child['Name'] -Attributes $childAttributes -Content $child['Content']
            }
        }
        Add-EvtxByte $Buffer ([byte[]](0x04))
    }

    Write-EvtxUInt32 -Buffer $Buffer -Offset $sizeAt -Value ([uint32]($Buffer.Count - $sizeAt - 4))
}

function New-CompatibilitySampleEvtx {
    <#
    .SYNOPSIS
        Writes a one-event .evtx file for the compatibility check.
    .DESCRIPTION
        Builds the file byte by byte: the 4096-byte file header, one
        65536-byte chunk, and a single record whose BinXML spells out each
        element and value in full, with no templates. Both headers and the
        record data carry correct CRC-32 checksums. Built in memory, so no
        event log service, registered provider or elevation is needed, and
        the same bytes come out on every machine.

        The event is Security 1102 from COMPAT-TEST at 2026-01-15 12:00 UTC,
        which Hayabusa's "Log Cleared" rule detects at level high.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Writes a new file in a working folder the caller owns.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $chunkSize = 65536
    $chunkHeaderSize = 512
    $time = [datetime]::Parse($script:CompatibilitySampleTimeUtc, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal)

    # The chunk is built in a list whose index is the offset from the chunk
    # start, because name references are chunk offsets.
    $chunk = New-Object System.Collections.Generic.List[byte]
    Add-EvtxByte $chunk (New-Object byte[] $chunkHeaderSize)

    $recordStart = $chunk.Count
    Add-EvtxByte $chunk ([byte[]](0x2A, 0x2A, 0x00, 0x00))
    $recordSizeAt = $chunk.Count
    Add-EvtxByte $chunk ([BitConverter]::GetBytes([uint32]0))
    Add-EvtxByte $chunk ([BitConverter]::GetBytes([uint64]1))
    Add-EvtxByte $chunk ([BitConverter]::GetBytes([int64]$time.ToFileTimeUtc()))

    # Fragment header, then <Event>.
    Add-EvtxByte $chunk ([byte[]](0x0F, 0x01, 0x01, 0x00))
    $system = @(
        @{ Name = 'Provider'; Attributes = [ordered]@{ Name = 'Microsoft-Windows-Eventlog'; Guid = '{fc65ddd8-d6ef-4962-83d5-6e5cfe9ce148}' } }
        @{ Name = 'EventID'; Content = '1102' }
        @{ Name = 'Version'; Content = '0' }
        @{ Name = 'Level'; Content = '4' }
        @{ Name = 'Task'; Content = '104' }
        @{ Name = 'Opcode'; Content = '0' }
        @{ Name = 'Keywords'; Content = '0x4020000000000000' }
        @{ Name = 'TimeCreated'; Attributes = [ordered]@{ SystemTime = $script:CompatibilitySampleTimeUtc } }
        @{ Name = 'EventRecordID'; Content = '1' }
        @{ Name = 'Correlation' }
        @{ Name = 'Execution'; Attributes = [ordered]@{ ProcessID = '4'; ThreadID = '8' } }
        @{ Name = 'Channel'; Content = 'Security' }
        @{ Name = 'Computer'; Content = $script:CompatibilitySampleComputer }
        @{ Name = 'Security' }
    )
    $userData = @(
        @{ Name = 'LogFileCleared'; Attributes = [ordered]@{ xmlns = 'http://manifests.microsoft.com/win/2004/08/windows/eventlog' }; Content = @(
                @{ Name = 'SubjectUserSid'; Content = 'S-1-5-18' }
                @{ Name = 'SubjectUserName'; Content = 'compat' }
                @{ Name = 'SubjectDomainName'; Content = 'COMPAT' }
                @{ Name = 'SubjectLogonId'; Content = '0x3e7' }
            )
        }
    )
    Add-EvtxElement -Buffer $chunk -Name 'Event' -Attributes ([ordered]@{ xmlns = 'http://schemas.microsoft.com/win/2004/08/events/event' }) -Content @(
        @{ Name = 'System'; Content = $system }
        @{ Name = 'UserData'; Content = $userData }
    )
    Add-EvtxByte $chunk ([byte[]](0x00))

    # The record ends with a copy of its size.
    $recordSize = [uint32]($chunk.Count - $recordStart + 4)
    Add-EvtxByte $chunk ([BitConverter]::GetBytes($recordSize))
    Write-EvtxUInt32 -Buffer $chunk -Offset $recordSizeAt -Value $recordSize
    $freeSpace = $chunk.Count
    if ($freeSpace -gt $chunkSize) {
        throw 'The sample event does not fit in one chunk.'
    }
    Add-EvtxByte $chunk (New-Object byte[] ($chunkSize - $freeSpace))
    $c = $chunk.ToArray()

    # Chunk header.
    [System.Text.Encoding]::ASCII.GetBytes("ElfChnk`0").CopyTo($c, 0)
    foreach ($at in 8, 16, 24, 32) {
        [BitConverter]::GetBytes([uint64]1).CopyTo($c, $at)
    }
    [BitConverter]::GetBytes([uint32]128).CopyTo($c, 40)
    [BitConverter]::GetBytes([uint32]$recordStart).CopyTo($c, 44)
    [BitConverter]::GetBytes([uint32]$freeSpace).CopyTo($c, 48)
    [BitConverter]::GetBytes((Get-Crc32 -Bytes $c -Offset $chunkHeaderSize -Count ($freeSpace - $chunkHeaderSize))).CopyTo($c, 52)
    $headerBytes = New-Object byte[] (120 + $chunkHeaderSize - 128)
    [System.Array]::Copy($c, 0, $headerBytes, 0, 120)
    [System.Array]::Copy($c, 128, $headerBytes, 120, $chunkHeaderSize - 128)
    [BitConverter]::GetBytes((Get-Crc32 -Bytes $headerBytes)).CopyTo($c, 124)

    # File header.
    $f = New-Object byte[] 4096
    [System.Text.Encoding]::ASCII.GetBytes("ElfFile`0").CopyTo($f, 0)
    [BitConverter]::GetBytes([uint64]0).CopyTo($f, 8)
    [BitConverter]::GetBytes([uint64]0).CopyTo($f, 16)
    [BitConverter]::GetBytes([uint64]2).CopyTo($f, 24)
    [BitConverter]::GetBytes([uint32]128).CopyTo($f, 32)
    [BitConverter]::GetBytes([uint16]1).CopyTo($f, 36)
    [BitConverter]::GetBytes([uint16]3).CopyTo($f, 38)
    [BitConverter]::GetBytes([uint16]4096).CopyTo($f, 40)
    [BitConverter]::GetBytes([uint16]1).CopyTo($f, 42)
    [BitConverter]::GetBytes((Get-Crc32 -Bytes $f -Offset 0 -Count 120)).CopyTo($f, 124)

    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::CreateNew)
    try {
        $stream.Write($f, 0, $f.Length)
        $stream.Write($c, 0, $c.Length)
    }
    finally {
        $stream.Dispose()
    }
    return $Path
}

function Get-HayabusaArgumentFlag {
    <#
    .SYNOPSIS
        Lists every flag New-HayabusaArgument can emit, read from its own
        code.
    .DESCRIPTION
        Takes each string literal in New-HayabusaArgument that looks like a
        flag. Reading the function, rather than keeping a second list here,
        means a flag added there is one this check notices it has not sent.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    $ast = (Get-Command -Name New-HayabusaArgument -CommandType Function).ScriptBlock.Ast
    $strings = $ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.StringConstantExpressionAst]
        }, $true)
    $flags = @($strings | ForEach-Object { $_.Value } | Where-Object { $_ -cmatch '^--?[A-Za-z][A-Za-z-]*$' } | Select-Object -Unique)
    return [string[]]$flags
}

function New-CompatibilityCheck {
    # One line of the report.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory object only.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [bool]$Passed,

        [Parameter(Mandatory)]
        [string]$Detail
    )

    [pscustomobject]@{
        Name   = $Name
        Passed = $Passed
        Detail = $Detail
    }
}

function Get-CompatibilityRunPlan {
    <#
    .SYNOPSIS
        The Hayabusa runs the check makes, between them sending every flag
        New-HayabusaArgument can emit.
    .DESCRIPTION
        baseline       the flags every run sends, with -m, --threads and
                       the time window around the sample event
        exact-tag      -e high and --include-tag with the sample's tag,
                       with the verbose profile
        exact-level    -e critical, a level the sample's detection isn't
        include-other  --include-tag with a tag the sample's rule lacks
        exclude-tag    --exclude-tag with the sample's tag

        Hayabusa 4.1.0 refuses -m with -e and --include-tag with
        --exclude-tag, so three runs is the fewest that send every flag.
        The first two must detect the sample, since Hayabusa 4.1.0 writes an
        empty CSV, with no header row, when it detects nothing. The last
        three must detect nothing, which shows each filter is applied and
        not just accepted. Filter names the flag that should drop the
        sample in each of those.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$RulesPath
    )

    $runs = @(
        @{ Name = 'baseline'; ExpectDetection = $true; Filter = ''; Threads = 1; Over = @{ MinLevel = 'informational'; TimelineStart = $script:CompatibilityTimelineStart; TimelineEnd = $script:CompatibilityTimelineEnd } }
        @{ Name = 'exact-tag'; ExpectDetection = $true; Filter = ''; Threads = $null; Over = @{ ExactLevel = 'high'; IncludeTags = [string[]]@($script:CompatibilitySampleTag); Profile = 'verbose' } }
        @{ Name = 'exact-level'; ExpectDetection = $false; Filter = '-e critical'; Threads = $null; Over = @{ ExactLevel = 'critical' } }
        @{ Name = 'include-other'; ExpectDetection = $false; Filter = "--include-tag $script:CompatibilityOtherTag"; Threads = $null; Over = @{ MinLevel = 'high'; IncludeTags = [string[]]@($script:CompatibilityOtherTag) } }
        @{ Name = 'exclude-tag'; ExpectDetection = $false; Filter = "--exclude-tag $script:CompatibilitySampleTag"; Threads = $null; Over = @{ MinLevel = 'high'; ExcludeTags = [string[]]@($script:CompatibilitySampleTag) } }
    )
    foreach ($run in $runs) {
        # The same keys Resolve-RunSetting gives a real run's Selection.
        $selection = [ordered]@{
            RulesPath     = $RulesPath
            MinLevel      = $null
            ExactLevel    = $null
            IncludeTags   = [string[]]@()
            ExcludeTags   = [string[]]@()
            TimelineStart = $null
            TimelineEnd   = $null
            Profile       = 'standard'
        }
        foreach ($k in $run.Over.Keys) {
            $selection[$k] = $run.Over[$k]
        }
        [pscustomobject]@{
            Name            = $run.Name
            ExpectDetection = $run.ExpectDetection
            Filter          = $run.Filter
            Threads         = $run.Threads
            Selection       = $selection
        }
    }
}

function Get-HayabusaRejection {
    <#
    .SYNOPSIS
        Says what Hayabusa refused, from the stderr lines in a run's log.
    .DESCRIPTION
        Hayabusa parses its command line with clap, which names the
        argument it refused and, for a near miss, the one it expected.
        Those messages become one line naming the flag, subcommand or
        value. Anything else is returned as the stderr text itself, so the
        reason is never lost.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$StderrLine
    )

    # PowerShell 7 records a blank native stderr line as the name of the
    # exception type, so those are dropped with the blank ones.
    $text = @($StderrLine | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_.Length -gt 0 -and $_ -ne 'System.Management.Automation.RemoteException' })
    $patterns = @(
        [pscustomobject]@{ Match = "unexpected argument '([^']+)'"; Say = 'Hayabusa rejected the flag {0}' }
        [pscustomobject]@{ Match = "unrecognized subcommand '([^']+)'"; Say = 'Hayabusa rejected the subcommand {0}' }
        [pscustomobject]@{ Match = "invalid value '([^']*)' for '([^']+)'"; Say = "Hayabusa rejected the value '{0}' for {1}" }
        [pscustomobject]@{ Match = "the argument '([^']+)' cannot be used with '([^']+)'"; Say = 'Hayabusa refused {0} together with {1}' }
    )
    $reason = $null
    foreach ($line in $text) {
        foreach ($p in $patterns) {
            $m = [regex]::Match($line, $p.Match)
            if ($m.Success) {
                $values = @($m.Groups | Select-Object -Skip 1 | ForEach-Object { $_.Value })
                $reason = $p.Say -f $values
                break
            }
        }
        if ($null -ne $reason) {
            break
        }
    }
    if ($null -eq $reason) {
        if ($text.Count -gt 0) {
            return (@($text | Select-Object -First 5) -join ' / ')
        }
        return 'Hayabusa wrote nothing to stderr'
    }

    foreach ($line in $text) {
        $tip = [regex]::Match($line, "a similar (?:argument|subcommand|value) exists: '([^']+)'")
        if ($tip.Success) {
            return "$reason (it suggests $($tip.Groups[1].Value))"
        }
    }
    return $reason
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

function Test-CompatibilityRun {
    <#
    .SYNOPSIS
        Judges one Hayabusa run of the check from its exit code, CSV and log.
    .DESCRIPTION
        Returns a "run" check, and a "columns" check when there is a CSV
        header to read or the run was expected to detect the sample.

        A non-zero exit is a possible compatibility break: the check names
        the flag, subcommand or value Hayabusa refused, from stderr in the
        log. Exit 0 with an empty CSV is a clean run with no detections,
        which is what Hayabusa 4.1.0 writes when nothing matches. A run
        expected to detect nothing that still detects the sample fails,
        because the filter in Filter was accepted but not applied. Exit 0
        with no CSV at all is a failure, because the tool counts a missing
        CSV as a failed host.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [int]$ExitCode,

        [Parameter(Mandatory)]
        [string]$CsvPath,

        [Parameter(Mandatory)]
        [string]$LogPath,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Flag,

        [bool]$ExpectDetection = $false,

        [AllowEmptyString()]
        [string]$Filter = ''
    )

    $sent = $Flag -join ' '
    $hasCsv = Test-Path -LiteralPath $CsvPath -PathType Leaf
    $header = @()
    $rows = 0
    if ($hasCsv) {
        $header = @(Get-CsvHeader -Path $CsvPath)
        if ($header.Count -gt 0) {
            $rows = @(Import-Csv -LiteralPath $CsvPath -Encoding UTF8).Count
        }
    }

    if ($ExitCode -ne 0) {
        $stderr = @(Get-HayabusaLogStderr -LogPath $LogPath)
        $reason = (Get-HayabusaRejection -StderrLine $stderr).TrimEnd('.')
        New-CompatibilityCheck -Name "run $Name" -Passed $false -Detail "exit code $ExitCode, possible compatibility break. $reason. Flags sent: $sent. Log: $LogPath"
    }
    elseif (-not $hasCsv) {
        New-CompatibilityCheck -Name "run $Name" -Passed $false -Detail "exit code 0 but no CSV was written at $CsvPath. The tool treats a missing CSV as a failed host. Log: $LogPath"
    }
    elseif ($ExpectDetection -and $rows -eq 0) {
        New-CompatibilityCheck -Name "run $Name" -Passed $false -Detail "accepted, but the sample's 'Log Cleared' detection did not fire, so there is no CSV header to check. Flags sent: $sent"
    }
    elseif (-not $ExpectDetection -and $rows -gt 0) {
        $what = 'the filter'
        if (-not [string]::IsNullOrEmpty($Filter)) {
            $what = $Filter
        }
        New-CompatibilityCheck -Name "run $Name" -Passed $false -Detail "accepted, but the sample was still detected ($rows detection(s)), so $what was not applied. Flags sent: $sent"
    }
    elseif ($rows -eq 0) {
        New-CompatibilityCheck -Name "run $Name" -Passed $true -Detail "accepted, no detections (empty CSV). Flags sent: $sent"
    }
    else {
        New-CompatibilityCheck -Name "run $Name" -Passed $true -Detail "accepted, $rows detection(s). Flags sent: $sent"
    }

    if ($header.Count -gt 0) {
        $missing = @($script:CompatibilityRequiredColumns | Where-Object { $header -notcontains $_ })
        if ($missing.Count -gt 0) {
            New-CompatibilityCheck -Name "columns $Name" -Passed $false -Detail "missing column(s) $($missing -join ', '). The CSV has: $($header -join ', ')"
        }
        else {
            New-CompatibilityCheck -Name "columns $Name" -Passed $true -Detail "$($script:CompatibilityRequiredColumns -join ', ') present"
        }
    }
}

function Test-CompatibilityLevel {
    <#
    .SYNOPSIS
        Checks every Level value in the runs' CSVs maps to a known severity.
    .DESCRIPTION
        Each distinct value goes through ConvertTo-SeverityName, the same
        mapping the rollup uses. A value that does not come out as one of
        the six severities is a renamed or new level, and is named. No
        Level values at all is a failure too, since then nothing was
        checked.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$CsvPath
    )

    $known = @($script:LevelAliases.Values | Select-Object -Unique)
    $values = New-Object System.Collections.Generic.List[string]
    foreach ($path in $CsvPath) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            continue
        }
        if (@(Get-CsvHeader -Path $path) -notcontains 'Level') {
            continue
        }
        foreach ($row in @(Import-Csv -LiteralPath $path -Encoding UTF8)) {
            $v = [string]$row.Level
            if (-not $values.Contains($v)) {
                $values.Add($v)
            }
        }
    }

    if ($values.Count -eq 0) {
        return (New-CompatibilityCheck -Name 'levels' -Passed $false -Detail 'no Level values to check: no run detected anything')
    }
    $unmapped = @($values | Where-Object { $known -notcontains (ConvertTo-SeverityName -Level $_) })
    if ($unmapped.Count -gt 0) {
        $quoted = @($unmapped | ForEach-Object { "'$_'" }) -join ', '
        return (New-CompatibilityCheck -Name 'levels' -Passed $false -Detail "Level value(s) $quoted do not map to one of $($known -join ', '). Renamed or new level")
    }
    $mapped = @($values | ForEach-Object { "$_ -> $(ConvertTo-SeverityName -Level $_)" }) -join ', '
    return (New-CompatibilityCheck -Name 'levels' -Passed $true -Detail "all map to a known severity: $mapped")
}

function Test-CompatibilityFlagCoverage {
    # Every flag New-HayabusaArgument can emit was sent in at least one run.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$SentFlag,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$EmittableFlag
    )

    $missing = @($EmittableFlag | Where-Object { $SentFlag -cnotcontains $_ })
    if ($missing.Count -gt 0) {
        return (New-CompatibilityCheck -Name 'flag coverage' -Passed $false -Detail "never sent: $($missing -join ', '). Add a run to Get-CompatibilityRunPlan that sends it")
    }
    return (New-CompatibilityCheck -Name 'flag coverage' -Passed $true -Detail "all $($EmittableFlag.Count) flags New-HayabusaArgument can emit were sent")
}

function Test-CompatibilityVersion {
    # The version line was read from the help banner, as run-meta needs.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$HayabusaVersion
    )

    if ($null -eq $HayabusaVersion.Version) {
        return (New-CompatibilityCheck -Name 'version' -Passed $false -Detail "could not read the version: $($HayabusaVersion.Error)")
    }
    $number = Get-HayabusaVersionNumber -VersionLine $HayabusaVersion.Version
    if ($number -eq $script:TestedHayabusaVersion) {
        $note = "the tested version"
    }
    else {
        $note = "tested version is $script:TestedHayabusaVersion"
    }
    return (New-CompatibilityCheck -Name 'version' -Passed $true -Detail "$($HayabusaVersion.Version) ($note)")
}

function Invoke-HayabusaCompatibilityCheck {
    <#
    .SYNOPSIS
        Runs a Hayabusa binary over the generated sample and judges the
        result.
    .DESCRIPTION
        Writes the sample under WorkingDirectory\sample, then makes each run
        in Get-CompatibilityRunPlan with arguments from New-HayabusaArgument
        through Invoke-HayabusaProcess, into WorkingDirectory\<run>. Returns
        the version, every check and the exit code: 0 when every check
        passed, 1 otherwise.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$HayabusaPath,

        [Parameter(Mandatory)]
        [string]$RulesPath,

        [Parameter(Mandatory)]
        [string]$WorkingDirectory
    )

    $checks = New-Object System.Collections.Generic.List[object]

    $version = Get-HayabusaVersion -HayabusaPath $HayabusaPath
    $checks.Add((Test-CompatibilityVersion -HayabusaVersion $version))

    $sampleDir = Join-Path -Path $WorkingDirectory -ChildPath 'sample'
    if (-not (Test-Path -LiteralPath $sampleDir -PathType Container)) {
        New-Item -ItemType Directory -Path $sampleDir | Out-Null
    }
    New-CompatibilitySampleEvtx -Path (Join-Path -Path $sampleDir -ChildPath 'Security.evtx') | Out-Null

    $emittable = Get-HayabusaArgumentFlag
    $sent = New-Object System.Collections.Generic.List[string]
    $runChecks = New-Object System.Collections.Generic.List[object]
    $csvPaths = New-Object System.Collections.Generic.List[string]

    foreach ($run in @(Get-CompatibilityRunPlan -RulesPath $RulesPath)) {
        $runDir = Join-Path -Path $WorkingDirectory -ChildPath $run.Name
        New-Item -ItemType Directory -Path $runDir -Force | Out-Null
        $csv = Join-Path -Path $runDir -ChildPath "$($run.Name)_timeline.csv"
        $html = Join-Path -Path $runDir -ChildPath "$($run.Name)_report.html"
        $log = Join-Path -Path $runDir -ChildPath "$($run.Name)_hayabusa.log"

        $argument = New-HayabusaArgument -InputPath $sampleDir -CsvPath $csv -HtmlPath $html -Selection $run.Selection -Threads $run.Threads
        $flags = [string[]]@($argument | Where-Object { $emittable -ccontains $_ })
        foreach ($f in $flags) {
            if (-not $sent.Contains($f)) {
                $sent.Add($f)
            }
        }

        $exit = Invoke-HayabusaProcess -HayabusaPath $HayabusaPath -Argument $argument -LogPath $log
        foreach ($c in @(Test-CompatibilityRun -Name $run.Name -ExitCode $exit -CsvPath $csv -LogPath $log -Flag (@('dfir-timeline') + $flags) -ExpectDetection $run.ExpectDetection -Filter $run.Filter)) {
            $runChecks.Add($c)
        }
        $csvPaths.Add($csv)
    }

    $checks.Add((Test-CompatibilityFlagCoverage -SentFlag $sent.ToArray() -EmittableFlag $emittable))
    foreach ($c in $runChecks) {
        $checks.Add($c)
    }
    $checks.Add((Test-CompatibilityLevel -CsvPath $csvPaths.ToArray()))

    $failed = @($checks | Where-Object { -not $_.Passed }).Count
    $exitCode = 0
    if ($failed -gt 0) {
        $exitCode = 1
    }
    [pscustomobject]@{
        Version  = $version
        Checks   = $checks.ToArray()
        Failed   = $failed
        ExitCode = $exitCode
    }
}

function Format-CompatibilityReport {
    # Plain lines, one per check, then the overall result.
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Check
    )

    $width = 0
    foreach ($c in $Check) {
        $width = [Math]::Max($width, $c.Name.Length)
    }
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($c in $Check) {
        $verdict = 'FAIL'
        if ($c.Passed) {
            $verdict = 'PASS'
        }
        $lines.Add(('{0}  {1}  {2}' -f $verdict, $c.Name.PadRight($width), $c.Detail))
    }
    $failed = @($Check | Where-Object { -not $_.Passed }).Count
    if ($failed -eq 0) {
        $lines.Add("Result: PASS, all $($Check.Count) checks passed.")
    }
    else {
        $lines.Add("Result: FAIL, $failed of $($Check.Count) checks failed.")
    }
    return [string[]]$lines.ToArray()
}
