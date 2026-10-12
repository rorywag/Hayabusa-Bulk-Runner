BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers/TestHelpers.ps1')
    $script:pd = New-TestDirectory (Join-TestPath $TestDrive 'parse')
    function script:Csv([string]$Name, [string[]]$Lines, [switch]$Bom) {
        $p = Join-TestPath $pd $Name
        [System.IO.File]::WriteAllLines($p, $Lines, (New-Object System.Text.UTF8Encoding($Bom.IsPresent)))
        $p
    }
}

Describe 'Level names' {
    It 'normalises <Level> to <Expected>' -ForEach @(
        @{ Level = 'EMER'; Expected = 'emergency' }, @{ Level = 'Emergency'; Expected = 'emergency' }, @{ Level = ' emergency '; Expected = 'emergency' }
        @{ Level = 'CRIT'; Expected = 'critical' }, @{ Level = 'Critical'; Expected = 'critical' }, @{ Level = 'High'; Expected = 'high' }
        @{ Level = 'MED'; Expected = 'medium' }, @{ Level = 'medium'; Expected = 'medium' }, @{ Level = 'Low'; Expected = 'low' }
        @{ Level = 'INFO'; Expected = 'informational' }, @{ Level = 'Informational'; Expected = 'informational' }, @{ Level = 'Weird'; Expected = 'weird' }
    ) {
        ConvertTo-SeverityName -Level $Level | Should -BeExactly $Expected
    }
}

Describe 'Get-HayabusaResultSummary' {
    It 'counts by level and picks the single Computer as Host' {
        $s = Get-HayabusaResultSummary -CsvPath (Csv 'n.csv' (@($TimelineHeader) + @(New-TimelineRow 'WS01' 'crit' 'A') + @(New-TimelineRowSet 'WS01' 'high' 'B' 2) + @(New-TimelineRow 'WS01' 'med' 'C') + @(New-TimelineRow 'WS01' 'low' 'D')))
        $s.Detections | Should -Be 5
        $s.Critical | Should -Be 1
        $s.High | Should -Be 2
        $h = Resolve-HostName -Computers $s.Computers
        $h.HostName | Should -Be 'WS01'
        $h.Warning | Should -BeNullOrEmpty
    }
    It 'counts all six levels from the static fixture, short and full forms' {
        $s = Get-HayabusaResultSummary -CsvPath (Join-Path $FixtureRoot 'six_levels_timeline.csv')
        $s.Detections | Should -Be 12
        $s.Emergency | Should -Be 3
        $s.Critical | Should -Be 2
        $s.High | Should -Be 2
    }
    It 'surfaces multiple Computer values as [multiple] with counts, case-insensitively' {
        $lines = @($TimelineHeader) + @(New-TimelineRowSet 'WS01' 'high' 'A' 2) + @(New-TimelineRow 'ws01' 'high' 'A') + @(New-TimelineRowSet 'WS01.corp.local' 'crit' 'B' 2) + @(New-TimelineRow 'WS01' 'med' 'C') + @(New-TimelineRow '' 'high' 'D')
        $s = Get-HayabusaResultSummary -CsvPath (Csv 'm.csv' $lines)
        $h = Resolve-HostName -Computers $s.Computers
        $s.Detections | Should -Be 7
        $h.HostName | Should -BeExactly '[multiple]'
        $h.Warning | Should -BeExactly 'Multiple Computer values: WS01 (4), WS01.corp.local (2)'
    }
    It 'cuts a long Computer list at 20' {
        $lines = @($TimelineHeader) + @(1..25 | ForEach-Object { New-TimelineRow ('PC{0:00}' -f $_) 'high' 'R' })
        $h = Resolve-HostName -Computers (Get-HayabusaResultSummary -CsvPath (Csv 'many.csv' $lines)).Computers
        $h.Warning | Should -BeLike '*, and 5 more'
        ([regex]::Matches($h.Warning, 'PC\d\d \(1\)')).Count | Should -Be 20
    }
    It 'treats header-only and zero-byte files as empty, with a blank Host' {
        $s = Get-HayabusaResultSummary -CsvPath (Csv 'h.csv' @($TimelineHeader))
        $s.Exists | Should -BeTrue
        $s.Empty | Should -BeTrue
        (Resolve-HostName -Computers $s.Computers).HostName | Should -Be ''
        $z = Join-TestPath $pd 'z.csv'; [System.IO.File]::WriteAllBytes($z, (New-Object byte[] 0))
        (Get-HayabusaResultSummary -CsvPath $z).Empty | Should -BeTrue
    }
    It 'reports a missing file as not existing' {
        (Get-HayabusaResultSummary -CsvPath (Join-TestPath $pd 'nope.csv')).Exists | Should -BeFalse
    }
    It 'refuses a CSV missing the required columns' {
        Get-ThrownMessage { Get-HayabusaResultSummary -CsvPath (Csv 'bad.csv' @('"Timestamp","RuleTitle"', '"x","y"')) } | Should -BeLike '*missing column(s) Level, Computer*'
    }
    It 'handles a BOM and an unquoted header' {
        $s = Get-HayabusaResultSummary -CsvPath (Csv 'bom.csv' @('Timestamp,Computer,Level,RuleTitle', '2026,WS02,high,R') -Bom)
        $s.Detections | Should -Be 1
        $s.Computers.Contains('WS02') | Should -BeTrue
    }
}

Describe 'Join-UniqueMessage' {
    It 'drops blanks and duplicates and keeps order' {
        ((Join-UniqueMessage -Message @('b', $null, 'a', ' ', 'b', 'c ')) -join ',') | Should -Be 'b,a,c'
    }
}
