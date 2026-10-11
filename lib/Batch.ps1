# Rows in these states are not run again unless -Force is given.
$script:FinishedStatuses = @('Completed', 'CompletedWithErrors')

function Invoke-CollectionRun {
    <#
    .SYNOPSIS
        Runs Hayabusa for one collection and records the outcome.
    .DESCRIPTION
        Marks the manifest row Running, creates the per-host output folder,
        resolves the input, runs Hayabusa and parses the CSV. Teardown runs
        in a finally block, and the final row is written after it so a
        teardown failure is recorded.

        Completed: Hayabusa exited 0. No detections is Completed with zero
        counts. No CSV at all is Completed with a warning.
        CompletedWithErrors: Hayabusa exited non-zero but still wrote a CSV.
        The counts are kept and the exit code goes in Error.
        Failed: resolve, run, parse or teardown failed, or Hayabusa exited
        non-zero without writing a CSV.

        Any failure is caught and recorded, so one collection cannot stop
        the batch. If the run is interrupted the row stays Running and is
        picked up again next time.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Collection,

        [Parameter(Mandatory)]
        [string]$OutputRoot,

        [Parameter(Mandatory)]
        [string]$HayabusaPath,

        [Parameter(Mandatory)]
        [pscustomobject]$Resolved,

        [AllowNull()]
        [object]$Threads,

        [Parameter(Mandatory)]
        [string]$RunId,

        [Parameter(Mandatory)]
        [string]$ManifestPath,

        [switch]$KeepArtifacts
    )

    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $warnings = New-Object System.Collections.Generic.List[object]
    $errors = New-Object System.Collections.Generic.List[string]
    foreach ($w in @($Collection.Warnings)) {
        $warnings.Add($w)
    }

    Set-RunManifestEntry -Path $ManifestPath -Collection $Collection.Collection -Source $Collection.Source `
        -RunId $RunId -InputType $Collection.InputType -Status 'Running' -WarningMessage @(Join-UniqueMessage -Message $warnings.ToArray())

    $paths = Get-CollectionOutputPath -OutputRoot $OutputRoot -Collection $Collection.Collection
    $resolvedInput = $null
    $summary = $null
    $exitCode = $null
    $status = 'Failed'

    try {
        # Checked before resolving, so a ZIP is not extracted for nothing.
        Assert-HayabusaHost

        if (-not (Test-Path -LiteralPath $paths.Directory -PathType Container)) {
            New-Item -ItemType Directory -Path $paths.Directory -Force | Out-Null
        }

        $resolvedInput = Resolve-CollectionInput -Collection $Collection -OutputRoot $OutputRoot `
            -MaxUncompressedBytes $Resolved.Limits.ZipMaxUncompressedBytes -MaxRatio $Resolved.Limits.ZipMaxRatio `
            -KeepArtifacts:$KeepArtifacts
        foreach ($w in @($resolvedInput.Warnings)) {
            $warnings.Add($w)
        }

        $arguments = New-HayabusaArgument -InputPath $resolvedInput.Path -CsvPath $paths.Csv -HtmlPath $paths.Html `
            -Selection $Resolved.Selection -Threads $Threads
        $exitCode = Invoke-HayabusaProcess -HayabusaPath $HayabusaPath -Argument $arguments -LogPath $paths.Log
        if ($exitCode -ne 0) {
            $errors.Add("Hayabusa exited with code $exitCode. See $($paths.Log).")
        }

        $summary = Get-HayabusaResultSummary -CsvPath $paths.Csv

        if ($exitCode -eq 0) {
            $status = 'Completed'
            if (-not $summary.Exists) {
                $warnings.Add('Hayabusa exited 0 but wrote no CSV. Counted as no detections.')
            }
        }
        elseif ($summary.Exists) {
            $status = 'CompletedWithErrors'
        }
        else {
            $errors.Add('No CSV was written.')
            $status = 'Failed'
        }
    }
    catch {
        $errors.Add($_.Exception.Message)
        $status = 'Failed'
    }
    finally {
        try {
            Invoke-CollectionCleanup -Resolved $resolvedInput
        }
        catch {
            $errors.Add("Teardown: $($_.Exception.Message)")
            $status = 'Failed'
        }
    }

    $hostName = ''
    $detections = 0
    $emergency = 0
    $critical = 0
    $high = 0
    if ($null -ne $summary) {
        $detections = $summary.Detections
        $emergency = $summary.Emergency
        $critical = $summary.Critical
        $high = $summary.High
        $picked = Resolve-HostName -Computers $summary.Computers
        $hostName = $picked.HostName
        if ($null -ne $picked.Warning) {
            $warnings.Add($picked.Warning)
        }
    }

    $timer.Stop()
    $finalWarnings = @(Join-UniqueMessage -Message $warnings.ToArray())

    Set-RunManifestEntry -Path $ManifestPath -Collection $Collection.Collection -Source $Collection.Source `
        -RunId $RunId -InputType $Collection.InputType -Status $status -HostName $hostName `
        -Detections $detections -Emergency $emergency -Critical $critical -High $high `
        -WarningMessage $finalWarnings -ErrorMessage $errors.ToArray() -DurationSec $timer.Elapsed.TotalSeconds

    [pscustomobject]@{
        Collection  = $Collection.Collection
        Status      = $status
        HostName    = $hostName
        Detections  = $detections
        Emergency   = $emergency
        Critical    = $critical
        High        = $high
        ExitCode    = $exitCode
        Warnings    = $finalWarnings
        Errors      = $errors.ToArray()
        DurationSec = $timer.Elapsed.TotalSeconds
        OutputPath  = $paths.Directory
    }
}

function Invoke-CollectionBatch {
    <#
    .SYNOPSIS
        Runs every discovered collection in turn.
    .DESCRIPTION
        Collections whose manifest row is Completed or CompletedWithErrors
        are skipped unless -Force is given. Resumability keys on Collection.
        Everything else, including Pending, Failed and rows left Running by
        an interrupted run, is processed. Collections run one at a time so
        Hayabusa can use every thread and only one image is mounted at once.

        Returns a summary of the counts by outcome.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Collections,

        [Parameter(Mandatory)]
        [string]$ManifestPath,

        [Parameter(Mandatory)]
        [string]$OutputRoot,

        [Parameter(Mandatory)]
        [string]$HayabusaPath,

        [Parameter(Mandatory)]
        [pscustomobject]$Resolved,

        [AllowNull()]
        [object]$Threads,

        [Parameter(Mandatory)]
        [string]$RunId,

        [switch]$Force,
        [switch]$KeepArtifacts
    )

    $existing = Get-RunManifest -Path $ManifestPath
    $summary = [ordered]@{
        Discovered          = $Collections.Count
        Processed           = 0
        Completed           = 0
        CompletedWithErrors = 0
        Failed              = 0
        Skipped             = 0
    }

    $index = 0
    foreach ($c in $Collections) {
        $index++
        $row = $null
        if ($existing.Contains($c.Collection)) {
            $row = $existing[$c.Collection]
        }

        if (-not $Force -and $null -ne $row -and $script:FinishedStatuses -contains $row.Status) {
            Write-Verbose "[$index/$($Collections.Count)] $($c.Collection): already $($row.Status), skipped. Use -Force to rerun."
            $summary.Skipped++
            continue
        }

        Write-Verbose "[$index/$($Collections.Count)] $($c.Collection): running."
        $summary.Processed++
        $result = Invoke-CollectionRun -Collection $c -OutputRoot $OutputRoot -HayabusaPath $HayabusaPath `
            -Resolved $Resolved -Threads $Threads -RunId $RunId -ManifestPath $ManifestPath -KeepArtifacts:$KeepArtifacts
        $summary[$result.Status]++

        if ($result.Status -eq 'Failed') {
            Write-Warning "$($c.Collection): Failed. $($result.Errors -join ' ')"
        }
        elseif ($result.Status -eq 'CompletedWithErrors') {
            Write-Warning "$($c.Collection): CompletedWithErrors. $($result.Errors -join ' ')"
        }
        else {
            Write-Verbose "$($c.Collection): $($result.Status), $($result.Detections) detection(s)."
        }
    }

    return $summary
}
