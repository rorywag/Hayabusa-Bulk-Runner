# Severity order, highest first. Emergency is above critical. Unknown
# levels rank below informational.
$script:SeverityRank = @{
    'emergency'     = 6
    'critical'      = 5
    'high'          = 4
    'medium'        = 3
    'low'           = 2
    'informational' = 1
}

# Hosts with results sort first, worst first. Among hosts with equal
# counts, and among the hosts without results below them, problem rows sort
# first so they are not hidden among clean ones.
$script:StatusPriority = @{
    'Failed'              = 0
    'Unreadable'          = 1
    'CompletedWithErrors' = 2
    'Running'             = 3
    'Pending'             = 4
    'Skipped'             = 5
    'Completed'           = 6
}

# Only these rows have results worth showing: counts, the report and the
# timeline. A Failed row's files may be left from an earlier run, when a
# rerun failed before Hayabusa ran, and a Running row's may be half-written
# by an interrupted run. The log is linked for any row that has one.
$script:ResultStatuses = @('Completed', 'CompletedWithErrors')

# Shown in place of Completed or CompletedWithErrors when the rollup can't
# read the host's CSV, so a host with unknown results never passes for a
# clean one. The manifest keeps the batch's own status.
$script:UnreadableStatus = 'Unreadable'

# Host marker when the manifest has no Host, which is a clean host with no
# detections at the severity floor, or a host that never produced results.
$script:UnknownHostMarker = '[unknown]'

# A [multiple] host is shown by its computer names: this many, then "+N".
$script:MultipleHostNamesShown = 3

$script:HostCsvColumns = @('Host', 'Collection', 'Status', 'Emergency', 'Critical', 'High', 'Medium', 'Low', 'Total', 'TopRule')
$script:RuleCsvColumns = @('RuleTitle', 'Level', 'HostsAffected', 'TotalHits')
$script:RollupRequiredColumns = @('Level', 'RuleTitle')

function Get-SeverityRank {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [AllowEmptyString()]
        [string]$Level
    )

    if ($script:SeverityRank.ContainsKey($Level)) {
        return $script:SeverityRank[$Level]
    }
    return 0
}

function Read-HostDetection {
    <#
    .SYNOPSIS
        Reads one per-host CSV for counts by level and hits per rule.
    .DESCRIPTION
        Streams the file. Levels are normalised with ConvertTo-SeverityName.
        Rules are keyed by RuleTitle and Level, so one title firing at two
        levels counts as two rules. A header-only or zero-byte file is an
        empty result. A file without Level or RuleTitle is an error.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$CsvPath
    )

    $result = [pscustomobject]@{
        Emergency     = 0
        Critical      = 0
        High          = 0
        Medium        = 0
        Low           = 0
        Informational = 0
        Other         = 0
        Total         = 0
        Rules         = @{}
    }

    $header = @(Get-CsvHeader -Path $CsvPath)
    if ($header.Count -eq 0) {
        return $result
    }
    $missing = @($script:RollupRequiredColumns | Where-Object { $header -notcontains $_ })
    if ($missing.Count -gt 0) {
        throw "Result CSV is missing column(s) $($missing -join ', '): $CsvPath"
    }

    $rules = @{}
    Import-Csv -LiteralPath $CsvPath -Encoding UTF8 | ForEach-Object {
        $level = ConvertTo-SeverityName -Level $_.Level
        $title = [string]$_.RuleTitle
        $result.Total++
        switch ($level) {
            'emergency' { $result.Emergency++ }
            'critical' { $result.Critical++ }
            'high' { $result.High++ }
            'medium' { $result.Medium++ }
            'low' { $result.Low++ }
            'informational' { $result.Informational++ }
            default { $result.Other++ }
        }
        $key = "$level`t$title"
        if ($rules.ContainsKey($key)) {
            $rules[$key].Hits++
        }
        else {
            $rules[$key] = [pscustomobject]@{ RuleTitle = $title; Level = $level; Hits = 1 }
        }
    }

    $result.Rules = $rules
    return $result
}

