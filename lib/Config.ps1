$script:ConfigKeys = @(
    'RulesPath'
    'MinLevel'
    'ExactLevel'
    'IncludeTags'
    'ExcludeTags'
    'TimelineStart'
    'TimelineEnd'
    'Profile'
    'ZipMaxUncompressedGB'
    'ZipMaxRatio'
)

$script:SeverityLevels = @('informational', 'low', 'medium', 'high', 'critical')
$script:OutputProfiles = @('standard', 'verbose')

# Hayabusa expects --timeline-start and --timeline-end in this form,
# for example "2026-01-01 00:00:00 +00:00".
$script:TimelineFormat = 'yyyy-MM-dd HH:mm:ss zzz'

function Import-EngagementConfig {
    <#
    .SYNOPSIS
        Loads an engagement config file as data.
    .DESCRIPTION
        Uses Import-PowerShellDataFile, which only accepts literal data
        (strings, numbers, arrays, hashtables) and never runs code from the
        file. Unknown keys are rejected so a typo cannot silently drop a
        filter.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Config file not found: $Path"
    }

    try {
        $data = Import-PowerShellDataFile -LiteralPath $Path
    }
    catch {
        throw "Config file could not be read as data: $Path. $($_.Exception.Message)"
    }

    $unknown = @($data.Keys | Where-Object { $script:ConfigKeys -notcontains $_ })
    if ($unknown.Count -gt 0) {
        throw ("Config file {0} has unknown key(s): {1}. Allowed keys: {2}" -f
            $Path, ($unknown -join ', '), ($script:ConfigKeys -join ', '))
    }

    [pscustomobject]@{
        Path      = $Path
        Directory = (Split-Path -Path $Path -Parent)
        Sha256    = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
        Values    = $data
    }
}

function ConvertTo-SeverityLevel {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Value
    )

    $level = $Value.Trim().ToLowerInvariant()
    if ($script:SeverityLevels -notcontains $level) {
        throw ("{0} '{1}' is not valid. Use one of: {2}" -f $Name, $Value, ($script:SeverityLevels -join ', '))
    }
    return $level
}

function ConvertTo-TagList {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [AllowNull()]
        [object]$Value
    )

    foreach ($item in @($Value)) {
        if ($null -eq $item) {
            continue
        }
        $tag = ([string]$item).Trim()
        if ($tag.Length -eq 0) {
            throw "$Name contains an empty tag."
        }
        $tag
    }
}

function ConvertTo-TimelineBound {
    [CmdletBinding()]
    [OutputType([System.DateTimeOffset])]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Value
    )

    $parsed = [System.DateTimeOffset]::MinValue
    $ok = [System.DateTimeOffset]::TryParseExact(
        $Value.Trim(),
        $script:TimelineFormat,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::None,
        [ref]$parsed)

    if (-not $ok) {
        throw ("{0} '{1}' is not valid. Use the form 'yyyy-MM-dd HH:mm:ss +00:00'." -f $Name, $Value)
    }
    return $parsed
}

function ConvertTo-PositiveNumber {
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [AllowNull()]
        [object]$Value,

        [Parameter(Mandatory)]
        [double]$Minimum
    )

    $number = 0.0
    $ok = [double]::TryParse([string]$Value, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$number)
    if (-not $ok -or [double]::IsNaN($number) -or [double]::IsInfinity($number) -or $number -lt $Minimum) {
        throw ("{0} '{1}' is not valid. Use a number of at least {2}." -f $Name, $Value, $Minimum)
    }
    return $number
}

