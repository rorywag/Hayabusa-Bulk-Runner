# The console output and run log, lib\Console.ps1. Control characters are
# built with [char], since Windows PowerShell 5.1 has no `e escape.

BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers/TestHelpers.ps1')
    $script:esc = [string][char]27
    $script:bel = [string][char]7

    function script:Get-ConsoleOutput {
        # Runs Script so its information lines reach -InformationVariable.
        [CmdletBinding()]
        param([Parameter(Mandatory)][scriptblock]$Script)
        . $Script
    }

    function script:Get-PieceText([object[]]$Piece) {
        # The plain text of a line built from pieces.
        return (-join @($Piece | ForEach-Object { if ($_ -is [System.Collections.IDictionary]) { $_['Text'] } else { [string]$_ } }))
    }
}

Describe 'ConvertTo-ConsoleText' {
    It 'removes <Name>' -ForEach @(
        @{ Name = 'a CSI sequence that clears the screen'; Text = "WS01$([char]27)[2JX"; Want = 'WS01X' }
        @{ Name = 'a CSI colour sequence'; Text = "$([char]27)[31mRED$([char]27)[0m"; Want = 'RED' }
        @{ Name = 'a cursor move'; Text = "A$([char]27)[10;1HB"; Want = 'AB' }
        @{ Name = 'an OSC sequence that sets the window title, ended by BEL'; Text = "A$([char]27)]0;owned$([char]7)B"; Want = 'AB' }
        @{ Name = 'an OSC sequence ended by the string terminator'; Text = "A$([char]27)]2;owned$([char]27)\B"; Want = 'AB' }
        @{ Name = 'an OSC hyperlink'; Text = "$([char]27)]8;;http://evil.example$([char]27)\click$([char]27)]8;;$([char]27)\"; Want = 'click' }
        @{ Name = 'an unterminated OSC sequence, to the end'; Text = "A$([char]27)]0;owned"; Want = 'A' }
        @{ Name = 'a C1 CSI'; Text = "A$([char]0x9B)31mB"; Want = 'AB' }
        @{ Name = 'a C1 OSC'; Text = "A$([char]0x9D)0;owned$([char]7)B"; Want = 'AB' }
        @{ Name = 'a lone escape and the character after it'; Text = "A$([char]27)cB"; Want = 'AB' }
        @{ Name = 'other C0 controls'; Text = "A$([char]0)$([char]7)$([char]8)B"; Want = 'AB' }
        @{ Name = 'DEL'; Text = "A$([char]0x7F)B"; Want = 'AB' }
        @{ Name = 'other C1 controls'; Text = "A$([char]0x80)$([char]0x85)$([char]0x8D)B"; Want = 'A B' }
        @{ Name = 'a C1 string sequence, such as APC'; Text = "A$([char]0x9F)hidden$([char]0x9C)B"; Want = 'AB' }
        @{ Name = 'bidi overrides'; Text = "A$([char]0x202E)exe.txt$([char]0x202C)B"; Want = 'Aexe.txtB' }
        @{ Name = 'bidi embeddings and isolates'; Text = "$([char]0x202A)$([char]0x202B)$([char]0x202D)A$([char]0x2066)$([char]0x2067)$([char]0x2068)$([char]0x2069)B"; Want = 'AB' }
        @{ Name = 'a zero-width space inside a name'; Text = "WS$([char]0x200B)01"; Want = 'WS01' }
        @{ Name = 'a right-to-left mark inside a name'; Text = "WS$([char]0x200F)01"; Want = 'WS01' }
        @{ Name = 'an Arabic letter mark inside a name'; Text = "WS$([char]0x061C)01"; Want = 'WS01' }
        @{ Name = 'a byte order mark inside a name'; Text = "WS$([char]0xFEFF)01"; Want = 'WS01' }
        @{ Name = 'the other zero-width and direction marks'; Text = "W$([char]0x200C)$([char]0x200D)$([char]0x200E)S$([char]0x2060)01"; Want = 'WS01' }
        @{ Name = 'a soft hyphen'; Text = "WS$([char]0x00AD)01"; Want = 'WS01' }
        @{ Name = 'tag characters, outside the Basic Multilingual Plane'; Text = "WS$([char]::ConvertFromUtf32(0xE0041))$([char]::ConvertFromUtf32(0xE007F))01"; Want = 'WS01' }
    ) {
        ConvertTo-ConsoleText -Text $Text | Should -BeExactly $Want
    }

    It 'turns line breaks and tabs into a space, so a value never starts a new line' {
        ConvertTo-ConsoleText -Text "A`r`nB`nC`rD`tE$([char]0x85)F$([char]0x2028)G" | Should -BeExactly 'A B C D E F G'
    }

    It 'caps the length, ending in ...' {
        $t = ConvertTo-ConsoleText -Text ('x' * 500) -MaxLength 20
        $t.Length | Should -Be 20
        $t | Should -BeExactly (('x' * 17) + '...')
        (ConvertTo-ConsoleText -Text ('y' * 300)).Length | Should -Be 200 -Because 'a value is capped at 200 by default'
    }

    It 'leaves plain text, including non-ASCII names, as it is' {
        ConvertTo-ConsoleText -Text "WS-01.corp.example D$([char]0x00FC)sseldorf" | Should -BeExactly "WS-01.corp.example D$([char]0x00FC)sseldorf"
        $astral = "WS01 $([char]::ConvertFromUtf32(0x1F600)) $([char]::ConvertFromUtf32(0x20BB7))"
        ConvertTo-ConsoleText -Text $astral | Should -BeExactly $astral -Because 'characters outside the Basic Multilingual Plane that are not format characters stay'
        ConvertTo-ConsoleText -Text $null | Should -BeExactly ''
    }
}

Describe 'Colour' {
    It 'is off when NO_COLOR is set to anything, or output is redirected' {
        Test-ConsoleColorWanted -NoColor '1' -Redirected $false | Should -BeFalse
        Test-ConsoleColorWanted -NoColor 'anything' -Redirected $false | Should -BeFalse
        Test-ConsoleColorWanted -NoColor '' -Redirected $true | Should -BeFalse
        Test-ConsoleColorWanted -NoColor $null -Redirected $true | Should -BeFalse
        Test-ConsoleColorWanted -NoColor '' -Redirected $false | Should -BeTrue
    }

    It 'follows NO_COLOR when the run starts' {
        Enter-TestPlainConsole
        try {
            Initialize-ConsoleOutput
            (Get-ConsoleState).Color | Should -BeFalse
        }
        finally {
            Exit-TestPlainConsole
        }
    }

    It 'colours only the status word, piece by piece, when colour is on and lines are shown' {
        Initialize-ConsoleOutput -Color $true -Width 100
        $iv = $null
        Write-ConsoleLine -Segment (Format-ConsoleStepLine -Name 'Read identity' -Result 'Complete, WS01' -Seconds 12) -InformationVariable iv -InformationAction Continue 6>$null
        $records = @($iv)
        $records.Count | Should -BeGreaterThan 1
        $word = @($records | Where-Object { "$_" -eq 'Complete' })
        $word.Count | Should -Be 1
        $word[0].MessageData.ForegroundColor | Should -Be ([System.ConsoleColor]::Green)
        @($records | Where-Object { "$_" -eq ', WS01' })[0].MessageData.ForegroundColor | Should -Not -Be ([System.ConsoleColor]::Green)
    }

    It 'writes one plain line when colour is off' {
        Initialize-ConsoleOutput -Color $false -Width 100
        $iv = $null
        Write-ConsoleLine -Segment (Format-ConsoleStepLine -Name 'Read identity' -Result 'Complete, WS01' -Seconds 12) -InformationVariable iv -InformationAction Continue 6>$null
        @($iv).Count | Should -Be 1
        @($iv)[0].MessageData | Should -BeOfType [string]
    }

    It 'never uses Write-Host in quiet mode, even with colour on' {
        Initialize-ConsoleOutput -Color $true -Width 100
        $iv = $null
        Write-ConsoleLine -Segment @('[1/2] H  ', @{ Text = 'skipped'; Color = [System.ConsoleColor]::DarkGray }, ', already Completed') -InformationVariable iv -InformationAction SilentlyContinue
        @($iv).Count | Should -Be 1 -Because 'a quiet line is still captured, as one record'
        @($iv)[0].MessageData | Should -BeExactly '[1/2] H  skipped, already Completed'
    }

    It 'gives each status word its colour' -ForEach @(
        @{ Word = 'Complete'; Color = 'Green' }, @{ Word = 'Completed'; Color = 'Green' }
        @{ Word = 'Partial'; Color = 'Yellow' }, @{ Word = 'CompletedWithErrors'; Color = 'Yellow' }, @{ Word = 'NoRegistryHives'; Color = 'Yellow' }
        @{ Word = 'Failed'; Color = 'Red' }, @{ Word = 'failed'; Color = 'Red' }, @{ Word = 'changed'; Color = 'Red' }
        @{ Word = 'skipped'; Color = 'DarkGray' }
    ) {
        Get-ConsoleStatusColor -Word $Word | Should -Be ([System.ConsoleColor]$Color)
    }

    It 'shows other words plain' {
        foreach ($w in 'done', 'unchanged', '3', 'Hayabusa') {
            Get-ConsoleStatusColor -Word $w | Should -BeNullOrEmpty
        }
    }
}

Describe 'Console width' {
    BeforeAll {
        $script:savedColumns = [System.Environment]::GetEnvironmentVariable('COLUMNS')
    }
    AfterAll {
        Restore-TestEnvironmentVariable -Name 'COLUMNS' -Value $savedColumns
    }
    BeforeEach {
        Restore-TestEnvironmentVariable -Name 'COLUMNS' -Value $null
        Mock Test-ConsoleRedirected { $false }
        Mock Get-ConsoleWindowWidth { 100 }
    }

    It 'uses COLUMNS when it is a whole number, ahead of a redirect and the window' {
        Mock Test-ConsoleRedirected { $true }
        $env:COLUMNS = '90'
        Get-ConsoleWidth | Should -Be 90
        $env:COLUMNS = '0120'
        Get-ConsoleWidth | Should -Be 120
    }

    It 'clamps a COLUMNS of <Columns> to <Want>' -ForEach @(
        @{ Columns = '10'; Want = 60 }
        @{ Columns = '0'; Want = 60 }
        @{ Columns = '9999'; Want = 500 }
        @{ Columns = '2147483647'; Want = 500 }
    ) {
        $env:COLUMNS = $Columns
        Get-ConsoleWidth | Should -Be $Want
    }

    It 'ignores a COLUMNS of <Name> and works the width out as if it were unset' -ForEach @(
        @{ Name = 'letters'; Columns = 'wide' }
        @{ Name = 'a negative number'; Columns = '-80' }
        @{ Name = 'a plus sign'; Columns = '+80' }
        @{ Name = 'a decimal'; Columns = '80.5' }
        @{ Name = 'spaces around it'; Columns = ' 80 ' }
        @{ Name = 'a thousands separator'; Columns = '1,000' }
        @{ Name = 'a number too big for an int'; Columns = '99999999999' }
        @{ Name = 'digits from another script'; Columns = "$([char]0x0668)$([char]0x0660)" }
        @{ Name = 'an escape sequence'; Columns = "80$([char]27)[2J" }
    ) {
        $env:COLUMNS = $Columns
        Get-ConsoleWidth | Should -Be 100 -Because 'the window is used when output is not redirected'
        Mock Test-ConsoleRedirected { $true }
        Get-ConsoleWidth | Should -Be 120 -Because 'redirected output gets the fallback'
    }

    It 'gives redirected output the 120 fallback, whatever the window says' {
        Mock Test-ConsoleRedirected { $true }
        Mock Get-ConsoleWindowWidth { 200 }
        Get-ConsoleWidth | Should -Be 120
        Should -Invoke Get-ConsoleWindowWidth -Times 0 -Exactly
    }

    It 'uses the window width on a console, no narrower than 60' {
        Get-ConsoleWidth | Should -Be 100
        Mock Get-ConsoleWindowWidth { 40 }
        Get-ConsoleWidth | Should -Be 60
    }

    It 'falls back to 120 when the window width cannot be read' {
        Mock Get-ConsoleWindowWidth { 0 }
        Get-ConsoleWidth | Should -Be 120
    }
}

Describe 'Formatting' {
    It 'formats <Seconds> seconds as <Want>' -ForEach @(
        @{ Seconds = 0; Want = '0s' }, @{ Seconds = 0.4; Want = '0s' }, @{ Seconds = 38; Want = '38s' }, @{ Seconds = 59.6; Want = '1m00s' }
        @{ Seconds = 94; Want = '1m34s' }, @{ Seconds = 362; Want = '6m02s' }, @{ Seconds = 3600; Want = '1h00m00s' }, @{ Seconds = 3723; Want = '1h02m03s' }
    ) {
        Format-ConsoleDuration -Seconds $Seconds | Should -BeExactly $Want
    }

    It 'formats sizes' {
        Format-ConsoleByteSize -Bytes (4.1 * 1GB) | Should -BeExactly '4.1 GB'
        Format-ConsoleByteSize -Bytes (512 * 1MB) | Should -BeExactly '512 MB'
        Format-ConsoleByteSize -Bytes 300 | Should -BeExactly '300 bytes'
    }

    It 'cuts text in the middle to fit' {
        Format-ConsoleMiddle -Text 'abcdefghij' -Width 7 | Should -BeExactly 'ab...ij'
        Format-ConsoleMiddle -Text 'abcdefghijk' -Width 8 | Should -BeExactly 'abc...jk'
        Format-ConsoleMiddle -Text 'short' -Width 10 | Should -BeExactly 'short'
    }

    It 'shortens a path in the middle, never the leaf' {
        Format-ConsolePath -Path 'C:\Users\someone\AppData\Local\Tools\EZ\RECmd\RECmd.exe' -Width 30 | Should -BeExactly 'C:\Users\...\RECmd.exe'
        Format-ConsolePath -Path 'C:\Tools\RECmd.exe' -Width 30 | Should -BeExactly 'C:\Tools\RECmd.exe'
        Format-ConsolePath -Path 'C:\a\b\a-leaf-that-is-longer-than-the-width.exe' -Width 20 | Should -BeExactly '...\a-leaf-that-is-longer-than-the-width.exe'
    }

    It 'counts collections by type for the header' {
        $c = @(
            [pscustomobject]@{ InputType = 'Zip' }, [pscustomobject]@{ InputType = 'Loose' }, [pscustomobject]@{ InputType = 'Vhd' }
            [pscustomobject]@{ InputType = 'Vhdx' }, [pscustomobject]@{ InputType = 'Vhdx' }
        )
        Get-ConsoleInputSummary -Collections $c | Should -BeExactly '5 collections, 1 ZIP, 1 folder, 1 VHD, 2 VHDX'
        Get-ConsoleInputSummary -Collections @([pscustomobject]@{ InputType = 'Loose' }) | Should -BeExactly '1 collection, 1 folder'
    }

    It 'lines up a step line, the time right-aligned' {
        Initialize-ConsoleOutput -Color $false -Width 100
        Get-PieceText (Format-ConsoleStepLine -Name 'Hash before mount' -Result 'done' -Seconds 38) | Should -BeExactly '      Hash before mount     done                           38s'
        Get-PieceText (Format-ConsoleStepLine -Name 'Mount' -Result 'done' -Seconds 4) | Should -BeExactly '      Mount                 done                            4s'
    }
}

Describe 'Summary table' {
    BeforeAll {
        $script:rows = @(
            [pscustomobject]@{ Collection = '2026-10-11T071510_RW-Test-from-a-velociraptor-offline-collector'; Status = 'Completed'; Detections = 12; Identity = 'Complete'; Computer = 'RW-LENOVO'; Seconds = 94 }
            [pscustomobject]@{ Collection = 'HOST02'; Status = 'Skipped'; Detections = $null; Identity = ''; Computer = ''; Seconds = $null }
        )
    }

    It 'fits a fixed width, cutting long collection names in the middle' {
        $table = Format-ConsoleTable -Row $rows -ShowStatus -ShowIdentity -Width 80
        $lines = @(foreach ($l in $table) { Get-PieceText $l })
        $lines[0] | Should -BeExactly '  Collection                   Status     Detections  Identity  Computer    Time'
        $lines[1] | Should -BeExactly '  2026-10-11T0...ne-collector  Completed          12  Complete  RW-LENOVO  1m34s'
        $lines[2].TrimEnd() | Should -BeExactly '  HOST02                       Skipped'
        foreach ($l in $lines) { $l.Length | Should -BeLessOrEqual 80 }
    }

    It 'shows only the columns that apply' {
        $table = Format-ConsoleTable -Row $rows -ShowIdentity -Width 120
        $lines = @(foreach ($l in $table) { Get-PieceText $l })
        $lines[0] | Should -BeExactly '  Collection                                                       Identity  Computer    Time'
        $lines[1] | Should -BeExactly '  2026-10-11T071510_RW-Test-from-a-velociraptor-offline-collector  Complete  RW-LENOVO  1m34s' -Because 'a name that fits is never cut'
    }

    It 'colours the status cell' {
        $table = Format-ConsoleTable -Row $rows -ShowStatus -Width 80
        $first = $table[1]
        @($first | Where-Object { $_ -is [System.Collections.IDictionary] -and $_['Text'] -eq 'Completed' })[0]['Color'] | Should -Be ([System.ConsoleColor]::Green)
    }
}

Describe 'Run log' {
    It 'starts with the lines held back before it opened, and keeps them sanitised and timestamped' {
        Initialize-ConsoleOutput -Color $false -Width 100 -BufferLog
        Write-ConsoleLine -Segment @('before the log opened') -InformationAction SilentlyContinue
        $path = Get-RunLogPath -OutputRoot (Join-TestPath $TestDrive 'log1') -StartedUtc ([datetime]'2026-11-01T10:00:00Z') -RunId 'abc'
        $path | Should -Be (Join-TestPath $TestDrive 'log1' '_runs' 'run_20261101T100000Z_abc.log')
        Open-ConsoleRunLog -Path $path
        Write-ConsoleLine -Segment @("[1/1] EVIL$esc]0;owned$bel$esc[2J  folder") -InformationAction SilentlyContinue
        Write-RunWarning -Message "a warning with a$([char]10)line break" -WarningAction SilentlyContinue
        Close-ConsoleRunLog
        Test-Utf8Bom -Path $path | Should -BeFalse
        $raw = [System.IO.File]::ReadAllText($path)
        $raw | Should -Not -Match '[\x00-\x09\x0B\x0C\x0E-\x1F\x7F]'
        $lines = @(Get-Content -LiteralPath $path -Encoding UTF8)
        $lines.Count | Should -Be 3
        foreach ($l in $lines) { $l | Should -Match '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ ' }
        $lines[0].Substring(21) | Should -BeExactly 'before the log opened'
        $lines[1].Substring(21) | Should -BeExactly '[1/1] EVIL  folder'
        $lines[2].Substring(21) | Should -BeExactly 'WARNING a warning with a line break'
    }

    It 'can be read while it is being written' {
        Initialize-ConsoleOutput -Color $false -Width 100 -BufferLog
        $path = Join-TestPath $TestDrive 'log2' '_runs' 'run_x.log'
        Open-ConsoleRunLog -Path $path
        Write-ConsoleLine -Segment @('first') -InformationAction SilentlyContinue
        try {
            $reader = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $reader.Length | Should -BeGreaterThan 0 -Because 'each line is flushed as it is written'
            $reader.Dispose()
        }
        finally {
            Close-ConsoleRunLog
        }
    }

    It 'warns once and carries on when it can''t be written' {
        Initialize-ConsoleOutput -Color $false -Width 100 -BufferLog
        $blocker = Write-TestText -Path (Join-TestPath $TestDrive 'log3' '_runs') -Line @('a file where the folder should be')
        $w = $null
        Open-ConsoleRunLog -Path (Join-Path $blocker 'run_x.log') -WarningVariable w -WarningAction SilentlyContinue
        Write-ConsoleLine -Segment @('still running') -InformationAction SilentlyContinue -WarningVariable +w -WarningAction SilentlyContinue
        Write-RunWarning -Message 'a later warning' -WarningVariable +w -WarningAction SilentlyContinue
        @($w | Where-Object { "$_" -like "Couldn't write the run log*" }).Count | Should -Be 1
        Get-ConsoleRunLogPath | Should -BeNullOrEmpty
    }

    It 'refuses to write through a _runs folder that is a link' {
        $target = New-TestDirectory (Join-TestPath $TestDrive 'elsewhere')
        $out = New-TestDirectory (Join-TestPath $TestDrive 'log4')
        try {
            New-Item -ItemType SymbolicLink -Path (Join-TestPath $out '_runs') -Target $target -ErrorAction Stop | Out-Null
        }
        catch {
            Set-ItResult -Skipped -Because "this session can't create symbolic links: $($_.Exception.Message)"
            return
        }
        Initialize-ConsoleOutput -Color $false -Width 100 -BufferLog
        $w = $null
        Open-ConsoleRunLog -Path (Join-TestPath $out '_runs' 'run_x.log') -WarningVariable w -WarningAction SilentlyContinue
        @($w | Where-Object { "$_" -like '*is a link or junction*' }).Count | Should -Be 1
        @(Get-ChildItem -LiteralPath $target).Count | Should -Be 0
    }
}

Describe 'Notices before the run' {
    It 'writes held warnings sanitised, and passes over one that cannot be written' {
        $hw = $null
        Write-HeldWarning -Record @("A$esc[2JB$([char]0x200B)C", $null) -WarningVariable hw -WarningAction SilentlyContinue
        @($hw | ForEach-Object { $_.Message }) | Should -BeExactly @('ABC')
        { Write-HeldWarning -Record @('stopped') -WarningAction Stop 3>$null } | Should -Not -Throw
    }

    It 'shows a short note and records the warning quietly when lines are on screen' {
        Initialize-ConsoleOutput -Color $false -Width 100
        $iv = $null
        $w = $null
        Write-ConsoleNotice -Warning 'X.zip can''t be extracted by this tool (unsupported compression or encryption).' -Display 'X.zip can''t be extracted, unsupported compression or encryption.' -InformationVariable iv -InformationAction Continue -WarningVariable w 6>$null 3>$null
        @($iv | ForEach-Object { "$_" }) | Should -Be @('  ! X.zip can''t be extracted, unsupported compression or encryption.')
        @($w | ForEach-Object { "$_" }) | Should -Be @('X.zip can''t be extracted by this tool (unsupported compression or encryption).')
    }

    It 'shows the warning itself when lines are hidden' {
        Initialize-ConsoleOutput -Color $false -Width 100
        $iv = $null
        $w = $null
        Write-ConsoleNotice -Warning 'A notice.' -InformationVariable iv -InformationAction SilentlyContinue -WarningVariable w -WarningAction SilentlyContinue
        @($iv).Count | Should -Be 0
        @($w | ForEach-Object { "$_" }) | Should -Be @('A notice.')
    }
}

Describe 'Hosts and steps' {
    It 'writes the header when the host starts, each step when it finishes, then the status and time' {
        Initialize-ConsoleOutput -Color $false -Width 100
        $iv = $null
        Get-ConsoleOutput -Script {
            Start-ConsoleHost -Index 3 -Total 5 -Name '2026-10-11T072226_RW-Test-VHD' -Detail 'VHD, 4.1 GB'
            Start-ConsoleStep -Name 'Hash before mount'
            Complete-ConsoleStep -Result 'done'
            Start-ConsoleStep -Name 'Teardown'
            Complete-ConsoleStep -Failed -Reason "Dismount failed$([char]10)device busy"
            $null = Complete-ConsoleHost -Status 'Failed'
        } -InformationVariable iv -InformationAction SilentlyContinue
        $lines = @($iv | ForEach-Object { "$_" })
        $lines[0] | Should -BeExactly '[3/5] 2026-10-11T072226_RW-Test-VHD  VHD, 4.1 GB'
        $lines[1] | Should -Match '^ {6}Hash before mount +done +\d+s$'
        $lines[2] | Should -Match '^ {6}Teardown +failed, Dismount failed device busy +\d+s$'
        $lines[3] | Should -Match '^ {6}Failed in \d+s$'
    }

    It 'closes a step still open as failed when the host ends' {
        Initialize-ConsoleOutput -Color $false -Width 100
        $iv = $null
        Get-ConsoleOutput -Script {
            Start-ConsoleHost -Index 1 -Total 1 -Name 'H' -Detail 'folder'
            Start-ConsoleStep -Name 'Hayabusa'
            $null = Complete-ConsoleHost -Status 'Failed'
        } -InformationVariable iv -InformationAction SilentlyContinue
        @($iv | ForEach-Object { "$_" })[1] | Should -Match '^ {6}Hayabusa +failed +\d+s$'
    }

    It 'sanitises a hostile collection name in the header and the progress bar' {
        Initialize-ConsoleOutput -Color $false -Width 100
        $iv = $null
        Start-ConsoleHost -Index 1 -Total 1 -Name "A$esc]0;owned$bel$([char]0x202E)B" -InformationVariable iv -InformationAction SilentlyContinue
        @($iv | ForEach-Object { "$_" })[0] | Should -BeExactly '[1/1] AB'
        $null = Complete-ConsoleHost -Status 'Completed' -InformationAction SilentlyContinue
    }
}

Describe 'Quiet mode' {
    It 'prints nothing with -InformationAction SilentlyContinue, and still writes the run log' {
        $tool = New-FakeHayabusa -Directory (Join-TestPath $TestDrive 'quiet-tool')
        $in = New-TestDirectory (Join-TestPath $TestDrive 'quiet-in')
        New-FakeHost -InputRoot $in -Name 'HOST01' -Files @{ 'r.csv' = @($TimelineHeader, (New-TimelineRow 'WS01' 'high' 'RuleA')) } | Out-Null
        $out = Join-TestPath $TestDrive 'quiet-out'
        $r = Invoke-ScriptInNewProcess -Path $MainScript -Argument @('-InputRoot', $in, '-OutputRoot', $out, '-HayabusaPath', $tool, '-InformationAction', 'SilentlyContinue', '-WarningAction', 'SilentlyContinue') -WorkingDirectory $TestDrive
        $r.ExitCode | Should -Be 0
        @($r.Output | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count | Should -Be 0
        $log = @(Get-ChildItem -LiteralPath (Join-TestPath $out '_runs') -Filter 'run_*.log')
        $log.Count | Should -Be 1
        $text = @(Get-Content -LiteralPath $log[0].FullName -Encoding UTF8 | ForEach-Object { $_.Substring(21) })
        $text | Should -Contain '[1/1] HOST01  folder'
        $text | Should -Contain 'Summary'
    }
}

Describe 'The test setup' {
    It 'leaves the environment as it found it when the helpers are loaded' {
        $before = Get-TestEnvironment
        & { . (Join-Path $PSScriptRoot 'Helpers/TestHelpers.ps1') }
        $after = Get-TestEnvironment
        ($after -join "`n") | Should -BeExactly ($before -join "`n")
    }

    It 'puts NO_COLOR and COLUMNS back the way they were after a run of the entry script, set or not' {
        $savedNoColor = [System.Environment]::GetEnvironmentVariable('NO_COLOR')
        $savedColumns = [System.Environment]::GetEnvironmentVariable('COLUMNS')
        try {
            Restore-TestEnvironmentVariable -Name 'NO_COLOR' -Value $null
            Restore-TestEnvironmentVariable -Name 'COLUMNS' -Value $null
            Enter-TestPlainConsole
            $env:NO_COLOR | Should -BeExactly '1'
            $env:COLUMNS | Should -BeExactly '120'
            Exit-TestPlainConsole
            foreach ($name in 'NO_COLOR', 'COLUMNS') {
                Test-Path -LiteralPath "Env:\$name" | Should -BeFalse -Because "$name wasn't set before, so it mustn't be left set, even empty"
                $null -eq [System.Environment]::GetEnvironmentVariable($name) | Should -BeTrue
                @([System.Environment]::GetEnvironmentVariables().Keys) | Should -Not -Contain $name
            }

            $env:NO_COLOR = 'mine'
            $env:COLUMNS = '80'
            Enter-TestPlainConsole
            Exit-TestPlainConsole
            $env:NO_COLOR | Should -BeExactly 'mine'
            $env:COLUMNS | Should -BeExactly '80'
        }
        finally {
            Restore-TestEnvironmentVariable -Name 'NO_COLOR' -Value $savedNoColor
            Restore-TestEnvironmentVariable -Name 'COLUMNS' -Value $savedColumns
        }
    }

    It 'removes a variable that was not set when it restores it, and sets one that was' {
        $saved = [System.Environment]::GetEnvironmentVariable('HBR_TEST_RESTORE')
        try {
            $env:HBR_TEST_RESTORE = 'x'
            Restore-TestEnvironmentVariable -Name 'HBR_TEST_RESTORE' -Value $null
            Test-Path -LiteralPath 'Env:\HBR_TEST_RESTORE' | Should -BeFalse
            { Restore-TestEnvironmentVariable -Name 'HBR_TEST_RESTORE' -Value $null } | Should -Not -Throw -Because 'removing one that is already gone is fine'
            Restore-TestEnvironmentVariable -Name 'HBR_TEST_RESTORE' -Value 'back'
            $env:HBR_TEST_RESTORE | Should -BeExactly 'back'
        }
        finally {
            Restore-TestEnvironmentVariable -Name 'HBR_TEST_RESTORE' -Value $saved
        }
    }
}
