# Engagement config for Invoke-BulkHayabusa.ps1
#
# Copy this file, rename it, and pass it with -ConfigPath. Real configs are
# git-ignored. Only this example file is tracked, so keep it free of real
# client paths and names.
#
# Loaded with Import-PowerShellDataFile, so it may only contain literal
# values. Values given on the command line override values set here.
# Unknown keys are rejected.

@{
    # Rule directory or single rule file. Omit to use the rules folder beside
    # hayabusa.exe. A relative path is taken relative to this file.
    # RulesPath = 'D:\Tools\hayabusa\rules'

    # Severity floor: informational, low, medium, high or critical.
    # Set MinLevel or ExactLevel, not both.
    MinLevel = 'high'
    # ExactLevel = 'critical'

    # Sigma tag filters. Leave empty to run all rules.
    IncludeTags = @()
    ExcludeTags = @()

    # Optional time window, in the form 'yyyy-MM-dd HH:mm:ss +00:00'.
    # TimelineStart = '2026-01-01 00:00:00 +00:00'
    # TimelineEnd   = '2026-01-31 23:59:59 +00:00'

    # Output profile: standard or verbose.
    Profile = 'standard'

    # ZIP safety limits, checked before anything is extracted. A ZIP over
    # either limit is refused. Raise them for a ZIP that wraps a large
    # fixed-size disk image, which can be both very large and very
    # compressible.
    ZipMaxUncompressedGB = 100
    ZipMaxRatio          = 250
}