function Resolve-RunSetting {
    <#
    .SYNOPSIS
        Merges command line values, config file values and defaults.
    .DESCRIPTION
        Precedence per setting is command line, then config file, then
        default. Returns the resolved selection settings, the ZIP limits,
        and where each setting came from, so run-meta records exactly what a
        run used.

        ZipMaxUncompressedGB caps the declared uncompressed size of one ZIP.
        ZipMaxRatio caps its overall compression ratio. Both guard against
        zip bombs and may need raising for a ZIP that wraps a large
        fixed-size disk image.

        MinLevel and ExactLevel are mutually exclusive. A config file may set
        one or the other, not both. If the config sets ExactLevel and
        -MinLevel is given on the command line, the command line wins and
        ExactLevel is dropped.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$CommandLine,

        [AllowNull()]
        [pscustomobject]$Config,

        [Parameter(Mandatory)]
        [string]$HayabusaPath
    )

    $configValues = @{}
    if ($null -ne $Config) {
        $configValues = $Config.Values
    }

    if ($configValues.ContainsKey('MinLevel') -and $configValues.ContainsKey('ExactLevel')) {
        throw "Config file $($Config.Path) sets both MinLevel and ExactLevel. Set one or the other."
    }

    $defaults = @{
        RulesPath            = (Join-Path -Path (Split-Path -Path $HayabusaPath -Parent) -ChildPath 'rules')
        MinLevel             = 'high'
        ExactLevel           = $null
        IncludeTags          = @()
        ExcludeTags          = @()
        TimelineStart        = $null
        TimelineEnd          = $null
        Profile              = 'standard'
        ZipMaxUncompressedGB = 100
        ZipMaxRatio          = 250
    }

    $values = @{}
    $sources = [ordered]@{}
    foreach ($key in $script:ConfigKeys) {
        if ($CommandLine.ContainsKey($key)) {
            $values[$key] = $CommandLine[$key]
            $sources[$key] = 'CommandLine'
        }
        elseif ($configValues.ContainsKey($key)) {
            $values[$key] = $configValues[$key]
            $sources[$key] = 'Config'
        }
        else {
            $values[$key] = $defaults[$key]
            $sources[$key] = 'Default'
        }
    }

    # Severity: exactly one of MinLevel or ExactLevel ends up set.
    if ($null -ne $values['ExactLevel'] -and $sources['ExactLevel'] -ne 'Default') {
        if ($sources['MinLevel'] -eq 'CommandLine') {
            $values['ExactLevel'] = $null
            $sources['ExactLevel'] = 'OverriddenByCommandLine'
        }
        else {
            $values['MinLevel'] = $null
            $sources['MinLevel'] = 'NotUsed'
        }
    }

    $minLevel = $null
    if ($null -ne $values['MinLevel']) {
        $minLevel = ConvertTo-SeverityLevel -Name 'MinLevel' -Value ([string]$values['MinLevel'])
    }
    $exactLevel = $null
    if ($null -ne $values['ExactLevel']) {
        $exactLevel = ConvertTo-SeverityLevel -Name 'ExactLevel' -Value ([string]$values['ExactLevel'])
    }

    $outputProfile = ([string]$values['Profile']).Trim().ToLowerInvariant()
    if ($script:OutputProfiles -notcontains $outputProfile) {
        throw ("Profile '{0}' is not valid. Use one of: {1}" -f $values['Profile'], ($script:OutputProfiles -join ', '))
    }

    [string[]]$includeTags = @(ConvertTo-TagList -Name 'IncludeTags' -Value $values['IncludeTags'])
    [string[]]$excludeTags = @(ConvertTo-TagList -Name 'ExcludeTags' -Value $values['ExcludeTags'])
    $overlap = @($includeTags | Where-Object { $excludeTags -contains $_ })
    if ($overlap.Count -gt 0) {
        throw "Tag(s) appear in both IncludeTags and ExcludeTags: $($overlap -join ', ')"
    }

    $timelineStart = $null
    $timelineEnd = $null
    if ($null -ne $values['TimelineStart']) {
        $start = ConvertTo-TimelineBound -Name 'TimelineStart' -Value ([string]$values['TimelineStart'])
        $timelineStart = ([string]$values['TimelineStart']).Trim()
    }
    if ($null -ne $values['TimelineEnd']) {
        $end = ConvertTo-TimelineBound -Name 'TimelineEnd' -Value ([string]$values['TimelineEnd'])
        $timelineEnd = ([string]$values['TimelineEnd']).Trim()
    }
    if ($null -ne $timelineStart -and $null -ne $timelineEnd -and $start -ge $end) {
        throw "TimelineStart ($timelineStart) must be earlier than TimelineEnd ($timelineEnd)."
    }

    # A relative RulesPath in a config file is taken relative to that file,
    # so the same config gives the same result from any working directory.
    $rulesPath = [string]$values['RulesPath']
    if ($sources['RulesPath'] -eq 'Config' -and -not [System.IO.Path]::IsPathRooted($rulesPath)) {
        $rulesPath = Join-Path -Path $Config.Directory -ChildPath $rulesPath
    }
    $rulesPath = ConvertTo-NormalizedPath -Path $rulesPath

    if (-not (Test-Path -LiteralPath $rulesPath)) {
        if ($sources['RulesPath'] -eq 'Default') {
            Write-Warning "No rules found at $rulesPath. Run 'hayabusa.exe update-rules' once at the start of the engagement, or set RulesPath in the config file."
        }
        else {
            throw "RulesPath not found: $rulesPath"
        }
    }

    $zipMaxGB = ConvertTo-PositiveNumber -Name 'ZipMaxUncompressedGB' -Value $values['ZipMaxUncompressedGB'] -Minimum 0.001
    $zipMaxRatio = ConvertTo-PositiveNumber -Name 'ZipMaxRatio' -Value $values['ZipMaxRatio'] -Minimum 1

    [pscustomobject]@{
        Selection = [ordered]@{
            RulesPath     = $rulesPath
            MinLevel      = $minLevel
            ExactLevel    = $exactLevel
            IncludeTags   = $includeTags
            ExcludeTags   = $excludeTags
            TimelineStart = $timelineStart
            TimelineEnd   = $timelineEnd
            Profile       = $outputProfile
        }
        Limits    = [ordered]@{
            ZipMaxUncompressedGB    = $zipMaxGB
            ZipMaxUncompressedBytes = [long]($zipMaxGB * 1GB)
            ZipMaxRatio             = $zipMaxRatio
        }
        Sources   = $sources
    }
}
