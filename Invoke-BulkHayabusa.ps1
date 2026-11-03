#Requires -Version 5.1

<#
.SYNOPSIS
    Runs Hayabusa across a folder of per-host KAPE collections.

.DESCRIPTION
    Point InputRoot at a parent folder holding one entry per host: a loose
    KAPE output folder, a ZIP, or a VHDX or VHD. Each host gets its own
    Hayabusa run, alert report and timeline under OutputRoot, and the results
    are rolled up into a cross-host triage view.

    Each top-level entry of InputRoot is a collection. Folders, .zip, .vhd
    and .vhdx are collections. Everything else is skipped. Collections are
    run one at a time, each into OutputRoot\<Collection>, and recorded in
    OutputRoot\run_manifest.csv keyed by collection name. Every run writes
    a provenance record to OutputRoot\_runs.

    A collection already Completed or CompletedWithErrors is skipped on a
    rerun unless -Force is given. One collection failing is recorded and
    the run moves on to the next.

    When the batch finishes, the cross-host rollup is rebuilt:
    triage_rules.csv, triage_hosts.csv and triage_dashboard.html under
    OutputRoot, along with combined_timeline.csv, every host's timeline in
    one file in time order, unless the config sets CombinedTimeline to
    $false.
    Invoke-HayabusaRollup.ps1 rebuilds the same files from an existing
    OutputRoot without rerunning anything.

    Settings are resolved in this order: command line, then the config file
    given by -ConfigPath, then built-in defaults.

    When the config sets RECmdPath, each collection's host identity is also
    read from its registry hives with RECmd while the collection is
    extracted or mounted, and identity_dashboard.html is written beside the
    triage dashboard. Without RECmdPath, host identity is not read.
    -IdentityOnly reads host identity alone, without running Hayabusa.

    The console shows a header for the run, any notes before it starts, a
    block for each host with a line per step as it finishes, and a summary
    table at the end, through the information stream, with live progress
    bars during long steps. Problems are warnings. Every run also writes
    the same lines, timestamped in UTC, to OutputRoot\_runs\run_<time>_<RunId>.log.
    -Verbose adds detail. -InformationAction SilentlyContinue hides the
    console lines, leaving the warnings, and the run log is still written.
    Nothing is returned unless -PassThru is given.

.PARAMETER InputRoot
    Parent folder holding one entry per host.

.PARAMETER OutputRoot
    Where per-host output, the manifest, run metadata and the rollup are
    written. Created if missing. Must not be inside InputRoot, or hold it.

.PARAMETER HayabusaPath
    Full path to hayabusa.exe.

.PARAMETER MinLevel
    Severity floor passed to Hayabusa: informational, low, medium, high,
    critical or emergency. Defaults to medium. When given on the
    command line it overrides MinLevel or ExactLevel from the config file.

.PARAMETER Threads
    Thread count passed to Hayabusa. Omit to let Hayabusa decide.

.PARAMETER Force
    Rerun collections already recorded as Completed or CompletedWithErrors.

.PARAMETER KeepArtifacts
    Keep the extracted ZIP and the differencing disk after each host
    finishes, for debugging. Disk images are always dismounted. Off by
    default.

.PARAMETER ConfigPath
    Optional engagement config file (.psd1). Loaded as data only with
    Import-PowerShellDataFile. See config\engagement.example.psd1.

.PARAMETER IdentityOnly
    Read each collection's host identity and write identity_dashboard.html,
    without running Hayabusa or building the triage dashboard. Needs
    RECmdPath in the config given with -ConfigPath, and no HayabusaPath.
    A collection whose identity is already Complete is skipped unless
    -Force is given. The manifest and run-meta are not written.

.PARAMETER PassThru
    Return an object describing the run, for scripting against. Without
    it the script returns nothing.

.PARAMETER Help
    Print a short usage summary and stop. -h does the same. Nothing is
    read or written.

.EXAMPLE
    .\Invoke-BulkHayabusa.ps1 -InputRoot D:\Cases\Case01\KAPE -OutputRoot D:\Cases\Case01\Output -HayabusaPath D:\Tools\hayabusa\hayabusa.exe

.EXAMPLE
    .\Invoke-BulkHayabusa.ps1 -InputRoot D:\Cases\Case01\KAPE -OutputRoot D:\Cases\Case01\Output -HayabusaPath D:\Tools\hayabusa\hayabusa.exe -ConfigPath D:\Cases\Case01\engagement.psd1 -MinLevel medium