function Get-TopRule {
    # Highest severity, then most hits, then title.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [hashtable]$Rules
    )

    if ($Rules.Count -eq 0) {
        return $null
    }
    return @($Rules.Values | Sort-Object -Property @(
            @{ Expression = { Get-SeverityRank -Level $_.Level }; Descending = $true }
            @{ Expression = { $_.Hits }; Descending = $true }
            @{ Expression = { $_.RuleTitle }; Descending = $false }
        ))[0]
}

function ConvertTo-SafeCsvValue {
    <#
    .SYNOPSIS
        Neutralises a cell value that a spreadsheet would treat as a formula.
    .DESCRIPTION
        Values starting with =, +, -, @, tab or carriage return get a
        leading apostrophe, following the OWASP guidance on CSV injection.
        Rule titles and computer names come from the evidence, so any of
        them could be crafted. Other values are returned unchanged.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Value
    )

    $text = [string]$Value
    if ($text -match '^[=+\-@\t\r]') {
        return "'" + $text
    }
    return $text
}

function Get-JsonValue {
    # Reads a property path from parsed JSON without failing under strict
    # mode when a level is missing. Run-meta files from older runs, or
    # edited by hand, may not carry every field.
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Object,

        [Parameter(Mandatory)]
        [string[]]$Name
    )

    $current = $Object
    foreach ($n in $Name) {
        if ($null -eq $current) {
            return $null
        }
        $prop = $current.PSObject.Properties[$n]
        if ($null -eq $prop) {
            return $null
        }
        $current = $prop.Value
    }
    return $current
}

function Get-RunProvenance {
    <#
    .SYNOPSIS
        Describes each run that produced a manifest row, from its run-meta.
    .DESCRIPTION
        Looks up OutputRoot\_runs\run_meta_*_<RunId>.json first, then falls
        back to reading every run-meta file for a matching RunId, which
        covers files named before the RunId was in the name. A run whose
        run-meta is missing is still listed.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$OutputRoot,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [hashtable]$RowsByRun
    )

    $runsDir = Join-Path -Path $OutputRoot -ChildPath '_runs'
    $all = @()
    if (Test-Path -LiteralPath $runsDir -PathType Container) {
        $all = @(Get-ChildItem -LiteralPath $runsDir -Filter 'run_meta_*.json' -File)
    }

    foreach ($runId in @($RowsByRun.Keys | Sort-Object)) {
        $meta = $null
        $named = @($all | Where-Object { $_.Name -like "*_$runId.json" })
        foreach ($file in @($named + $all)) {
            try {
                $candidate = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                if ([string](Get-JsonValue -Object $candidate -Name 'RunId') -eq $runId) {
                    $meta = $candidate
                    break
                }
            }
            catch {
                Write-Verbose "Could not read $($file.FullName): $($_.Exception.Message)"
            }
        }

        $started = $null
        $floor = $null
        $profileName = $null
        $hayabusa = $null
        $rulesVersion = $null
        if ($null -ne $meta) {
            # ConvertFrom-Json in 7.x turns ISO timestamps into DateTime.
            $startedValue = Get-JsonValue -Object $meta -Name 'StartedUtc'
            if ($startedValue -is [datetime]) {
                $started = $startedValue.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
            }
            elseif ($null -ne $startedValue) {
                $started = [string]$startedValue
            }
            $exact = [string](Get-JsonValue -Object $meta -Name 'Selection', 'ExactLevel')
            $min = [string](Get-JsonValue -Object $meta -Name 'Selection', 'MinLevel')
            if (-not [string]::IsNullOrEmpty($exact)) {
                $floor = "exact $exact"
            }
            elseif (-not [string]::IsNullOrEmpty($min)) {
                $floor = "min $min"
            }
            $profileName = [string](Get-JsonValue -Object $meta -Name 'Selection', 'Profile')
            $hayabusa = [string](Get-JsonValue -Object $meta -Name 'Hayabusa', 'Version')
            $rulesVersion = [string](Get-JsonValue -Object $meta -Name 'Hayabusa', 'RulesVersion')
        }

        [pscustomobject]@{
            RunId        = $runId
            Found        = ($null -ne $meta)
            StartedUtc   = $started
            Floor        = $floor
            Profile      = $profileName
            Hayabusa     = $hayabusa
            RulesVersion = $rulesVersion
            Rows         = $RowsByRun[$runId]
        }
    }
}

