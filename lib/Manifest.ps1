# Rows are keyed by Collection, the folder-safe name of the InputRoot entry.
# Source is the entry's original name. Host stays blank until the event
# Computer field has been read from the results.
$script:ManifestColumns = @(
    'Host'
    'Collection'
    'Source'
    'RunId'
    'InputType'
    'Status'
    'Detections'
    'Critical'
    'High'
    'Warning'
    'Error'
    'DurationSec'
    'Timestamp'
)

function Write-Utf8Line {
    # Writes lines as UTF-8 without a BOM. Set-Content in 5.1 adds a BOM and
    # 7.x does not, so this keeps the file identical across both.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Line
    )

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines($Path, $Line, $encoding)
}

function Get-ManifestHeaderLine {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    return (($script:ManifestColumns | ForEach-Object { '"' + $_ + '"' }) -join ',')
}

function Initialize-RunManifest {
    <#
    .SYNOPSIS
        Creates run_manifest.csv with its header, or validates an existing one.
    .DESCRIPTION
        An existing manifest is kept so earlier results drive resumability.
        If its header does not match the expected columns the run stops,
        rather than appending rows to a file of a different shape.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Write-Utf8Line -Path $Path -Line @(Get-ManifestHeaderLine)
        Write-Verbose "Created run manifest: $Path"
        return $Path
    }

    $first = Get-Content -LiteralPath $Path -TotalCount 1 -Encoding UTF8
    if ($null -eq $first) {
        Write-Utf8Line -Path $Path -Line @(Get-ManifestHeaderLine)
        Write-Verbose "Run manifest was empty. Header written: $Path"
        return $Path
    }

    Assert-RunManifestHeader -Path $Path -HeaderLine $first
    Write-Verbose "Using existing run manifest: $Path"
    return $Path
}

function Assert-RunManifestHeader {
    <#
    .SYNOPSIS
        Fails if a manifest's header does not match the expected columns.
    .DESCRIPTION
        Read-only. Used before appending to a manifest and before building
        a rollup from one.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [string]$HeaderLine
    )

    $first = $HeaderLine
    if (-not $PSBoundParameters.ContainsKey('HeaderLine')) {
        $first = Get-Content -LiteralPath $Path -TotalCount 1 -Encoding UTF8
    }
    if ($null -eq $first) {
        $first = ''
    }

    $found = @($first.TrimStart([char]0xFEFF).Split(',') | ForEach-Object { $_.Trim().Trim('"') })
    $expected = $script:ManifestColumns
    $headerOk = ($found.Count -eq $expected.Count)
    if ($headerOk) {
        for ($i = 0; $i -lt $expected.Count; $i++) {
            if ($found[$i] -ne $expected[$i]) {
                $headerOk = $false
                break
            }
        }
    }

    if (-not $headerOk) {
        throw ("Existing run manifest has unexpected columns: {0}`n" +
            "Expected: {1}`nMove or rename {2} and rerun.") -f ($found -join ','), ($expected -join ','), $Path
    }
}

function Get-RunManifest {
    <#
    .SYNOPSIS
        Reads run_manifest.csv into an ordered dictionary keyed by collection.
    .DESCRIPTION
        Collection keys are case-insensitive. If a collection appears more
        than once the last row wins.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $entries = New-Object System.Collections.Specialized.OrderedDictionary([System.StringComparer]::OrdinalIgnoreCase)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $entries
    }

    foreach ($row in @(Import-Csv -LiteralPath $Path -Encoding UTF8)) {
        if ([string]::IsNullOrWhiteSpace($row.Collection)) {
            continue
        }
        $entries[$row.Collection] = $row
    }

    return $entries
}

function ConvertTo-ManifestText {
    # Flattens one or more messages onto a single CSV-friendly line.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Message
    )

    $parts = @($Message | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { ($_ -replace '[\r\n]+', ' ').Trim() })
    return ($parts -join ' | ')
}

