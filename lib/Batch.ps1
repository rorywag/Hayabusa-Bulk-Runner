# Rows in these states are not run again unless -Force is given.
$script:FinishedStatuses = @('Completed', 'CompletedWithErrors')

function Remove-PreviousHostLog {
    <#
    .SYNOPSIS
        Removes a collection's log from an earlier run when it is run again.
    .DESCRIPTION
        Runs before anything else for the collection. A rerun that fails
        before Hayabusa starts, for example an image that won't mount or a
        ZIP over a limit, then can't leave the earlier run's log, with its
        results summary, linked from the new Failed row. The run writes its
        own log when Hayabusa runs, or when a ZIP is refused.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Path
    )

    if ((Test-Path -LiteralPath $Path.Log -PathType Leaf) -and $PSCmdlet.ShouldProcess($Path.Log, 'Remove the previous run''s log')) {
        try {
            [System.IO.File]::Delete($Path.Log)
        }
        catch {
            throw "Could not remove the previous run's $([System.IO.Path]::GetFileName($Path.Log)): $($_.Exception.Message)"
        }
    }
}

function Remove-PreviousHostOutput {
    <#
    .SYNOPSIS
        Removes a collection's earlier timeline and report before Hayabusa
        runs for it again.
    .DESCRIPTION
        Without this, a rerun where Hayabusa writes nothing would be counted
        from the previous run's CSV and linked to its report. Only the two
        files Hayabusa writes are removed, from the collection's own output
        folder. The log is removed earlier, by Remove-PreviousHostLog.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Path
    )

    foreach ($file in @($Path.Csv, $Path.Html)) {
        if ((Test-Path -LiteralPath $file -PathType Leaf) -and $PSCmdlet.ShouldProcess($file, 'Remove the previous run''s output')) {
            try {
                [System.IO.File]::Delete($file)
            }
            catch {
                throw "Could not remove the previous run's $([System.IO.Path]::GetFileName($file)) before running Hayabusa again: $($_.Exception.Message)"
            }
        }
    }
}