.EXAMPLE
    .\Invoke-BulkHayabusa.ps1 -InputRoot D:\Cases\Case01\KAPE -OutputRoot D:\Cases\Case01\Output -ConfigPath D:\Cases\Case01\engagement.psd1 -IdentityOnly

.EXAMPLE
    $run = .\Invoke-BulkHayabusa.ps1 -InputRoot D:\Cases\Case01\KAPE -OutputRoot D:\Cases\Case01\Output -HayabusaPath D:\Tools\hayabusa\hayabusa.exe -PassThru
    $run.Summary.Failed

.EXAMPLE
    .\Invoke-BulkHayabusa.ps1 -Help

.OUTPUTS
    None, unless -PassThru is given. Then a PSCustomObject with RunId,
    ManifestPath, RunMetaPath, RunLogPath, Summary, the counts by outcome,
    Rollup, Identity and Collections. With -IdentityOnly it has Summary,
    Identity, RunLogPath and Collections.
#>
[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Run')]
    [Parameter(Mandatory, ParameterSetName = 'Identity')]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$InputRoot,

    [Parameter(Mandatory, ParameterSetName = 'Run')]
    [Parameter(Mandatory, ParameterSetName = 'Identity')]
    [ValidateNotNullOrEmpty()]
    [string]$OutputRoot,

    [Parameter(Mandatory, ParameterSetName = 'Run')]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$HayabusaPath,

    [Parameter(ParameterSetName = 'Run')]
    [ValidateSet('informational', 'low', 'medium', 'high', 'critical', 'emergency')]
    [string]$MinLevel = 'medium',

    [Parameter(ParameterSetName = 'Run')]
    [ValidateRange(1, 256)]
    [int]$Threads,

    [Parameter(ParameterSetName = 'Run')]
    [Parameter(ParameterSetName = 'Identity')]
    [switch]$Force,

    [Parameter(ParameterSetName = 'Run')]
    [Parameter(ParameterSetName = 'Identity')]
    [switch]$KeepArtifacts,

    [Parameter(ParameterSetName = 'Run')]
    [Parameter(ParameterSetName = 'Identity')]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$ConfigPath,

    [Parameter(Mandatory, ParameterSetName = 'Identity')]
    [switch]$IdentityOnly,

    [Parameter(ParameterSetName = 'Run')]
    [Parameter(ParameterSetName = 'Identity')]
    [switch]$PassThru,

    # In a set of its own, so -Help binds without asking for the required
    # parameters.
    [Parameter(ParameterSetName = 'Help')]
    [Alias('h')]
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Help) {
    @(
        'Invoke-BulkHayabusa.ps1: runs Hayabusa across a folder of per-host KAPE collections and builds a cross-host triage view.'
        ''
        'Usage:'
        '  .\Invoke-BulkHayabusa.ps1 -InputRoot <folder> -OutputRoot <folder> -HayabusaPath <hayabusa.exe> [options]'
        ''
        'Required:'
        '  -InputRoot      Parent folder holding one entry per host'
        '  -OutputRoot     Where everything is written. Created if missing. Must not be inside InputRoot, or hold it'
        '  -HayabusaPath   Full path to hayabusa.exe'
        ''
        'Options:'
        '  -MinLevel       Severity floor: informational, low, medium, high, critical or emergency. Default medium'
        '  -Threads        Thread count passed to Hayabusa. Leave it out to let Hayabusa decide'
        '  -Force          Rerun hosts that already finished'
        '  -KeepArtifacts  Keep extracted ZIPs and differencing disks after each host, for debugging'
        '  -ConfigPath     Engagement config .psd1 for ExactLevel, tag filters, a time window and more'
        '  -IdentityOnly   Read host identity with RECmd only, no Hayabusa. Needs RECmdPath in the config, not -HayabusaPath'
        '  -PassThru       Return an object describing the run, for scripting'
        ''
        'Examples:'
        '  .\Invoke-BulkHayabusa.ps1 -InputRoot D:\Cases\Case01\KAPE -OutputRoot D:\Cases\Case01\Output -HayabusaPath D:\Tools\hayabusa\hayabusa.exe'
        '  .\Invoke-BulkHayabusa.ps1 -InputRoot D:\Cases\Case01\KAPE -OutputRoot D:\Cases\Case01\Output -HayabusaPath D:\Tools\hayabusa\hayabusa.exe -MinLevel medium -ConfigPath D:\Cases\Case01\engagement.psd1'
        '  .\Invoke-BulkHayabusa.ps1 -InputRoot D:\Cases\Case01\KAPE -OutputRoot D:\Cases\Case01\Output -ConfigPath D:\Cases\Case01\engagement.psd1 -IdentityOnly'
        ''
        'For the complete help: Get-Help .\Invoke-BulkHayabusa.ps1 -Full'
    )
    return
}

