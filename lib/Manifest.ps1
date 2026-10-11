$script:ManifestColumns = @(
    'Host'
    'RunId'
    'InputType'
    'Status'
    'Detections'
    'Critical'
    'High'
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

    Write-Verbose "Using existing run manifest: $Path"
    return $Path
}

function Get-RunManifest {
    <#
    .SYNOPSIS
        Reads run_manifest.csv into an ordered dictionary keyed by host.
    .DESCRIPTION
        Host keys are case-insensitive. If a host appears more than once the
        last row wins.
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
        if ([string]::IsNullOrWhiteSpace($row.Host)) {
            continue
        }
        $entries[$row.Host] = $row
    }

    return $entries
}

function Set-RunManifestEntry {
    <#
    .SYNOPSIS
        Adds or replaces one host's row in run_manifest.csv.
    .DESCRIPTION
        The whole manifest is rewritten to a temporary file and then swapped
        in, so a crash mid-write leaves the previous manifest intact.
        Timestamp is set to the current UTC time in ISO 8601 form.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$HostName,

        [Parameter(Mandatory)]
        [string]$RunId,

        [Parameter(Mandatory)]
        [ValidateSet('Loose', 'Zip', 'Vhdx', 'Vhd')]
        [string]$InputType,

        [Parameter(Mandatory)]
        [ValidateSet('Pending', 'Running', 'Completed', 'Failed', 'Skipped')]
        [string]$Status,

        [int]$Detections = 0,
        [int]$Critical = 0,
        [int]$High = 0,

        [AllowEmptyString()]
        [string]$ErrorMessage = '',

        [double]$DurationSec = 0
    )

    $entries = Get-RunManifest -Path $Path

    $entries[$HostName] = [pscustomobject][ordered]@{
        Host        = $HostName
        RunId       = $RunId
        InputType   = $InputType
        Status      = $Status
        Detections  = $Detections
        Critical    = $Critical
        High        = $High
        Error       = ($ErrorMessage -replace '[\r\n]+', ' ')
        DurationSec = [math]::Round($DurationSec, 1)
        Timestamp   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add((Get-ManifestHeaderLine))
    $rows = @($entries.Values | Select-Object -Property $script:ManifestColumns)
    if ($rows.Count -gt 0) {
        $csv = $rows | ConvertTo-Csv -NoTypeInformation
        foreach ($line in ($csv | Select-Object -Skip 1)) {
            $lines.Add($line)
        }
    }

    if (-not $PSCmdlet.ShouldProcess($Path, "Update manifest entry for $HostName")) {
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
