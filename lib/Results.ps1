# Host marker when a collection's results carry more than one Computer value.
$script:MultipleHostMarker = '[multiple]'

# Most Computer values listed in the warning before it is cut short.
$script:MaxComputersListed = 20

# Columns the minimal parse needs from the standard profile.
$script:RequiredResultColumns = @('Level', 'Computer')

# Hayabusa may write levels in short or full form, so both are accepted.
$script:CriticalLevels = @('crit', 'critical')
$script:HighLevels = @('high')

function Get-CsvHeader {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $first = Get-Content -LiteralPath $Path -TotalCount 1 -Encoding UTF8
    if ($null -eq $first) {
        return
    }
    foreach ($field in $first.TrimStart([char]0xFEFF).Split(',')) {
        $field.Trim().Trim('"')
    }
}

function Get-HayabusaResultSummary {
    <#
    .SYNOPSIS
        Counts detections in a per-host Hayabusa CSV for the manifest row.
    .DESCRIPTION
        Streams the CSV rather than loading it whole. Returns whether the
        file exists, the total detection count, the Critical and High
        counts, and each distinct Computer value with its row count.
        Computer values are compared case-insensitively. Blank values are
        ignored.

        A missing file comes back with Exists set to false. A zero-byte file
        and a header-only file are both an empty result. A file without the
        Level or Computer column is an error.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$CsvPath
    )

    $summary = [pscustomobject]@{
        Exists     = $false
        Empty      = $true
        Detections = 0
        Critical   = 0
        High       = 0
        Computers  = [ordered]@{}
    }

    if (-not (Test-Path -LiteralPath $CsvPath -PathType Leaf)) {
        return $summary
    }
    $summary.Exists = $true

    $header = @(Get-CsvHeader -Path $CsvPath)
    if ($header.Count -eq 0) {
        return $summary
    }

    $missing = @($script:RequiredResultColumns | Where-Object { $header -notcontains $_ })
    if ($missing.Count -gt 0) {
        throw "Result CSV is missing column(s) $($missing -join ', '): $CsvPath"
    }

    $counts = New-Object 'System.Collections.Generic.Dictionary[string,int]' ([System.StringComparer]::OrdinalIgnoreCase)
    $firstSeen = New-Object System.Collections.Generic.List[string]
    $total = 0
    $critical = 0
    $high = 0

    Import-Csv -LiteralPath $CsvPath -Encoding UTF8 | ForEach-Object {
        $total++
        $level = ([string]$_.Level).Trim().ToLowerInvariant()
        if ($script:CriticalLevels -contains $level) {
            $critical++
        }
        elseif ($script:HighLevels -contains $level) {
            $high++
        }

        $computer = ([string]$_.Computer).Trim()
        if ($computer.Length -gt 0) {
            if ($counts.ContainsKey($computer)) {
                $counts[$computer] = $counts[$computer] + 1
            }
            else {
                $counts[$computer] = 1
                $firstSeen.Add($computer)
            }
        }
    }

    $ordered = [ordered]@{}
    foreach ($name in @($firstSeen | Sort-Object -Property @{ Expression = { $counts[$_] }; Descending = $true }, @{ Expression = { $_ } })) {
        $ordered[$name] = $counts[$name]
    }

    $summary.Empty = ($total -eq 0)
    $summary.Detections = $total
    $summary.Critical = $critical
    $summary.High = $high
    $summary.Computers = $ordered
    return $summary
}

function Resolve-HostName {
    <#
    .SYNOPSIS
        Picks the Host value from the Computer values in the results.
    .DESCRIPTION
        No values gives a blank Host, which is the case for a clean host
        with no detections at the severity floor. One value is the Host.
        More than one sets Host to the [multiple] marker and returns a
        warning listing each value with its row count, rather than picking
        one.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.IDictionary]$Computers
    )

    $names = @($Computers.Keys)
    if ($names.Count -eq 0) {
        return [pscustomobject]@{ HostName = ''; Warning = $null }
    }
    if ($names.Count -eq 1) {
        return [pscustomobject]@{ HostName = [string]$names[0]; Warning = $null }
    }

    $listed = @($names | Select-Object -First $script:MaxComputersListed | ForEach-Object { "$_ ($($Computers[$_]))" })
    $more = ''
    if ($names.Count -gt $script:MaxComputersListed) {
        $more = ", and $($names.Count - $script:MaxComputersListed) more"
    }
    return [pscustomobject]@{
        HostName = $script:MultipleHostMarker
        Warning  = "Multiple Computer values: $($listed -join ', ')$more"
    }
}

function Join-UniqueMessage {
    # Joins message lists in order, dropping blanks and exact duplicates.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Message
    )

    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($m in @($Message)) {
        if ($null -eq $m) {
            continue
        }
        $text = ([string]$m).Trim()
        if ($text.Length -gt 0 -and $seen.Add($text)) {
            $text
        }
    }
}