# Progress and the end-of-run summary go to the information stream, which
# PowerShell hides by default. Show it unless the caller chose otherwise.
if (-not $PSBoundParameters.ContainsKey('InformationAction')) {
    $InformationPreference = 'Continue'
}

$ToolVersion = '0.11.0'

$libDir = Join-Path -Path $PSScriptRoot -ChildPath 'lib'
foreach ($lib in @('Paths', 'Console', 'Elevation', 'Config', 'Manifest', 'RunMeta', 'Archive', 'Discovery', 'DiskImage', 'Resolve', 'Hayabusa', 'Results', 'Batch', 'Rollup', 'CombinedTimeline', 'Dashboard', 'SparseFile', 'HostIdentity', 'IdentityDashboard')) {
    . (Join-Path -Path $libDir -ChildPath "$lib.ps1")
}

# Console lines are held until the run log opens, so the log starts with
# every one of them.
Initialize-ConsoleOutput -BufferLog
$runWatch = [System.Diagnostics.Stopwatch]::StartNew()

# Paths
$InputRoot = ConvertTo-NormalizedPath -Path $InputRoot
$OutputRoot = ConvertTo-NormalizedPath -Path $OutputRoot
if (-not $IdentityOnly) {
    $HayabusaPath = ConvertTo-NormalizedPath -Path $HayabusaPath
}

if (Test-PathIsWithin -Path $OutputRoot -Parent $InputRoot) {
    throw "OutputRoot ($OutputRoot) must not be inside InputRoot ($InputRoot). Output would be picked up as a host and written next to evidence."
}
# The reverse too: the tool creates and deletes files under OutputRoot, so
# evidence there, such as an image in a _diff folder kept by -KeepArtifacts,
# could share a path with a differencing disk it is about to clear.
if (Test-PathIsWithin -Path $InputRoot -Parent $OutputRoot) {
    throw "InputRoot ($InputRoot) must not be inside OutputRoot ($OutputRoot). The tool creates and deletes files under OutputRoot, so evidence there could be deleted. Move the evidence out of OutputRoot, or choose a different OutputRoot."
}

# Settings
$config = $null
if ($PSBoundParameters.ContainsKey('ConfigPath')) {
    $config = Import-EngagementConfig -Path (ConvertTo-NormalizedPath -Path $ConfigPath)
    Write-Verbose "Loaded config $($config.Path) (SHA256 $($config.Sha256))"
}

# Host identity is read only when the config names RECmd. A RECmdPath that
# is set but wrong stops the run here, before anything is written.
$recmdPath = Resolve-RECmdPath -Config $config
$combinedTimeline = Get-CombinedTimelineSetting -Config $config
if ($IdentityOnly -and $null -eq $recmdPath) {
    throw '-IdentityOnly needs RECmdPath, the full path of RECmd.exe, set in the engagement config given with -ConfigPath.'
}

# Warnings from checking the settings and reading InputRoot are shown as
# notes under Before the run, once the header is out. While information
# lines are on screen they're only recorded here, so nothing shows twice,
# and in quiet mode they're shown as warnings as they come.
$early = @{}
if (Test-ConsoleInformationShown) {
    $early['WarningAction'] = 'SilentlyContinue'
}
$settingWarnings = $null
$discoveryWarnings = $null
$heldWarningsShown = $early.Count -eq 0