function Invoke-CollectionRun {
    <#
    .SYNOPSIS
        Runs Hayabusa for one collection and records the outcome.
    .DESCRIPTION
        Marks the manifest row Running, creates the per-host output folder,
        resolves the input, removes the collection's earlier timeline and
        report, runs Hayabusa and parses the CSV. Teardown runs
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

    # A failure to mark the row Running is recorded and the run goes ahead.
    # The final write below tries again, and only if that fails too is this
    # recorded.
    $runningMarkError = $null
    try {
        Set-RunManifestEntry -Path $ManifestPath -Collection $Collection.Collection -Source $Collection.Source `
            -RunId $RunId -InputType $Collection.InputType -Status 'Running' -WarningMessage @(Join-UniqueMessage -Message $warnings.ToArray())
    }
    catch {
        $runningMarkError = "Could not mark the manifest row Running: $($_.Exception.Message)"
        Write-Verbose "$($Collection.Collection): $runningMarkError"
    }

    $paths = Get-CollectionOutputPath -OutputRoot $OutputRoot -Collection $Collection.Collection
    $resolvedInput = $null
    $summary = $null
    $exitCode = $null
    $status = 'Failed'

    try {
        # First, so however this run fails, the row can't link an earlier
        # run's log.
        Remove-PreviousHostLog -Path $paths

        # Checked before resolving, so a ZIP is not extracted for nothing.
        Assert-HayabusaHost

        if (-not (Test-Path -LiteralPath $paths.Directory -PathType Container)) {
            New-Item -ItemType Directory -Path $paths.Directory -Force | Out-Null
        }

        # An unreadable ZIP is refused by Resolve-CollectionInput below. The
        # analyst-facing views carry only the short guidance, so the
        # technical detail (entry, method) goes in this collection's log.
        if (Test-ZipUnreadable -Collection $Collection) {
            try {
                Write-ZipRefusalLog -Collection $Collection -LogPath $paths.Log
            }
            catch {
                Write-Verbose "Could not write $($paths.Log): $($_.Exception.Message)"
            }
        }

        $resolvedInput = Resolve-CollectionInput -Collection $Collection -OutputRoot $OutputRoot `
            -MaxUncompressedBytes $Resolved.Limits.ZipMaxUncompressedBytes -MaxRatio $Resolved.Limits.ZipMaxRatio `
            -KeepArtifacts:$KeepArtifacts
        foreach ($w in @($resolvedInput.Warnings)) {
            $warnings.Add($w)
        }

        $arguments = New-HayabusaArgument -InputPath $resolvedInput.Path -CsvPath $paths.Csv -HtmlPath $paths.Html `
            -Selection $Resolved.Selection -Threads $Threads
        Remove-PreviousHostOutput -Path $paths
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
    $finalWarnings = @()

    # Recording the result is guarded too, so a failure here marks this one
    # collection Failed and can never stop the batch.
    try {
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

        # A message already recorded as an error is not repeated as a
        # warning, so the manifest and dashboard show it once.
        $errorText = $errors.ToArray()
        $finalWarnings = @(Join-UniqueMessage -Message $warnings.ToArray() | Where-Object { $errorText -notcontains $_ })

        Set-RunManifestEntry -Path $ManifestPath -Collection $Collection.Collection -Source $Collection.Source `
            -RunId $RunId -InputType $Collection.InputType -Status $status -HostName $hostName `
            -Detections $detections -Emergency $emergency -Critical $critical -High $high `
            -WarningMessage $finalWarnings -ErrorMessage $errors.ToArray() -DurationSec $timer.Elapsed.TotalSeconds
    }
    catch {
        if ($null -ne $runningMarkError) {
            $errors.Add($runningMarkError)
        }
        $errors.Add("Recording the result failed: $($_.Exception.Message)")
        $status = 'Failed'
        try {
            Set-RunManifestEntry -Path $ManifestPath -Collection $Collection.Collection -Source $Collection.Source `
                -RunId $RunId -InputType $Collection.InputType -Status 'Failed' -ErrorMessage $errors.ToArray() `
                -DurationSec $timer.Elapsed.TotalSeconds
        }
        catch {
            Write-Warning "$($Collection.Collection): could not record the result in the manifest: $($_.Exception.Message)"
        }
    }
    $timer.Stop()

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

function Test-ZipUnreadable {
    # True for a ZIP collection that discovery found this tool cannot extract.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Collection
    )

    return ($Collection.InputType -eq 'Zip' -and $null -ne $Collection.Zip -and -not $Collection.Zip.Readable)
}

function Write-ZipRefusalLog {
    <#
    .SYNOPSIS
        Writes the per-host log for a ZIP that will not be extracted.
    .DESCRIPTION
        Holds the short guidance plus the technical detail from discovery,
        such as the offending entry and compression method, which is kept
        out of the console, manifest and dashboard. Hayabusa is not run.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Writes this collection''s own log under OutputRoot.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Collection,

        [Parameter(Mandatory)]
        [string]$LogPath
    )

    $lines = @(
        "Started: $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture))"
        "Source: $($Collection.Source)"
        (Get-ZipGuidance -Source $Collection.Source -Info $Collection.Zip)
        "Detail: $($Collection.Zip.ReadError)"
        'Hayabusa was not run.'
    )
    Write-TextFileAtomic -Path $LogPath -Text (($lines -join "`r`n") + "`r`n") | Out-Null
}

function Format-DetectionCount {
    # "1 detection", "10 detections".
    [CmdletBinding()]
    [OutputType([string])]
    param([int]$Count)

    if ($Count -eq 1) {
        return '1 detection'
    }
    return "$Count detections"
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

        Each collection gets one progress line, such as
        "[2/4] HOST01 ... Completed, 10 detections". Completed and skipped
        lines go to the information stream. Failed and CompletedWithErrors
        lines are warnings, except a ZIP already reported at startup as
        unreadable, which is not warned about twice.

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

        $prefix = "[$index/$($Collections.Count)] $($c.Collection) ..."
        if (-not $Force -and $null -ne $row -and $script:FinishedStatuses -contains $row.Status) {
            Write-Information "$prefix skipped, already $($row.Status)"
            Write-Verbose "$($c.Collection): use -Force to rerun."
            $summary.Skipped++
            continue
        }

        Write-Verbose "[$index/$($Collections.Count)] $($c.Collection): running."
        $summary.Processed++
        try {
            $result = Invoke-CollectionRun -Collection $c -OutputRoot $OutputRoot -HayabusaPath $HayabusaPath `
                -Resolved $Resolved -Threads $Threads -RunId $RunId -ManifestPath $ManifestPath -KeepArtifacts:$KeepArtifacts
        }
        catch {
            # Last line of defence: one collection must never abort the run.
            $result = [pscustomobject]@{ Collection = $c.Collection; Status = 'Failed'; Detections = 0; Errors = @("Unexpected error: $($_.Exception.Message)") }
        }
        $summary[$result.Status]++

        $counted = Format-DetectionCount -Count $result.Detections
        if ($result.Status -eq 'Failed') {
            if ((Test-ZipUnreadable -Collection $c) -and (@($result.Errors) -contains (Get-ZipGuidance -Source $c.Source -Info $c.Zip))) {
                Write-Information "$prefix Failed: ZIP not extracted, see the warning at the start"
            }
            else {
                Write-Warning "$prefix Failed: $($result.Errors -join ' ')"
            }
        }
        elseif ($result.Status -eq 'CompletedWithErrors') {
            Write-Warning "$prefix CompletedWithErrors, ${counted}: $($result.Errors -join ' ')"
        }
        else {
            Write-Information "$prefix $($result.Status), $counted"
        }
    }

    return $summary
}
