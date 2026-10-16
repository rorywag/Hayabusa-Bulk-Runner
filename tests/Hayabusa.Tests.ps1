BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers/TestHelpers.ps1')
    $script:sel = [ordered]@{ RulesPath = 'D:\Tools\hayabusa\rules'; MinLevel = 'high'; ExactLevel = $null; IncludeTags = [string[]]@(); ExcludeTags = [string[]]@(); TimelineStart = $null; TimelineEnd = $null; Profile = 'standard' }
    function script:Sel([hashtable]$Over) {
        $s = [ordered]@{}
        foreach ($k in $sel.Keys) { $s[$k] = $sel[$k] }
        foreach ($k in $Over.Keys) { $s[$k] = $Over[$k] }
        $s
    }
    $script:b = @{ InputPath = 'X:\'; CsvPath = 'D:\Case Out\HOST01\HOST01_timeline.csv'; HtmlPath = 'D:\Case Out\HOST01\HOST01_report.html' }
    $script:hb = New-FakeHayabusa -Directory (Join-TestPath $TestDrive 'tool')
}

Describe 'Argument builder' {
    It 'builds the default argument order' {
        $a = New-HayabusaArgument @b -Selection (Sel @{}) -Threads $null
        ($a -join ' | ') | Should -BeExactly 'dfir-timeline | -d | X:\ | -w | -K | -p | standard | -U | -t | csv | -o | D:\Case Out\HOST01\HOST01_timeline.csv | -H | D:\Case Out\HOST01\HOST01_report.html | -s | -X | -C | -r | D:\Tools\hayabusa\rules | -m | high'
    }
    It 'passes a drive root as its own unchanged argument' {
        (New-HayabusaArgument @b -Selection (Sel @{}) -Threads $null)[2] | Should -BeExactly 'X:\'
    }
    It 'uses -e for ExactLevel and never both' {
        $a = New-HayabusaArgument @b -Selection (Sel @{ MinLevel = $null; ExactLevel = 'critical' }) -Threads $null
        ($a[-2..-1] -join ' ') | Should -Be '-e critical'
        $a | Should -Not -Contain '-m'
    }
    It 'passes emergency through -m and -e' {
        ((New-HayabusaArgument @b -Selection (Sel @{ MinLevel = 'emergency' }) -Threads $null)[-2..-1] -join ' ') | Should -Be '-m emergency'
        ((New-HayabusaArgument @b -Selection (Sel @{ MinLevel = $null; ExactLevel = 'emergency' }) -Threads $null)[-2..-1] -join ' ') | Should -Be '-e emergency'
    }
    It 'adds threads, include tags and the time window only when set' {
        $a = New-HayabusaArgument @b -Selection (Sel @{ Profile = 'verbose'; IncludeTags = [string[]]@('attack.credential_access', 'attack.lateral_movement'); TimelineStart = '2026-01-01 00:00:00 +00:00'; TimelineEnd = '2026-01-31 23:59:59 +00:00' }) -Threads 8
        $a[6] | Should -Be 'verbose'
        (($a | Select-Object -Skip 21) -join ' | ') | Should -BeExactly '--threads | 8 | --include-tag | attack.credential_access,attack.lateral_movement | --timeline-start | 2026-01-01 00:00:00 +00:00 | --timeline-end | 2026-01-31 23:59:59 +00:00'
        $a | Should -Not -Contain '--exclude-tag'
        @(New-HayabusaArgument @b -Selection (Sel @{}) -Threads $null | Where-Object { $_ -like '--*' }).Count | Should -Be 0
    }
    It 'passes exclude tags alone as one comma-separated value' {
        $a = New-HayabusaArgument @b -Selection (Sel @{ ExcludeTags = [string[]]@('attack.discovery', 'attack.collection') }) -Threads $null
        (($a | Select-Object -Skip 21) -join ' | ') | Should -BeExactly '--exclude-tag | attack.discovery,attack.collection'
        $a | Should -Not -Contain '--include-tag'
    }
    It 'refuses include and exclude tags together, as Hayabusa 4.1.0 does' {
        Get-ThrownMessage { New-HayabusaArgument @b -Selection (Sel @{ IncludeTags = [string[]]@('a'); ExcludeTags = [string[]]@('b') }) -Threads $null } | Should -BeLike '*IncludeTags or ExcludeTags, not both*'
    }
    It 'keeps a path with spaces as one argument' {
        (New-HayabusaArgument -InputPath 'D:\Case Out\_work\HOST 1' -CsvPath 'c.csv' -HtmlPath 'h.html' -Selection (Sel @{}) -Threads $null)[2] | Should -BeExactly 'D:\Case Out\_work\HOST 1'
    }
    It 'refuses <Case>' -ForEach @(
        @{ Case = 'both levels'; Over = @{ ExactLevel = 'low' }; InPath = 'X:\'; Like = '*Exactly one*' }
        @{ Case = 'neither level'; Over = @{ MinLevel = $null }; InPath = 'X:\'; Like = '*Exactly one*' }
        @{ Case = 'whitespace with a trailing backslash'; Over = @{}; InPath = 'D:\Case Out\'; Like = '*whitespace and ends in a backslash*' }
        @{ Case = 'a double quote'; Over = @{}; InPath = 'D:\a"b'; Like = '*double quote*' }
        @{ Case = 'an empty RulesPath'; Over = @{ RulesPath = '' }; InPath = 'X:\'; Like = '*is empty*' }
    ) {
        Get-ThrownMessage { New-HayabusaArgument -InputPath $InPath -CsvPath 'c' -HtmlPath 'h' -Selection (Sel $Over) -Threads $null } | Should -BeLike $Like
    }
}

Describe 'Version from the help banner' {
    BeforeEach { Mock Assert-HayabusaHost { } }

    It 'stores the banner line verbatim and skips the logo' {
        $v = Get-HayabusaVersion -HayabusaPath $hb
        $v.Version | Should -BeExactly $FakeVersionLine
        $v.ExitCode | Should -Be 0
        $v.Error | Should -BeNullOrEmpty
        $v.PSObject.Properties.Name | Should -Not -Contain 'Output'
    }
    It 'returns null with a reason when there is no banner, ignoring a later mention' {
        $env:FAKE_NO_BANNER = '1'
        try { $v = Get-HayabusaVersion -HayabusaPath $hb } finally { Remove-Item Env:\FAKE_NO_BANNER }
        $v.Version | Should -BeNullOrEmpty
        $v.Error | Should -BeLike "No line matching 'Hayabusa v<version>'*"
    }
    It 'matches an indented banner' {
        $env:FAKE_HELP_MODE = 'indented'
        try { $v = Get-HayabusaVersion -HayabusaPath $hb } finally { Remove-Item Env:\FAKE_HELP_MODE }
        $v.Version | Should -BeExactly $FakeVersionLine
    }
    It 'returns null when nothing matches' {
        $env:FAKE_HELP_MODE = 'silent'
        try { $v = Get-HayabusaVersion -HayabusaPath $hb } finally { Remove-Item Env:\FAKE_HELP_MODE }
        $v.Version | Should -BeNullOrEmpty
    }
    It 'keeps the version and records a non-zero exit' {
        $env:FAKE_VERSION_FAIL = '1'
        try { $v = Get-HayabusaVersion -HayabusaPath $hb } finally { Remove-Item Env:\FAKE_VERSION_FAIL }
        $v.Version | Should -BeExactly $FakeVersionLine
        $v.ExitCode | Should -Be 1
        $v.Error | Should -BeLike '*exited with code 1. Version line was still read.'
    }
}

Describe 'Version off Windows' {
    It 'is recorded as an error, not fatal' {
        Mock Test-IsWindowsHost { $false }
        $v = Get-HayabusaVersion -HayabusaPath $hb
        $v.Version | Should -BeNullOrEmpty
        $v.Error | Should -Be 'Running Hayabusa requires Windows.'
    }
}

Describe 'Rules version' {
    It 'counts rule files and finds the newest, ignoring other files' {
        $rules = New-TestDirectory (Join-TestPath $TestDrive 'rules')
        foreach ($n in 'a.yml', 'b.yml', 'sub/c.yml', 'sub/d.yaml', 'readme.txt') { Write-TestText -Path (Join-TestPath $rules $n) -Line @('x') | Out-Null }
        $newest = New-Object DateTime 2026, 9, 30, 12, 0, 0, ([DateTimeKind]::Utc)
        $old = New-Object DateTime 2026, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc)
        (Get-Item -LiteralPath (Join-TestPath $rules 'sub' 'c.yml')).LastWriteTimeUtc = $newest
        foreach ($n in 'a.yml', 'b.yml', 'sub/d.yaml', 'readme.txt') { (Get-Item -LiteralPath (Join-TestPath $rules $n)).LastWriteTimeUtc = $old }
        $v = Get-RulesVersion -RulesPath $rules
        $v.RuleFileCount | Should -Be 4
        $v.NewestRuleFileUtc | Should -Be '2026-09-30T12:00:00Z'
        $v.Summary | Should -Be 'newest rule file 2026-09-30T12:00:00Z, 4 rule files'
        (Get-RulesVersion -RulesPath (Join-TestPath $rules 'a.yml')).RuleFileCount | Should -Be 1
    }
}

Describe 'Native capture' {
    It 'passes every argument intact, captures stdout and stderr, and the real exit code' {
        $in = New-FakeHost -InputRoot (Join-TestPath $TestDrive 'nc') -Name 'HOST 01' -Behavior "EXIT=3`nCSV=r.csv`nSTDERR=[ERROR] rules failed" -Files @{ 'r.csv' = @($TimelineHeader) }
        $o = New-TestDirectory (Join-TestPath $TestDrive 'nco')
        $argList = @('dfir-timeline', '-d', $in, '-o', (Join-TestPath $o 'x.csv'), '-H', (Join-TestPath $o 'x.html'), '-m', 'high')
        $lines = New-Object System.Collections.Generic.List[string]
        $exit = Invoke-NativeCapture -FilePath $hb -Argument $argList -OnLine { param($l) $lines.Add($l) }
        $exit | Should -Be 3
        @(Get-Content -LiteralPath (Join-TestPath $o 'x.args')) | Should -Be $argList
        @($lines | Where-Object { $_ -like 'Results Summary: fake run over*' }).Count | Should -Be 1
        $lines | Should -Contain '[stderr] [ERROR] rules failed'
        @($lines | Where-Object { $_ -match "$([char]27)" }).Count | Should -Be 0
    }
    It 'fails like Hayabusa 4.1.0 when given both tag filters' {
        $in = New-FakeHost -InputRoot (Join-TestPath $TestDrive 'nc3') -Name 'H' -Behavior "EXIT=0`nCSV=none"
        $o = New-TestDirectory (Join-TestPath $TestDrive 'nco3')
        $lines = New-Object System.Collections.Generic.List[string]
        $exit = Invoke-NativeCapture -FilePath $hb -Argument @('dfir-timeline', '-d', $in, '-o', (Join-TestPath $o 'x.csv'), '--include-tag', 'a', '--exclude-tag', 'b') -OnLine { param($l) $lines.Add($l) }
        $exit | Should -Be 2
        $lines | Should -Contain "[stderr] error: the argument '--include-tag <TAG...>' cannot be used with '--exclude-tag <TAG...>'"
        Test-Path -LiteralPath (Join-TestPath $o 'x.args') | Should -BeFalse
    }
    It 'does not stop on stderr under ErrorActionPreference Stop' {
        $ErrorActionPreference = 'Stop'
        $in = New-FakeHost -InputRoot (Join-TestPath $TestDrive 'nc2') -Name 'H' -Behavior "EXIT=0`nSTDERR=warning line"
        { Invoke-NativeCapture -FilePath $hb -Argument @('dfir-timeline', '-d', $in) -OnLine { param($l) $null = $l } } | Should -Not -Throw
    }
}

Describe 'Error from the log' {
    BeforeAll {
        function script:New-StderrLog([string]$Name, [string[]]$Stderr) {
            $lines = @('Started (UTC): 2026-10-16T00:00:00Z', '--- output ---', 'Results Summary: x')
            $lines += @($Stderr | ForEach-Object { "[stderr] $_" })
            $lines += @('--- end ---', 'Exit code: 0')
            Write-TestText -Path (Join-TestPath $TestDrive "$Name.log") -Line $lines
        }
    }
    It 'returns the [ERROR] lines without the prefix, ahead of other stderr' {
        $log = New-StderrLog 'err' @('warning: noisy', '[ERROR] No .evtx files were found.', '', 'System.Management.Automation.RemoteException')
        Get-HayabusaLogError -LogPath $log | Should -BeExactly 'No .evtx files were found.'
    }
    It 'falls back to the other stderr lines, up to three' {
        $log = New-StderrLog 'other' @('one', 'two', 'three', 'four')
        Get-HayabusaLogError -LogPath $log | Should -BeExactly 'one / two / three'
    }
    It 'returns null when stderr was empty or there is no log' {
        Get-HayabusaLogError -LogPath (New-StderrLog 'none' @('', 'System.Management.Automation.RemoteException')) | Should -BeNullOrEmpty
        Get-HayabusaLogError -LogPath (Join-TestPath $TestDrive 'missing.log') | Should -BeNullOrEmpty
    }
}

Describe 'Tested version in the docs' {
    It 'matches the tested version between every tested-version marker in <File>' -ForEach @(
        @{ File = 'README.md' }
        @{ File = 'docs/USAGE.md' }
    ) {
        $text = [System.IO.File]::ReadAllText((Join-Path -Path $script:RepoRoot -ChildPath $File))
        $values = @([regex]::Matches($text, '<!--tested-version-->(.*?)<!--/tested-version-->') | ForEach-Object { $_.Groups[1].Value })
        $values.Count | Should -BeGreaterThan 0
        ([regex]::Matches($text, '<!--tested-version-->')).Count | Should -Be $values.Count -Because 'every marker is closed'
        ([regex]::Matches($text, '<!--/tested-version-->')).Count | Should -Be $values.Count -Because 'every marker is opened'
        foreach ($v in $values) {
            $v | Should -BeExactly $TestedHayabusaVersion
        }
    }
}