# Everything up to the header can stop the run, and the warnings held back
# for Before the run would be lost with it, so on a stop they're written as
# warnings before the error goes on unchanged.
try {
    if ($IdentityOnly) {
        # Only the ZIP limits apply. Hayabusa and its settings aren't used.
        $limits = Resolve-ZipLimit -Config $config
    }
    else {
        $commandLine = @{}
        if ($PSBoundParameters.ContainsKey('MinLevel')) {
            $commandLine['MinLevel'] = $MinLevel
        }

        $resolved = Resolve-RunSetting -CommandLine $commandLine -Config $config -HayabusaPath $HayabusaPath -WarningVariable settingWarnings @early
    }

    $threadsValue = $null
    if ($PSBoundParameters.ContainsKey('Threads')) {
        $threadsValue = $Threads
    }

    # Discovery reads InputRoot and lists ZIP entries. Nothing is extracted,
    # mounted or written until the checks below pass.
    $collections = @(Get-InputCollection -InputRoot $InputRoot -WarningVariable discoveryWarnings @early)
    Assert-UniqueCollectionName -Collections $collections
    Assert-CollectionNameAllowed -Collections $collections
    Write-Verbose "Discovered $($collections.Count) collection(s)."

    # Fail before anything is written if disk images need an elevated session.
    Assert-ElevationForContainer -Collections $collections

    $hayabusaVersion = $null
    $rulesVersion = $null
    if (-not $IdentityOnly) {
        if (-not (Test-Path -LiteralPath $resolved.Selection.RulesPath)) {
            throw "RulesPath not found: $($resolved.Selection.RulesPath). Run 'hayabusa.exe update-rules' once at the start of the engagement, or set RulesPath in the config file."
        }
        # Provenance for run-meta. A failed version read is recorded, not fatal.
        $hayabusaVersion = Get-HayabusaVersion -HayabusaPath $HayabusaPath
        $rulesVersion = Get-RulesVersion -RulesPath $resolved.Selection.RulesPath
        Write-Verbose "Hayabusa: $($hayabusaVersion.Version). Rules: $($rulesVersion.Summary)."
    }

    # Run setup. From here on the run has an id and a log.
    if (-not (Test-Path -LiteralPath $OutputRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
        Write-Verbose "Created OutputRoot: $OutputRoot"
    }
    $runId = [guid]::NewGuid().ToString()
    $startedUtc = (Get-Date).ToUniversalTime()
    Open-ConsoleRunLog -Path (Get-RunLogPath -OutputRoot $OutputRoot -StartedUtc $startedUtc -RunId $runId)
    Write-Verbose "RunId $runId"
}
catch {
    if (-not $heldWarningsShown) {
        $heldWarningsShown = $true
        Write-HeldWarning -Record (@($settingWarnings) + @($discoveryWarnings))
    }
    throw
}

try {
    # Header
    $valueWidth = (Get-ConsoleUsableWidth) - 10
    $inputSummary = Get-ConsoleInputSummary -Collections $collections
    $header = [ordered]@{}
    $header['Input'] = "$(Format-ConsolePath -Path $InputRoot -Width ($valueWidth - $inputSummary.Length - 2)), $inputSummary"
    $header['Output'] = Format-ConsolePath -Path $OutputRoot -Width $valueWidth
    if ($IdentityOnly) {
        $title = "Hayabusa-Bulk-Runner $ToolVersion, reading host identity only, Hayabusa is not run"
    }
    else {
        $title = "Hayabusa-Bulk-Runner $ToolVersion, running Hayabusa"
        if ($null -ne $recmdPath) {
            $title += ' and reading host identity'
        }
        $number = Get-HayabusaVersionNumber -VersionLine $hayabusaVersion.Version
        if ($null -eq $number) {
            $number = 'version not read'
        }
        $header['Hayabusa'] = "$number, $(Format-ConsolePath -Path $HayabusaPath -Width ($valueWidth - $number.Length - 2))"
        $header['Rules'] = $rulesVersion.Summary
    }
    if ($null -ne $recmdPath) {
        $header['RECmd'] = Format-ConsolePath -Path $recmdPath -Width $valueWidth
    }
    Write-ConsoleHeader -Title $title -Field $header

    # Before the run, only when there's something to say.
    $unreadableZips = @($collections | Where-Object { $_.InputType -eq 'Zip' -and $null -ne $_.Zip -and -not $_.Zip.Readable })
    $imageCount = @($collections | Where-Object { $_.InputType -eq 'Vhd' -or $_.InputType -eq 'Vhdx' -or ($_.InputType -eq 'Zip' -and $null -ne $_.Zip -and $_.Zip.Readable -and @($_.Zip.ImageEntries).Count -gt 0) }).Count
    $notices = New-Object System.Collections.Generic.List[string]
    if (-not $IdentityOnly) {
        if ($null -ne $hayabusaVersion.Error) {
            $notices.Add("Could not read the Hayabusa version: $($hayabusaVersion.Error)")
        }
        $versionNotice = Get-HayabusaVersionNotice -VersionLine $hayabusaVersion.Version
        if ($null -ne $versionNotice) {
            $notices.Add($versionNotice)
        }
        $levelNotice = Get-SeverityLevelNotice -Selection $resolved.Selection
        if ($null -ne $levelNotice) {
            $notices.Add($levelNotice)
        }
    }
    $earlyWarnings = @(@($settingWarnings) + @($discoveryWarnings) | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_.Message })
    if ($earlyWarnings.Count -gt 0 -or $notices.Count -gt 0 -or $unreadableZips.Count -gt 0 -or $imageCount -gt 0) {
        Write-ConsoleSection -Title 'Before the run'
        foreach ($w in $earlyWarnings) {
            Write-ConsoleNotice -Warning $w -Recorded
        }
        $heldWarningsShown = $true
        foreach ($n in $notices) {
            Write-ConsoleNotice -Warning $n
        }
        # A ZIP this tool can't extract: one short line each, then the
        # advice once. The host's own closing line points back here.
        foreach ($z in $unreadableZips) {
            $reason = Get-ZipReadReasonText -Info $z.Zip
            Write-ConsoleNotice -Warning "$($z.Source) can't be extracted by this tool ($reason)." -Display "$($z.Source) can't be extracted, $reason."
        }
        if ($unreadableZips.Count -eq 1) {
            Write-ConsoleNote -Indent 4 -Text 'Extract it yourself and put the folder in InputRoot, then rerun and finished hosts are skipped.'
        }
        elseif ($unreadableZips.Count -gt 1) {
            Write-ConsoleNote -Indent 4 -Text 'Extract each one yourself and put its folder in InputRoot, then rerun and finished hosts are skipped.'
        }
        foreach ($z in $unreadableZips) {
            $images = @($z.Zip.ImageEntries)
            if ($images.Count -gt 0) {
                $leaf = ($images | ForEach-Object { ($_ -split '[\\/]')[-1] }) -join ', '
                Write-ConsoleNote -Indent 4 -Text "$($z.Source) holds a disk image, so put the extracted $leaf directly in InputRoot."
            }
        }
        # Each disk image is read in full twice, so say so before a long run.
        if ($imageCount -eq 1) {
            Write-ConsoleNote -Text '1 disk image is hashed before mounting and again after teardown, so it''s read in full twice.'
        }
        elseif ($imageCount -gt 1) {
            Write-ConsoleNote -Text "$imageCount disk images are hashed before mounting and again after teardown, so each is read in full twice."
        }
    }
    Write-ConsoleLine -Segment @('') -NoLog

    if ($IdentityOnly) {
        $identityBatch = Invoke-IdentityBatch -Collections $collections -OutputRoot $OutputRoot -RECmdPath $recmdPath -Limits $limits `
            -Force:$Force -KeepArtifacts:$KeepArtifacts

        $identityRecord = [ordered]@{ Dashboard = $null; HostCount = $null; Error = $null }
        $dashboardWarnings = $null
        try {
            $identityRollup = Invoke-IdentityRollup -OutputRoot $OutputRoot -Collection @($collections | ForEach-Object { $_.Collection }) -WarningVariable dashboardWarnings
            $identityRecord.Dashboard = $identityRollup.Dashboard
            $identityRecord.HostCount = $identityRollup.HostCount
        }
        catch {
            $identityRecord.Error = $_.Exception.Message
            Write-RunWarning -Message "Identity dashboard failed: $($_.Exception.Message)"
        }
        foreach ($w in @($dashboardWarnings)) {
            Write-ConsoleLogLine -Text "WARNING $w"
        }

        Write-ConsoleSummary -ShowIdentity
        Write-ConsoleLine -Segment @(("{0} processed, {1} complete, {2} partial, {3} failed, {4} with no registry hives, {5} skipped, in {6}." -f
                $identityBatch.Processed, $identityBatch.Complete, $identityBatch.Partial, $identityBatch.Failed, $identityBatch.NoRegistryHives, $identityBatch.Skipped,
                (Format-ConsoleDuration -Seconds $runWatch.Elapsed.TotalSeconds)))
        if ($null -eq $identityRecord.Error) {
            Write-ConsoleLine -Segment @('Identity dashboard   ', $identityRecord.Dashboard)
        }
        else {
            Write-ConsoleLine -Segment @('Identity dashboard   could not be built, see the warning above')
        }
        $runLog = Get-ConsoleRunLogPath
        if ($null -ne $runLog) {
            Write-ConsoleLine -Segment @('Run log              ', $runLog)
        }

        if ($PassThru) {
            [pscustomobject]@{
                Summary     = $identityBatch
                Identity    = $identityRecord
                RunLogPath  = $runLog
                Collections = $collections
            }
        }
        return
    }

    $manifestPath = Join-Path -Path $OutputRoot -ChildPath 'run_manifest.csv'
    Initialize-RunManifest -Path $manifestPath | Out-Null
    $added = Add-PendingCollection -Path $manifestPath -Collections $collections -RunId $runId
    Write-Verbose "Manifest: $added new collection(s) recorded as Pending."

    $runMeta = New-RunMeta `
        -RunId $runId `
        -StartedUtc $startedUtc `
        -ToolVersion $ToolVersion `
        -InputRoot $InputRoot `
        -OutputRoot $OutputRoot `
        -HayabusaPath $HayabusaPath `
        -Resolved $resolved `
        -Config $config `
        -Collections $collections `
        -HayabusaVersion $hayabusaVersion `
        -RulesVersion $rulesVersion `
        -Threads $threadsValue `
        -Force $Force.IsPresent `
        -KeepArtifacts $KeepArtifacts.IsPresent `
        -RunLogPath (Get-ConsoleRunLogPath)

    $runMetaPath = Get-RunMetaPath -OutputRoot $OutputRoot -StartedUtc $startedUtc -RunId $runId
    Save-RunMeta -Path $runMetaPath -RunMeta $runMeta | Out-Null

    Write-Verbose "Manifest: $manifestPath"
    Write-Verbose "Run metadata: $runMetaPath"

    $imageHashes = [ordered]@{}
    $batch = Invoke-CollectionBatch -Collections $collections -ManifestPath $manifestPath -OutputRoot $OutputRoot `
        -HayabusaPath $HayabusaPath -Resolved $resolved -Threads $threadsValue -RunId $runId `
        -Force:$Force -KeepArtifacts:$KeepArtifacts -ImageHash $imageHashes -RunMeta $runMeta -RunMetaPath $runMetaPath -RECmdPath $recmdPath
    Set-RunMetaImageHash -RunMeta $runMeta -ImageHash $imageHashes

    # A rollup failure is recorded and reported, and never hides the batch
    # results already in the manifest. The rollup's own warnings are shown
    # as it writes them and go in the run log after.
    $rollupRecord = [ordered]@{
        HostsCsv                    = $null
        RulesCsv                    = $null
        Dashboard                   = $null
        HostCount                   = $null
        RuleCount                   = $null
        CombinedTimeline            = $null
        CombinedTimelineRows        = $null
        CombinedTimelineHosts       = $null
        CombinedTimelineCollections = $null
        CombinedTimelineLeftOut     = $null
        CombinedTimelineError       = $null
        Error                       = $null
    }
    $combinedReason = 'the rollup failed'
    $rollupWarnings = $null
    try {
        $rollup = Invoke-Rollup -OutputRoot $OutputRoot -SkipCombinedTimeline:(-not $combinedTimeline) -WarningVariable rollupWarnings
        $rollupRecord.HostsCsv = $rollup.HostsCsv
        $rollupRecord.RulesCsv = $rollup.RulesCsv
        $rollupRecord.Dashboard = $rollup.Dashboard
        $rollupRecord.HostCount = $rollup.HostCount
        $rollupRecord.RuleCount = $rollup.RuleCount
        $rollupRecord.CombinedTimeline = $rollup.CombinedTimeline.Path
        $rollupRecord.CombinedTimelineRows = $rollup.CombinedTimeline.Rows
        $rollupRecord.CombinedTimelineHosts = $rollup.CombinedTimeline.Hosts
        $rollupRecord.CombinedTimelineCollections = $rollup.CombinedTimeline.Collections
        $rollupRecord.CombinedTimelineLeftOut = $rollup.CombinedTimeline.LeftOut
        $rollupRecord.CombinedTimelineError = $rollup.CombinedTimeline.Error
        $combinedReason = $rollup.CombinedTimeline.Reason
    }
    catch {
        $rollupRecord.Error = $_.Exception.Message
        Write-RunWarning -Message "Rollup failed: $($_.Exception.Message). Rebuild it with Invoke-HayabusaRollup.ps1 -OutputRoot $OutputRoot"
    }
    foreach ($w in @($rollupWarnings)) {
        Write-ConsoleLogLine -Text "WARNING $w"
    }

    # Only when RECmd is set. Kept out of run-meta, and a failure here never
    # hides the triage results.
    $identityRecord = $null
    if ($null -ne $recmdPath) {
        $identityRecord = [ordered]@{ Dashboard = $null; HostCount = $null; Error = $null }
        $dashboardWarnings = $null
        try {
            $identityRollup = Invoke-IdentityRollup -OutputRoot $OutputRoot -Collection @($collections | ForEach-Object { $_.Collection }) -WarningVariable dashboardWarnings
            $identityRecord.Dashboard = $identityRollup.Dashboard
            $identityRecord.HostCount = $identityRollup.HostCount
        }
        catch {
            $identityRecord.Error = $_.Exception.Message
            Write-RunWarning -Message "Identity dashboard failed: $($_.Exception.Message)"
        }
        foreach ($w in @($dashboardWarnings)) {
            Write-ConsoleLogLine -Text "WARNING $w"
        }
    }

    $runMeta['CompletedUtc'] = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
    $runMeta['Summary'] = $batch
    $runMeta['Rollup'] = $rollupRecord
    Save-RunMeta -Path $runMetaPath -RunMeta $runMeta -Update | Out-Null

    Write-ConsoleSummary -ShowStatus -ShowIdentity:($null -ne $recmdPath)
    Write-ConsoleLine -Segment @(("{0} processed, {1} completed, {2} completed with errors, {3} failed, {4} skipped, in {5}." -f
            $batch.Processed, $batch.Completed, $batch.CompletedWithErrors, $batch.Failed, $batch.Skipped,
            (Format-ConsoleDuration -Seconds $runWatch.Elapsed.TotalSeconds)))
    if ($null -eq $rollupRecord.Error) {
        Write-ConsoleLine -Segment @('Triage dashboard     ', $rollupRecord.Dashboard)
    }
    else {
        Write-ConsoleLine -Segment @('Triage dashboard     could not be built, see the warning above')
    }
    if ($null -ne $rollupRecord.CombinedTimeline) {
        Write-ConsoleLine -Segment @('Combined timeline    ', $rollupRecord.CombinedTimeline, ", $(Format-CombinedCoverage -Rows $rollupRecord.CombinedTimelineRows -Hosts $rollupRecord.CombinedTimelineHosts -Collections $rollupRecord.CombinedTimelineCollections)")
    }
    elseif ($null -ne $rollupRecord.CombinedTimelineError -or $null -ne $rollupRecord.Error) {
        Write-ConsoleLine -Segment @("Combined timeline    not built, $combinedReason, see the warning above")
    }
    else {
        Write-ConsoleLine -Segment @("Combined timeline    not built, $combinedReason")
    }
    if ($null -ne $identityRecord) {
        if ($null -eq $identityRecord.Error) {
            Write-ConsoleLine -Segment @('Identity dashboard   ', $identityRecord.Dashboard)
        }
        else {
            Write-ConsoleLine -Segment @('Identity dashboard   could not be built, see the warning above')
        }
    }
    $runLog = Get-ConsoleRunLogPath
    if ($null -ne $runLog) {
        Write-ConsoleLine -Segment @('Run log              ', $runLog)
    }

    if ($PassThru) {
        [pscustomobject]@{
            RunId        = $runId
            ManifestPath = $manifestPath
            RunMetaPath  = $runMetaPath
            RunLogPath   = $runLog
            Summary      = $batch
            Rollup       = $rollupRecord
            Identity     = $identityRecord
            Collections  = $collections
        }
    }
}
catch {
    # A run that stops on an error says why in its log too, and any warning
    # held back for Before the run is written first.
    if (-not $heldWarningsShown) {
        $heldWarningsShown = $true
        Write-HeldWarning -Record (@($settingWarnings) + @($discoveryWarnings))
    }
    Write-ConsoleLogLine -Text "ERROR $($_.Exception.Message)"
    throw
}
finally {
    Complete-ConsoleProgress
    Close-ConsoleRunLog
}