function New-RunManifestRow {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory object only.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Collection,

        [Parameter(Mandatory)]
        [string]$Source,

        [Parameter(Mandatory)]
        [string]$RunId,

        [Parameter(Mandatory)]
        [ValidateSet('Loose', 'Zip', 'Vhdx', 'Vhd')]
        [string]$InputType,

        [Parameter(Mandatory)]
        [ValidateSet('Pending', 'Running', 'Completed', 'CompletedWithErrors', 'Failed', 'Skipped')]
        [string]$Status,

        [AllowEmptyString()]
        [string]$HostName = '',

        [int]$Detections = 0,
        [int]$Critical = 0,
        [int]$High = 0,

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$WarningMessage = @(),

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$ErrorMessage = @(),

        [double]$DurationSec = 0
    )

    [pscustomobject][ordered]@{
        Host        = $HostName
        Collection  = $Collection
        Source      = $Source
        RunId       = $RunId
        InputType   = $InputType
        Status      = $Status
        Detections  = $Detections
        Critical    = $Critical
        High        = $High
        Warning     = (ConvertTo-ManifestText -Message $WarningMessage)
        Error       = (ConvertTo-ManifestText -Message $ErrorMessage)
        DurationSec = [math]::Round($DurationSec, 1)
        Timestamp   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
}

function Write-RunManifest {
    <#
    .SYNOPSIS
        Writes every manifest row in one atomic save.
    .DESCRIPTION
        Rows go to a temporary file that is then swapped in, so a crash
        mid-write leaves the previous manifest intact.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Entries
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add((Get-ManifestHeaderLine))
    $rows = @($Entries.Values | Select-Object -Property $script:ManifestColumns)
    if ($rows.Count -gt 0) {
        $csv = $rows | ConvertTo-Csv -NoTypeInformation
        foreach ($line in ($csv | Select-Object -Skip 1)) {
            $lines.Add($line)
        }
    }

    if (-not $PSCmdlet.ShouldProcess($Path, 'Write run manifest')) {
        return
    }

    $temp = $Path + '.tmp'
    Write-Utf8Line -Path $temp -Line $lines.ToArray()

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        try {
            [System.IO.File]::Replace($temp, $Path, $null)
        }
        catch {
            # File.Replace is not supported on every file system, for
            # example some network shares. Fall back to a plain move.
            Move-Item -LiteralPath $temp -Destination $Path -Force
        }
    }
    else {
        Move-Item -LiteralPath $temp -Destination $Path -Force
    }
}

function Set-RunManifestEntry {
    <#
    .SYNOPSIS
        Adds or replaces one collection's row in run_manifest.csv.
    .DESCRIPTION
        Timestamp is set to the current UTC time in ISO 8601 form. Warning
        and Error take one or more messages, joined onto one line.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Collection,

        [Parameter(Mandatory)]
        [string]$Source,

        [Parameter(Mandatory)]
        [string]$RunId,

        [Parameter(Mandatory)]
        [ValidateSet('Loose', 'Zip', 'Vhdx', 'Vhd')]
        [string]$InputType,

        [Parameter(Mandatory)]
        [ValidateSet('Pending', 'Running', 'Completed', 'CompletedWithErrors', 'Failed', 'Skipped')]
        [string]$Status,

        [AllowEmptyString()]
        [string]$HostName = '',

        [int]$Detections = 0,
        [int]$Critical = 0,
        [int]$High = 0,

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$WarningMessage = @(),

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$ErrorMessage = @(),

        [double]$DurationSec = 0
    )

    $entries = Get-RunManifest -Path $Path
    $entries[$Collection] = New-RunManifestRow -Collection $Collection -Source $Source -RunId $RunId `
        -InputType $InputType -Status $Status -HostName $HostName -Detections $Detections `
        -Critical $Critical -High $High -WarningMessage $WarningMessage -ErrorMessage $ErrorMessage `
        -DurationSec $DurationSec

    if ($PSCmdlet.ShouldProcess($Path, "Update manifest entry for $Collection")) {
        Write-RunManifest -Path $Path -Entries $entries
    }
}

function Add-PendingCollection {
    <#
    .SYNOPSIS
        Records newly discovered collections as Pending.
    .DESCRIPTION
        Only collections not already in the manifest are added, with their
        discovery warnings. Existing rows are left alone so earlier results
        still drive resumability, and rows for collections no longer in
        InputRoot stay as history. Returns the number of rows added.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Collections,

        [Parameter(Mandatory)]
        [string]$RunId
    )

    $entries = Get-RunManifest -Path $Path
    $added = 0
    foreach ($c in $Collections) {
        if ($entries.Contains($c.Collection)) {
            continue
        }
        $entries[$c.Collection] = New-RunManifestRow -Collection $c.Collection -Source $c.Source -RunId $RunId `
            -InputType $c.InputType -Status 'Pending' -WarningMessage $c.Warnings
        $added++
    }

    if ($added -gt 0 -and $PSCmdlet.ShouldProcess($Path, "Add $added pending collection(s)")) {
        Write-RunManifest -Path $Path -Entries $entries
    }
    return $added
}
