$script:RunMetaSchemaVersion = 6

# Deep enough for every nested object in run-meta. ConvertTo-Json defaults
# to a depth of 2 and silently flattens anything deeper.
$script:RunMetaJsonDepth = 10

function Get-RunMetaPath {
    <#
    .SYNOPSIS
        Returns OutputRoot\_runs\run_meta_<utc-stamp>_<RunId>.json for a run.
    .DESCRIPTION
        The RunId makes the name unique even for two runs started in the
        same second, and matches the RunId column in the manifest.
    #>
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

    $stamp = $StartedUtc.ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    $runsDir = Join-Path -Path $OutputRoot -ChildPath '_runs'
    return (Join-Path -Path $runsDir -ChildPath "run_meta_$($stamp)_$RunId.json")
}

function New-RunMeta {
    <#
    .SYNOPSIS
        Builds the provenance record for one run.
    .DESCRIPTION
        Filled from the resolved settings, the collections discovered for
        this run, the version line from hayabusa help stored verbatim, and the
        rule set's newest file and count. CompletedUtc, Summary and Rollup
        are set when the batch and rollup finish. Nothing is written to disk here.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory object only.')]
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [string]$RunId,

        [Parameter(Mandatory)]
        [datetime]$StartedUtc,

        [Parameter(Mandatory)]
        [string]$ToolVersion,

        [Parameter(Mandatory)]
        [string]$InputRoot,

        [Parameter(Mandatory)]
        [string]$OutputRoot,

        [Parameter(Mandatory)]
        [string]$HayabusaPath,

        [Parameter(Mandatory)]
        [pscustomobject]$Resolved,

        [AllowNull()]
        [pscustomobject]$Config,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Collections,

        [Parameter(Mandatory)]
        [pscustomobject]$HayabusaVersion,

        [Parameter(Mandatory)]
        [pscustomobject]$RulesVersion,

        [AllowNull()]
        [object]$Threads,

        [bool]$Force,
        [bool]$KeepArtifacts
    )

    $configRecord = $null
    if ($null -ne $Config) {
        $configRecord = [ordered]@{
            Path   = $Config.Path
            Sha256 = $Config.Sha256
        }
    }

    [ordered]@{
        SchemaVersion   = $script:RunMetaSchemaVersion
        RunId           = $RunId
        StartedUtc      = $StartedUtc.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        CompletedUtc    = $null
        Summary         = $null
        Rollup          = $null
        Tool            = [ordered]@{
            Name              = 'Invoke-BulkHayabusa'
            Version           = $ToolVersion
            PowerShellVersion = $PSVersionTable.PSVersion.ToString()
            PowerShellEdition = $PSVersionTable.PSEdition
        }
        InputRoot       = $InputRoot
        OutputRoot      = $OutputRoot
        Config          = $configRecord
        Hayabusa        = [ordered]@{
            Path              = $HayabusaPath
            Version           = $HayabusaVersion.Version
            VersionError      = $HayabusaVersion.Error
            RulesPath         = $Resolved.Selection.RulesPath
            RulesVersion      = $RulesVersion.Summary
            NewestRuleFileUtc = $RulesVersion.NewestRuleFileUtc
            RuleFileCount     = $RulesVersion.RuleFileCount
        }
        Selection       = $Resolved.Selection
        Limits          = $Resolved.Limits
        SettingSource   = $Resolved.Sources
        OutputUtc       = $true
        Options         = [ordered]@{
            Threads       = $Threads
            Force         = $Force
            KeepArtifacts = $KeepArtifacts
        }
        Collections     = @($Collections | ForEach-Object {
                [ordered]@{
                    Collection = $_.Collection
                    Source     = $_.Source
                    InputType  = $_.InputType
                }
            })
    }
}

function Save-RunMeta {
    <#
    .SYNOPSIS
        Writes run-meta as UTF-8 JSON without a BOM.
    .DESCRIPTION
        A new file is created with CreateNew, so an existing run's record is
        never overwritten. Use -Update to rewrite the current run's own file,
        for example to set CompletedUtc.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$RunMeta,

        [switch]$Update
    )

    if (-not $PSCmdlet.ShouldProcess($Path, 'Write run metadata')) {
        return
    }

    $json = ConvertTo-Json -InputObject $RunMeta -Depth $script:RunMetaJsonDepth
    $encoding = New-Object System.Text.UTF8Encoding($false)

    $dir = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    if ($Update) {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            throw "Cannot update run metadata that does not exist: $Path"
        }
        [System.IO.File]::WriteAllText($Path, $json, $encoding)
        return $Path
    }

    $stream = $null
    try {
        $stream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $bytes = $encoding.GetBytes($json)
        $stream.Write($bytes, 0, $bytes.Length)
    }
    catch [System.IO.IOException] {
        if (Test-Path -LiteralPath $Path) {
            throw "Run metadata already exists and will not be overwritten: $Path"
        }
        throw
    }
    finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }

    return $Path
}
