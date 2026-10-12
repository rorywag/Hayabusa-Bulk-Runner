# PSScriptAnalyzer settings for the test suite:
#
#     Invoke-ScriptAnalyzer -Path ./tests -Recurse -Settings ./tests/PSScriptAnalyzerSettings.psd1
#
# Same as the root settings, with two rules left out:
#
# - PSUseCompatibleCommands: the 5.1 profile only knows the Pester 3.4 that
#   ships with Windows, so every Pester 5 It, Should and Mock is reported.
#   PSUseCompatibleSyntax and PSUseCompatibleTypes still apply.
# - PSUseShouldProcessForStateChangingFunctions: the New-* helpers only
#   build fixtures under $TestDrive.
@{
    IncludeDefaultRules = $true
    ExcludeRules        = @(
        'PSUseCompatibleCommands'
        'PSUseShouldProcessForStateChangingFunctions'
    )
    Rules               = @{
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.0')
        }
        PSUseCompatibleTypes  = @{
            Enable         = $true
            TargetProfiles = @('win-48_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework')
        }
    }
}