function Get-MultipleHostLabel {
    <#
    .SYNOPSIS
        Display label for a collection holding more than one computer.
    .DESCRIPTION
        Takes the Computer counts from Get-HayabusaResultSummary, already
        ordered most rows first. Up to three names are joined, then "+N"
        for the rest: "DC01, DC01.corp.local" or "WS01, WS02, WS03 +2".
        Display only. Whether a collection is [multiple] is decided when the
        results are parsed, and the manifest keeps the marker.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.IDictionary]$Computers
    )

    $names = @($Computers.Keys)
    $label = ($names | Select-Object -First $script:MultipleHostNamesShown) -join ', '
    if ($names.Count -gt $script:MultipleHostNamesShown) {
        $label += " +$($names.Count - $script:MultipleHostNamesShown)"
    }
    return $label
}

function Get-RollupData {
    <#
    .SYNOPSIS
        Builds the cross-host view from the manifest and per-host CSVs.
    .DESCRIPTION
        Reads OutputRoot\run_manifest.csv and, for each row that is
        Completed or CompletedWithErrors, that collection's timeline CSV.
        A Failed row is shown without counts, report or timeline, since its
        files may be from an earlier run. Nothing is written and no host is
        rerun.

        Hosts: one row per manifest row. A blank Host becomes [unknown]. A
        [multiple] Host is shown by its computer names when the CSV can be
        read, and stays [multiple] when it cannot. HostNames holds the names
        to show, up to three, and HostNamesMore how many more there are.
        Counts are null, shown blank, when there is no readable CSV, so a
        host that never produced results does not read as clean. Rows with
        results, Completed or CompletedWithErrors, sort first, by Emergency,
        Critical, High, Medium, Low and Total, highest first. Every other
        row sorts below them. Within each group, ties go to problem statuses
        first, then Collection.

        Rules: one row per RuleTitle and Level. HostsAffected counts
        collections, so a [multiple] collection counts once even though it
        holds more than one machine. Sorted by severity, HostsAffected and
        TotalHits, highest first, then RuleTitle.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$OutputRoot
    )

    $manifestPath = Join-Path -Path $OutputRoot -ChildPath 'run_manifest.csv'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "No run_manifest.csv in $OutputRoot. Nothing to roll up."
    }
    Assert-RunManifestHeader -Path $manifestPath

    $warnings = New-Object System.Collections.Generic.List[string]
    $hosts = New-Object System.Collections.Generic.List[object]
    $ruleTotals = @{}
    $rowsByRun = @{}

    foreach ($entry in (Get-RunManifest -Path $manifestPath).Values) {
        $collection = [string]$entry.Collection
        $paths = Get-CollectionOutputPath -OutputRoot $OutputRoot -Collection $collection

        if (-not [string]::IsNullOrEmpty([string]$entry.RunId)) {
            if ($rowsByRun.ContainsKey($entry.RunId)) {
                $rowsByRun[$entry.RunId]++
            }
            else {
                $rowsByRun[$entry.RunId] = 1
            }
        }

        $detection = $null
        $readError = $null
        if ($script:ResultStatuses -contains $entry.Status -and (Test-Path -LiteralPath $paths.Csv -PathType Leaf)) {
            try {
                $detection = Read-HostDetection -CsvPath $paths.Csv
            }
            catch {
                $readError = $_.Exception.Message
                $warnings.Add("${collection}: $readError")
            }
        }

        $topRule = $null
        if ($null -ne $detection) {
            $topRule = Get-TopRule -Rules $detection.Rules
            foreach ($rule in $detection.Rules.Values) {
                $key = "$($rule.Level)`t$($rule.RuleTitle)"
                if (-not $ruleTotals.ContainsKey($key)) {
                    $ruleTotals[$key] = [pscustomobject]@{
                        RuleTitle   = $rule.RuleTitle
                        Level       = $rule.Level
                        TotalHits   = 0
                        Collections = New-Object System.Collections.Generic.List[string]
                    }
                }
                $ruleTotals[$key].TotalHits += $rule.Hits
                $ruleTotals[$key].Collections.Add($collection)
            }
        }

        $hostName = [string]$entry.Host
        $hostUnknown = [string]::IsNullOrWhiteSpace($hostName)
        if ($hostUnknown) {
            $hostName = $script:UnknownHostMarker
        }
        $multiple = ($hostName -eq $script:MultipleHostMarker)
        $hostNames = @()
        $hostNamesMore = 0
        if (-not $hostUnknown -and -not $multiple) {
            $hostNames = @($hostName)
        }
        if ($multiple -and $null -ne $detection) {
            try {
                $computers = (Get-HayabusaResultSummary -CsvPath $paths.Csv).Computers
                $label = Get-MultipleHostLabel -Computers $computers
                if (-not [string]::IsNullOrEmpty($label)) {
                    $hostName = $label
                    $allNames = @($computers.Keys)
                    $hostNames = @($allNames | Select-Object -First $script:MultipleHostNamesShown)
                    $hostNamesMore = [math]::Max(0, $allNames.Count - $script:MultipleHostNamesShown)
                }
            }
            catch {
                Write-Verbose "${collection}: could not list computer names: $($_.Exception.Message)"
            }
        }

        # Report and timeline only for rows whose results are read, as their
        # files may otherwise be stale or half-written. The log, for any row
        # that has one, as it's where a failure is explained.
        $linkFiles = @()
        if ($script:ResultStatuses -contains $entry.Status) {
            $linkFiles += , @('Report', $paths.Html)
            $linkFiles += , @('Timeline', $paths.Csv)
        }
        $linkFiles += , @('Log', $paths.Log)
        $links = [ordered]@{}
        foreach ($pair in $linkFiles) {
            if (Test-Path -LiteralPath $pair[1] -PathType Leaf) {
                $links[$pair[0]] = @($collection, (Split-Path -Path $pair[1] -Leaf))
            }
        }

        $em = $null; $c = $null; $h = $null; $m = $null; $l = $null; $inf = $null; $t = $null
        if ($null -ne $detection) {
            $em = $detection.Emergency; $c = $detection.Critical; $h = $detection.High; $m = $detection.Medium; $l = $detection.Low; $inf = $detection.Informational; $t = $detection.Total
        }
        $topTitle = $null
        $topLevel = $null
        if ($null -ne $topRule) {
            $topTitle = $topRule.RuleTitle
            $topLevel = $topRule.Level
        }

        $status = [string]$entry.Status
        if ($null -ne $readError) {
            $status = $script:UnreadableStatus
        }

        $hosts.Add([pscustomobject]@{
                Host          = $hostName
                HostNames     = $hostNames
                HostNamesMore = $hostNamesMore
                HostUnknown   = $hostUnknown
                Multiple      = $multiple
                Collection    = $collection
                Source        = [string]$entry.Source
                Status        = $status
                Emergency     = $em
                Critical      = $c
                High          = $h
                Medium        = $m
                Low           = $l
                Informational = $inf
                Total         = $t
                TopRule       = $topTitle
                TopRuleLevel  = $topLevel
                Warning       = [string]$entry.Warning
                Error         = [string]$entry.Error
                ReadError     = $readError
                RunId         = [string]$entry.RunId
                Links         = $links
            })
    }

    $zero = { param($v) if ($null -eq $v) { 0 } else { [int]$v } }
    $sortedHosts = @($hosts | Sort-Object -Property @(
            @{ Expression = { if ($script:ResultStatuses -contains $_.Status) { 0 } else { 1 } }; Descending = $false }
            @{ Expression = { & $zero $_.Emergency }; Descending = $true }
            @{ Expression = { & $zero $_.Critical }; Descending = $true }
            @{ Expression = { & $zero $_.High }; Descending = $true }
            @{ Expression = { & $zero $_.Medium }; Descending = $true }
            @{ Expression = { & $zero $_.Low }; Descending = $true }
            @{ Expression = { & $zero $_.Total }; Descending = $true }
            @{ Expression = { if ($script:StatusPriority.ContainsKey($_.Status)) { $script:StatusPriority[$_.Status] } else { 9 } }; Descending = $false }
            @{ Expression = { $_.Collection }; Descending = $false }
        ))

    $rules = foreach ($r in $ruleTotals.Values) {
        [pscustomobject]@{
            RuleTitle     = $r.RuleTitle
            Level         = $r.Level
            HostsAffected = $r.Collections.Count
            TotalHits     = $r.TotalHits
            Collections   = @($r.Collections | Sort-Object)
        }
    }
    $sortedRules = @($rules | Sort-Object -Property @(
            @{ Expression = { Get-SeverityRank -Level $_.Level }; Descending = $true }
            @{ Expression = { $_.HostsAffected }; Descending = $true }
            @{ Expression = { $_.TotalHits }; Descending = $true }
            @{ Expression = { $_.RuleTitle }; Descending = $false }
        ))

    $provenance = @(Get-RunProvenance -OutputRoot $OutputRoot -RowsByRun $rowsByRun)
    $floors = @($provenance | Where-Object { $null -ne $_.Floor } | ForEach-Object { $_.Floor } | Sort-Object -Unique)

    [pscustomobject]@{
        OutputRoot   = $OutputRoot
        ManifestPath = $manifestPath
        BuiltUtc     = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
        Hosts        = $sortedHosts
        Rules        = $sortedRules
        Provenance   = $provenance
        MixedFloors  = ($floors.Count -gt 1)
        Floors       = $floors
        Warnings     = $warnings.ToArray()
    }
}

