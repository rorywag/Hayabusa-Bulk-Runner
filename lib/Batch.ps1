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

        Completed: Hayabusa exited 0 and wrote a CSV. An empty CSV, which is
        what Hayabusa writes when nothing matches, is Completed with zero
        counts.
        CompletedWithErrors: Hayabusa exited non-zero but still wrote a CSV.
        The counts are kept and the exit code goes in Error.
        Failed: resolve, run, parse or teardown failed, or Hayabusa wrote no
        CSV. With exit 0 that means Hayabusa stopped on an error, and its
        [ERROR] line from stderr goes in Error.

        A disk image is hashed with SHA-256 before it is mounted and again
        after teardown. If the two differ, the collection is Failed whatever
        else happened, and the evidence integrity error leads its Error.
        The hash record is returned as ImageHash.

        With RECmdPath, the collection's host identity is read from its
        registry hives too, from the same extracted or mounted path, and
        saved beside its other output. Its status is returned as
        IdentityStatus, null when identity wasn't read. Reading identity
        never changes the collection's status, manifest row or run-meta.

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

        [switch]$KeepArtifacts,

        [string]$RECmdPath
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
    # Owned here, not by the resolved input, so a hash taken before a mount
    # that then fails is still checked below.
    $imageHashes = New-Object System.Collections.Generic.List[object]
    $resolvedInput = $null
    $summary = $null
    $exitCode = $null
    $status = 'Failed'
    $identityStatus = $null

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
            -KeepArtifacts:$KeepArtifacts -ImageHashRecord $imageHashes
        foreach ($w in @($resolvedInput.Warnings)) {
            $warnings.Add($w)
        }

        # Read where the collection already is, extracted or mounted, so it
        # is never extracted or mounted a second time. This never throws.
        if (-not [string]::IsNullOrEmpty($RECmdPath)) {
            $identityStatus = (Invoke-CollectionIdentity -Collection $Collection.Collection -CollectionRoot $resolvedInput.Path -OutputRoot $OutputRoot -RECmdPath $RECmdPath).Status
        }

        $arguments = New-HayabusaArgument -InputPath $resolvedInput.Path -CsvPath $paths.Csv -HtmlPath $paths.Html `
            -Selection $Resolved.Selection -Threads $Threads
        Remove-PreviousHostOutput -Path $paths
        $exitCode = Invoke-HayabusaProcess -HayabusaPath $HayabusaPath -Argument $arguments -LogPath $paths.Log
        if ($exitCode -ne 0) {
            $errors.Add("Hayabusa exited with code $exitCode. See $($paths.Log).")
        }

        $summary = Get-HayabusaResultSummary -CsvPath $paths.Csv

        if ($exitCode -eq 0 -and $summary.Exists) {
            $status = 'Completed'
        }
        elseif ($exitCode -eq 0) {
            # A run that matches nothing still writes an empty CSV. Hayabusa
            # exits 0 without one when it stopped on an error, such as a time
            # window it can't parse, and says why only on stderr.
            $reason = Get-HayabusaLogError -LogPath $paths.Log
            if ($null -eq $reason) {
                $errors.Add("Hayabusa exited 0 but wrote no CSV, and printed no error. See $($paths.Log).")
            }
            else {
                $errors.Add("Hayabusa exited 0 but wrote no CSV: $($reason.TrimEnd('.')). See $($paths.Log).")
            }
            $status = 'Failed'
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

    # The image must read the same after the run as before it. If it does
    # not, nothing else about this collection matters as much.
    $imageHash = $null
    if ($imageHashes.Count -gt 0) {
        $imageHash = $imageHashes[0]
        if ($imageHash.Match -eq $false) {
            $errors.Insert(0, (Get-ImageHashMismatchMessage -Record $imageHash))
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
        Collection     = $Collection.Collection
        Status         = $status
        HostName       = $hostName
        Detections     = $detections
        Emergency      = $emergency
        Critical       = $critical
        High           = $high
        ExitCode       = $exitCode
        Warnings       = $finalWarnings
        Errors         = $errors.ToArray()
        DurationSec    = $timer.Elapsed.TotalSeconds
        OutputPath     = $paths.Directory
        ImageHash      = $imageHash
        IdentityStatus = $identityStatus
    }
}

function Get-ImageHashMismatchMessage {
    # The error for an image whose hash changed during the run. It starts
    # with $script:EvidenceChangedPrefix, which the dashboard looks for.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Record
    )

    return ("{0}: the SHA-256 of {1} changed during this run, from {2} before it was mounted to {3} after teardown. The image was written to and can't be treated as unchanged. Stop and check it against your original hash before relying on it." -f
        $script:EvidenceChangedPrefix, $Record.ImagePath, $Record.Before, $Record.After)
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

        With RECmdPath, each processed collection's host identity is read
        as it runs, and its progress line ends with the identity status.

        Returns a summary of the counts by outcome. If ImageHash is given,
        each processed collection's image hash record is stored in it by
        collection name, null for a collection with no disk image.

        If RunMeta and RunMetaPath are given, the run's record is rewritten
        after each processed collection, with the counts so far and every
        image hash taken so far, so an interrupted run loses nothing about
        the hosts it finished. A failed write is warned about and the batch
        carries on.
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
        [switch]$KeepArtifacts,

        [System.Collections.IDictionary]$ImageHash,

        [System.Collections.IDictionary]$RunMeta,

        [string]$RunMetaPath,

        [string]$RECmdPath
    )

    # Hashes are needed to update run-meta, even if the caller asked for none.
    if ($null -ne $RunMeta -and $null -eq $ImageHash) {
        $ImageHash = [ordered]@{}
    }

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
                -Resolved $Resolved -Threads $Threads -RunId $RunId -ManifestPath $ManifestPath -KeepArtifacts:$KeepArtifacts -RECmdPath $RECmdPath
        }
        catch {
            # Last line of defence: one collection must never abort the run.
            $result = [pscustomobject]@{ Collection = $c.Collection; Status = 'Failed'; Detections = 0; Errors = @("Unexpected error: $($_.Exception.Message)") }
        }
        $summary[$result.Status]++
        if ($null -ne $ImageHash) {
            $record = $null
            if ($result.PSObject.Properties['ImageHash']) {
                $record = $result.ImageHash
            }
            $ImageHash[$c.Collection] = $record
        }
        if ($null -ne $RunMeta -and -not [string]::IsNullOrEmpty($RunMetaPath)) {
            try {
                Set-RunMetaImageHash -RunMeta $RunMeta -ImageHash $ImageHash
                $RunMeta['Summary'] = $summary
                Save-RunMeta -Path $RunMetaPath -RunMeta $RunMeta -Update | Out-Null
            }
            catch {
                Write-Warning "$($c.Collection): could not update the run metadata at ${RunMetaPath}: $($_.Exception.Message)"
            }
        }

        $counted = Format-DetectionCount -Count $result.Detections
        if ($result.PSObject.Properties['IdentityStatus'] -and $null -ne $result.IdentityStatus) {
            $counted += ", identity $($result.IdentityStatus)"
        }
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

function Invoke-CollectionIdentityRun {
    <#
    .SYNOPSIS
        Reads one collection's host identity without running Hayabusa.
    .DESCRIPTION
        Extracts or mounts the collection exactly as a normal run does,
        reads its host identity, and tears it down in a finally block. A
        disk image is hashed before it is mounted and after teardown, and a
        changed hash leads the identity's notes. Anything that stops the
        hives being read, such as a ZIP this tool can't extract, is saved
        as a Failed identity saying why. Never throws. The manifest and
        run-meta are not touched.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Collection,

        [Parameter(Mandatory)]
        [string]$OutputRoot,

        [Parameter(Mandatory)]
        [string]$RECmdPath,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Limits,

        [switch]$KeepArtifacts
    )

    $imageHashes = New-Object System.Collections.Generic.List[object]
    $errors = New-Object System.Collections.Generic.List[string]
    $resolvedInput = $null
    $identity = $null
    try {
        # Checked before resolving, so a ZIP is not extracted for nothing.
        Assert-RECmdHost
        $resolvedInput = Resolve-CollectionInput -Collection $Collection -OutputRoot $OutputRoot `
            -MaxUncompressedBytes $Limits.ZipMaxUncompressedBytes -MaxRatio $Limits.ZipMaxRatio `
            -KeepArtifacts:$KeepArtifacts -ImageHashRecord $imageHashes
        $identity = Invoke-CollectionIdentity -Collection $Collection.Collection -CollectionRoot $resolvedInput.Path -OutputRoot $OutputRoot -RECmdPath $RECmdPath
    }
    catch {
        $errors.Add($_.Exception.Message)
    }
    finally {
        try {
            Invoke-CollectionCleanup -Resolved $resolvedInput
        }
        catch {
            $errors.Add("Teardown: $($_.Exception.Message)")
        }
    }

    $imageHash = $null
    if ($imageHashes.Count -gt 0) {
        $imageHash = $imageHashes[0]
        if ($imageHash.Match -eq $false) {
            $errors.Insert(0, (Get-ImageHashMismatchMessage -Record $imageHash))
        }
    }

    if ($null -eq $identity) {
        $identity = New-HostIdentityRecord -Collection $Collection.Collection -RECmdPath $RECmdPath -Status 'Failed' -Note $errors.ToArray()
    }
    elseif ($errors.Count -gt 0) {
        $identity['Notes'] = [string[]](@($errors.ToArray()) + @($identity['Notes']))
    }
    if ($errors.Count -gt 0) {
        try {
            Save-HostIdentity -OutputRoot $OutputRoot -Identity $identity | Out-Null
        }
        catch {
            Write-Warning "$($Collection.Collection): could not save the host identity: $($_.Exception.Message)"
        }
    }

    [pscustomobject]@{
        Collection = $Collection.Collection
        Status     = $identity['Status']
        Hostname   = $identity['Hostname']
        Notes      = @($identity['Notes'])
        Errors     = $errors.ToArray()
        ImageHash  = $imageHash
    }
}

function Invoke-IdentityBatch {
    <#
    .SYNOPSIS
        Reads every discovered collection's host identity, without running
        Hayabusa.
    .DESCRIPTION
        For -IdentityOnly. A collection whose identity is already Complete,
        or NoRegistryHives, is skipped unless -Force is given, the same way
        a normal run skips a finished host. Each collection gets one
        progress line, such as "[2/4] HOST01 ... identity Complete,
        WS01". Failed lines are warnings, except a ZIP already reported at
        startup as unreadable. Returns the counts by outcome.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Collections,

        [Parameter(Mandatory)]
        [string]$OutputRoot,

        [Parameter(Mandatory)]
        [string]$RECmdPath,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Limits,

        [switch]$Force,
        [switch]$KeepArtifacts
    )

    $summary = [ordered]@{
        Discovered      = $Collections.Count
        Processed       = 0
        Complete        = 0
        Partial         = 0
        Failed          = 0
        NoRegistryHives = 0
        Skipped         = 0
    }

    $index = 0
    foreach ($c in $Collections) {
        $index++
        $prefix = "[$index/$($Collections.Count)] $($c.Collection) ..."
        if (-not $Force) {
            $existing = Read-HostIdentity -OutputRoot $OutputRoot -Collection $c.Collection
            $done = $null
            if ($null -ne $existing.Identity) {
                $done = [string](Get-JsonValue -Object $existing.Identity -Name 'Status')
            }
            if ($done -eq 'Complete' -or $done -eq 'NoRegistryHives') {
                Write-Information "$prefix skipped, identity already $done"
                Write-Verbose "$($c.Collection): use -Force to read it again."
                $summary.Skipped++
                continue
            }
        }

        $summary.Processed++
        try {
            $result = Invoke-CollectionIdentityRun -Collection $c -OutputRoot $OutputRoot -RECmdPath $RECmdPath -Limits $Limits -KeepArtifacts:$KeepArtifacts
        }
        catch {
            # Last line of defence: one collection must never abort the run.
            $result = [pscustomobject]@{ Collection = $c.Collection; Status = 'Failed'; Hostname = $null; Notes = @("Unexpected error: $($_.Exception.Message)"); Errors = @(); ImageHash = $null }
        }
        if ($summary.Contains([string]$result.Status)) {
            $summary[[string]$result.Status]++
        }
        else {
            $summary.Failed++
        }

        $name = ''
        if (-not [string]::IsNullOrEmpty($result.Hostname)) {
            $name = ", $($result.Hostname)"
        }
        $evidence = @($result.Errors | Where-Object { ([string]$_).StartsWith($script:EvidenceChangedPrefix) })
        if ($evidence.Count -gt 0) {
            Write-Warning "$prefix identity $($result.Status)${name}: $($evidence[0])"
        }
        elseif ($result.Status -eq 'Failed') {
            if ((Test-ZipUnreadable -Collection $c) -and (@($result.Notes) -contains (Get-ZipGuidance -Source $c.Source -Info $c.Zip))) {
                Write-Information "$prefix identity Failed: ZIP not extracted, see the warning at the start"
            }
            else {
                Write-Warning "$prefix identity Failed: $(@($result.Notes) -join ' ')"
            }
        }
        else {
            Write-Information "$prefix identity $($result.Status)$name"
        }
    }

    return $summary
}