function ConvertTo-RollupCsvText {
    # Renders rows to CSV text with every text cell passed through the
    # formula-injection guard. Numbers are written as is, blanks as empty.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Rows,

        [Parameter(Mandatory)]
        [string[]]$Columns
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add((($Columns | ForEach-Object { '"' + $_ + '"' }) -join ','))

    $safe = foreach ($row in $Rows) {
        $o = [ordered]@{}
        foreach ($col in $Columns) {
            $v = $row.$col
            if ($null -eq $v) {
                $o[$col] = ''
            }
            elseif ($v -is [int] -or $v -is [long]) {
                $o[$col] = [string]$v
            }
            else {
                $o[$col] = ConvertTo-SafeCsvValue -Value ([string]$v)
            }
        }
        [pscustomobject]$o
    }

    if (@($safe).Count -gt 0) {
        foreach ($line in (@($safe) | ConvertTo-Csv -NoTypeInformation | Select-Object -Skip 1)) {
            $lines.Add($line)
        }
    }
    return (($lines.ToArray() -join "`r`n") + "`r`n")
}

function Invoke-Rollup {
    <#
    .SYNOPSIS
        Writes triage_hosts.csv, triage_rules.csv and triage_dashboard.html
        under OutputRoot.
    .DESCRIPTION
        Built only from the manifest, the per-host CSVs and run-meta, so it
        can be rebuilt from an existing OutputRoot at any time without
        rerunning a host. The manifest and per-host files are never
        modified. Each output is written atomically. The CSVs carry a UTF-8
        byte order mark so Excel reads non-ASCII names correctly.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$OutputRoot
    )

    $data = Get-RollupData -OutputRoot $OutputRoot

    $hostsPath = Join-Path -Path $OutputRoot -ChildPath 'triage_hosts.csv'
    $rulesPath = Join-Path -Path $OutputRoot -ChildPath 'triage_rules.csv'
    $dashboardPath = Join-Path -Path $OutputRoot -ChildPath 'triage_dashboard.html'

    if ($PSCmdlet.ShouldProcess($OutputRoot, 'Write rollup')) {
        Write-TextFileAtomic -Path $hostsPath -Text (ConvertTo-RollupCsvText -Rows $data.Hosts -Columns $script:HostCsvColumns) -Bom
        Write-TextFileAtomic -Path $rulesPath -Text (ConvertTo-RollupCsvText -Rows $data.Rules -Columns $script:RuleCsvColumns) -Bom
        Write-TextFileAtomic -Path $dashboardPath -Text (New-DashboardHtml -Data $data)
    }

    foreach ($w in $data.Warnings) {
        Write-Warning "Rollup: $w"
    }

    [pscustomobject]@{
        HostsCsv  = $hostsPath
        RulesCsv  = $rulesPath
        Dashboard = $dashboardPath
        HostCount = @($data.Hosts).Count
        RuleCount = @($data.Rules).Count
        Warnings  = $data.Warnings
        BuiltUtc  = $data.BuiltUtc
    }
}
