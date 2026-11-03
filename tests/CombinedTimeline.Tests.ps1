# The combined timeline, lib\CombinedTimeline.ps1. Every per-host CSV here
# is synthetic and written as raw bytes, so the tests can check rows come
# through byte for byte, line endings and byte order mark included.

BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers/TestHelpers.ps1')
    $script:utf8 = New-Object System.Text.UTF8Encoding($false)
    $script:hdr = '"Timestamp","Computer","Channel","EventID","Level","RecordID","RuleTitle","Details","RuleID"'

    function script:Row([string]$Time, [string]$Computer = 'WS01', [string]$Title = 'RuleA', [string]$Details = 'd') {
        # One row as Hayabusa writes it, numbers unquoted.
        $q = { param($v) '"' + $v.Replace('"', '""') + '"' }
        return ('{0},{1},"Sec",4624,"high",1,{2},{3},"id"' -f (& $q $Time), (& $q $Computer), (& $q $Title), (& $q $Details))
    }

    function script:ConvertTo-CsvByte([string[]]$Line, [string]$Ending = "`n", [switch]$Bom) {
        $text = (($Line | ForEach-Object { $_ + $Ending }) -join '')
        $bytes = $utf8.GetBytes($text)
        if ($Bom) {
            $bytes = [byte[]](@(0xEF, 0xBB, 0xBF) + $bytes)
        }
        return , $bytes
    }

    function script:New-CombinedRoot {
        # Hosts is a list of @{ Name; Status; Bytes }, written to the
        # manifest in that order. Bytes $null leaves the CSV out.
        param([string]$Name, [object[]]$Hosts)
        $o = New-TestDirectory (Join-TestPath $TestDrive $Name)
        $m = Join-TestPath $o 'run_manifest.csv'
        Initialize-RunManifest -Path $m | Out-Null
        foreach ($h in $Hosts) {
            $status = 'Completed'
            if ($h.ContainsKey('Status')) { $status = $h.Status }
            Set-RunManifestEntry -Path $m -Collection $h.Name -Source $h.Name -RunId 'r1' -InputType Loose -Status $status -HostName $h.Name
            if ($null -ne $h.Bytes) {
                $csv = (Get-CollectionOutputPath -OutputRoot $o -Collection $h.Name).Csv
                New-TestDirectory (Split-Path -Parent $csv) | Out-Null
                [System.IO.File]::WriteAllBytes($csv, [byte[]]$h.Bytes)
            }
        }
        return $o
    }

    function script:Build([string]$OutputRoot) {
        # Runs the merge as the rollup does and returns the result with the
        # warnings it would write.
        $hosts = (Get-RollupData -OutputRoot $OutputRoot).Hosts
        return (Invoke-CombinedTimeline -OutputRoot $OutputRoot -Hosts $hosts)
    }

    function script:Get-Combined([string]$OutputRoot) {
        return , [System.IO.File]::ReadAllBytes((Join-TestPath $OutputRoot 'combined_timeline.csv'))
    }

    function script:Get-CombinedLine([string]$OutputRoot) {
        return @(([System.IO.File]::ReadAllText((Join-TestPath $OutputRoot 'combined_timeline.csv'), $utf8) -split "`n") | Where-Object { $_ -ne '' })
    }
}

Describe 'Merging' {
    It 'puts every host''s rows in time order under one header' {
        $o = New-CombinedRoot 'order' @(
            @{ Name = 'WS01'; Bytes = (ConvertTo-CsvByte @($hdr, (Row '2026-10-01 10:00:00.000 +00:00' 'WS01' 'A1'), (Row '2026-10-01 12:00:00.000 +00:00' 'WS01' 'A2'))) }
            @{ Name = 'WS02'; Bytes = (ConvertTo-CsvByte @($hdr, (Row '2026-10-01 09:00:00.000 +00:00' 'WS02' 'B1'), (Row '2026-10-01 11:00:00.000 +00:00' 'WS02' 'B2'), (Row '2026-10-02 00:00:00.000 +00:00' 'WS02' 'B3'))) }
            @{ Name = 'DC01'; Bytes = (ConvertTo-CsvByte @($hdr, (Row '2026-10-01 10:30:00.000 +00:00' 'DC01' 'C1'))) }
        )
        $r = Build $o
        $r.Error | Should -BeNullOrEmpty
        $r.Rows | Should -Be 6
        $r.Hosts | Should -Be 3
        $lines = Get-CombinedLine $o
        $lines[0] | Should -BeExactly $hdr
        @($lines | Where-Object { $_ -eq $hdr }).Count | Should -Be 1 -Because 'the header is written once'
        (@($lines | ConvertFrom-Csv | ForEach-Object { $_.RuleTitle }) -join ',') | Should -BeExactly 'B1,A1,C1,B2,A2,B3'
    }

    It 'keeps ties in the manifest''s order, then the file''s' {
        $t = '2026-10-01 10:00:00.000 +00:00'
        # ZZ is listed before AA, so it goes first however the names sort.
        $o = New-CombinedRoot 'ties' @(
            @{ Name = 'ZZ'; Bytes = (ConvertTo-CsvByte @($hdr, (Row $t 'ZZ' 'Z1'), (Row $t 'ZZ' 'Z2'))) }
            @{ Name = 'AA'; Bytes = (ConvertTo-CsvByte @($hdr, (Row $t 'AA' 'A1'), (Row $t 'AA' 'A2'))) }
            @{ Name = 'MM'; Bytes = (ConvertTo-CsvByte @($hdr, (Row '2026-10-01 09:59:59.999 +00:00' 'MM' 'M0'), (Row $t 'MM' 'M1'))) }
        )
        (Build $o).Error | Should -BeNullOrEmpty
        (@(Get-CombinedLine $o | ConvertFrom-Csv | ForEach-Object { $_.RuleTitle }) -join ',') | Should -BeExactly 'M0,Z1,Z2,A1,A2,M1'
    }

    It 'copies a quoted field with commas, quotes and line breaks byte for byte' {
        $tricky = "a, b ""quoted"", c`r`nsecond line`nthird $([char]0x00A6) line"
        $row1 = Row '2026-10-01 10:00:00.000 +00:00' 'WS01' 'Odd, title' $tricky
        $row2 = Row '2026-10-01 11:00:00.000 +00:00' 'WS02' 'Plain'
        $one = ConvertTo-CsvByte @($hdr, $row1) -Ending "`r`n"
        $two = ConvertTo-CsvByte @($hdr, $row2)
        $o = New-CombinedRoot 'quoted' @(@{ Name = 'WS01'; Bytes = $one }, @{ Name = 'WS02'; Bytes = $two })
        $r = Build $o
        $r.Error | Should -BeNullOrEmpty
        $r.Rows | Should -Be 2
        $want = [byte[]]($utf8.GetBytes("$hdr`r`n") + $utf8.GetBytes("$row1`r`n") + $utf8.GetBytes("$row2`n"))
        $got = Get-Combined $o
        [System.Convert]::ToBase64String($got) | Should -BeExactly ([System.Convert]::ToBase64String($want)) -Because 'every row keeps its own bytes and line ending, and the header comes from the first host'
    }

    It 'keeps a byte order mark when Hayabusa wrote one, and leaves it off when it didn''t' {
        $withBom = New-CombinedRoot 'bom' @(@{ Name = 'H1'; Bytes = (ConvertTo-CsvByte @($hdr, (Row '2026-10-01 10:00:00.000 +00:00')) -Bom) })
        (Build $withBom).Error | Should -BeNullOrEmpty
        Test-Utf8Bom -Path (Join-TestPath $withBom 'combined_timeline.csv') | Should -BeTrue
        $noBom = New-CombinedRoot 'nobom' @(@{ Name = 'H1'; Bytes = (ConvertTo-CsvByte @($hdr, (Row '2026-10-01 10:00:00.000 +00:00'))) })
        (Build $noBom).Error | Should -BeNullOrEmpty
        Test-Utf8Bom -Path (Join-TestPath $noBom 'combined_timeline.csv') | Should -BeFalse
    }

    It 'adds the line ending to a last row that has none, so rows never run together' {
        $o = New-CombinedRoot 'noend' @(
            @{ Name = 'H1'; Bytes = $utf8.GetBytes("$hdr`n$(Row '2026-10-01 10:00:00.000 +00:00' 'H1' 'X1')") }
            @{ Name = 'H2'; Bytes = (ConvertTo-CsvByte @($hdr, (Row '2026-10-01 11:00:00.000 +00:00' 'H2' 'X2'))) }
        )
        (Build $o).Error | Should -BeNullOrEmpty
        @(Get-CombinedLine $o).Count | Should -Be 3
    }

    It 'adds nothing for a host whose CSV is empty or missing, and doesn''t count it as a column mismatch' {
        $o = New-CombinedRoot 'empty' @(
            @{ Name = 'H1'; Bytes = (ConvertTo-CsvByte @($hdr, (Row '2026-10-01 10:00:00.000 +00:00'))) }
            @{ Name = 'CLEAN'; Bytes = [byte[]]@() }
            @{ Name = 'NOCSV'; Bytes = $null }
        )
        $r = Build $o
        $r.Error | Should -BeNullOrEmpty
        $r.Rows | Should -Be 1
        $r.Hosts | Should -Be 3 -Because 'hosts that detected nothing are still in it'
    }

    It 'writes an empty file, as Hayabusa does, when no included host detected anything' {
        $o = New-CombinedRoot 'allempty' @(@{ Name = 'H1'; Bytes = [byte[]]@() }, @{ Name = 'H2'; Bytes = [byte[]]@() })
        $r = Build $o
        $r.Error | Should -BeNullOrEmpty
        $r.Rows | Should -Be 0
        (Get-Item -LiteralPath (Join-TestPath $o 'combined_timeline.csv')).Length | Should -Be 0
    }

    It 'leaves out a Failed host and one the rollup finds Unreadable' {
        $other = '"Timestamp","Computer","Level","RuleTitle","Extra"'
        $o = New-CombinedRoot 'excluded' @(
            @{ Name = 'GOOD'; Bytes = (ConvertTo-CsvByte @($hdr, (Row '2026-10-01 10:00:00.000 +00:00' 'GOOD'))) }
            @{ Name = 'FAILED'; Status = 'Failed'; Bytes = (ConvertTo-CsvByte @($other, '"not a timestamp","FAILED","high","Old","x"')) }
            @{ Name = 'NOLEVEL'; Bytes = (ConvertTo-CsvByte @('"Timestamp","Computer"', '"2026-10-01 10:00:00.000 +00:00","NOLEVEL"')) }
        )
        $data = Get-RollupData -OutputRoot $o
        @($data.Hosts | Where-Object { $_.Collection -eq 'NOLEVEL' })[0].Status | Should -BeExactly 'Unreadable'
        $r = Invoke-CombinedTimeline -OutputRoot $o -Hosts $data.Hosts
        $r.Error | Should -BeNullOrEmpty -Because 'neither host is looked at, so neither header nor Timestamp can stop it'
        $r.Rows | Should -Be 1
        $r.Hosts | Should -Be 1
        ((Get-CombinedLine $o) -join "`n") | Should -Not -Match 'FAILED|NOLEVEL'
    }

    It 'is not built at all when no host has results' {
        $o = New-CombinedRoot 'nohosts' @(@{ Name = 'F1'; Status = 'Failed'; Bytes = $null })
        $r = Build $o
        $r.Path | Should -BeNullOrEmpty
        $r.Error | Should -BeNullOrEmpty
        $r.Reason | Should -BeExactly 'no host has results yet'
        Test-Path -LiteralPath (Join-TestPath $o 'combined_timeline.csv') | Should -BeFalse
    }

    It 'replaces a leftover temporary file instead of appending to it' {
        $o = New-CombinedRoot 'leftover' @(@{ Name = 'H1'; Bytes = (ConvertTo-CsvByte @($hdr, (Row '2026-10-01 10:00:00.000 +00:00'))) })
        Write-TestText -Path (Join-TestPath $o 'combined_timeline.csv.tmp') -Line @('junk from an interrupted run') | Out-Null
        (Build $o).Error | Should -BeNullOrEmpty
        (Get-CombinedLine $o).Count | Should -Be 2
        Test-Path -LiteralPath (Join-TestPath $o 'combined_timeline.csv.tmp') | Should -BeFalse
    }
}

Describe 'When it stops' {
    BeforeAll {
        $script:earlier = 'an earlier combined timeline, left as it was'
        function script:Set-Earlier([string]$OutputRoot) {
            $p = Join-TestPath $OutputRoot 'combined_timeline.csv'
            [System.IO.File]::WriteAllText($p, $earlier, $utf8)
            return $p
        }
        function script:Assert-Untouched([string]$OutputRoot) {
            [System.IO.File]::ReadAllText((Join-TestPath $OutputRoot 'combined_timeline.csv'), $utf8) | Should -BeExactly $earlier
            Test-Path -LiteralPath (Join-TestPath $OutputRoot 'combined_timeline.csv.tmp') | Should -BeFalse
        }
    }

    It 'writes nothing when the hosts'' columns differ, naming each header''s hosts' {
        $verbose = '"Timestamp","Computer","Channel","EventID","Level","MitreTactics","RecordID","RuleTitle","Details","RuleID"'
        $o = New-CombinedRoot 'mismatch' @(
            @{ Name = 'WS01'; Bytes = (ConvertTo-CsvByte @($hdr, (Row '2026-10-01 10:00:00.000 +00:00'))) }
            @{ Name = 'WS02'; Bytes = (ConvertTo-CsvByte @($hdr, (Row '2026-10-01 11:00:00.000 +00:00'))) }
            @{ Name = 'DC01'; Bytes = (ConvertTo-CsvByte @($verbose, '"2026-10-01 10:00:00.000 +00:00","DC01","Sec",4624,"high","","1","R","d","id"')) }
        )
        Set-Earlier $o | Out-Null
        $r = Build $o
        $r.Path | Should -BeNullOrEmpty
        $r.Reason | Should -BeExactly "the hosts' columns differ"
        $r.Error | Should -BeLike "Combined timeline not built, because the hosts' timelines don't all have the same columns*"
        $r.Error | Should -BeLike '*WS01 and WS02 have Timestamp, Computer, Channel, EventID, Level, RecordID, RuleTitle, Details, RuleID*'
        $r.Error | Should -BeLike '*DC01 has Timestamp, Computer, Channel, EventID, Level, MitreTactics,*'
        $r.Error | Should -BeLike '*Rerunning those hosts with -Force under one profile fixes it.*'
        Assert-Untouched $o
    }

    It 'stops on a file out of time order, naming the host and the line' {
        $o = New-CombinedRoot 'outoforder' @(
            @{ Name = 'GOOD'; Bytes = (ConvertTo-CsvByte @($hdr, (Row '2026-10-01 10:00:00.000 +00:00'))) }
            @{ Name = 'BACK'; Bytes = (ConvertTo-CsvByte @($hdr, (Row '2026-10-01 10:00:00.000 +00:00'), (Row '2026-10-01 12:00:00.000 +00:00'), (Row '2026-10-01 11:59:59.999 +00:00'))) }
        )
        Set-Earlier $o | Out-Null
        $r = Build $o
        $r.Reason | Should -BeExactly "a host's timeline is out of time order"
        $r.Error | Should -BeLike "*because BACK's timeline isn't in time order at line 4,*"
        $r.Error | Should -BeLike '*Any earlier combined_timeline.csv was left as it was.'
        Assert-Untouched $o
    }

    It 'counts lines inside a quoted field when it names the line' {
        $o = New-CombinedRoot 'outoforder2' @(
            @{ Name = 'BACK'; Bytes = (ConvertTo-CsvByte @($hdr, (Row '2026-10-01 12:00:00.000 +00:00' 'BACK' 'T' "one`ntwo"), (Row '2026-10-01 11:00:00.000 +00:00'))) }
        )
        (Build $o).Error | Should -BeLike '*at line 4,*' -Because 'the header is line 1 and the first row takes lines 2 and 3'
    }

    It 'stops on a Timestamp that isn''t in Hayabusa''s UTC form, <Name>' -ForEach @(
        @{ Name = 'a local offset'; Time = '2026-10-01 10:00:00.000 +09:00' }
        @{ Name = 'no milliseconds'; Time = '2026-10-01 10:00:00 +00:00' }
        @{ Name = 'an ISO 8601 form'; Time = '2026-10-01T10:00:00.000Z' }
        @{ Name = 'a date that doesn''t exist'; Time = '2026-02-30 10:00:00.000 +00:00' }
        @{ Name = 'an empty value'; Time = '' }
    ) {
        $o = New-CombinedRoot "badts-$([guid]::NewGuid().ToString('N'))" @(
            @{ Name = 'GOOD'; Bytes = (ConvertTo-CsvByte @($hdr, (Row '2026-10-01 10:00:00.000 +00:00'))) }
            @{ Name = 'ODD'; Bytes = (ConvertTo-CsvByte @($hdr, (Row '2026-10-01 09:00:00.000 +00:00'), (Row $Time))) }
        )
        Set-Earlier $o | Out-Null
        $r = Build $o
        $r.Reason | Should -BeExactly "a Timestamp isn't in the expected form"
        $r.Error | Should -BeLike "*because line 3 of ODD's timeline has a Timestamp that isn't in Hayabusa's UTC form, yyyy-MM-dd HH:mm:ss.fff +00:00.*"
        Assert-Untouched $o
    }

    It 'stops on a row too short to hold a Timestamp' {
        $o = New-CombinedRoot 'short' @(@{ Name = 'SHORT'; Bytes = (ConvertTo-CsvByte @('"Computer","Level","RuleTitle","Timestamp"', '"WS01","high","R"')) })
        Set-Earlier $o | Out-Null
        (Build $o).Error | Should -BeLike "*line 2 of SHORT's timeline*"
        Assert-Untouched $o
    }

    It 'stops on a quoted field that never closes' {
        $o = New-CombinedRoot 'unclosed' @(@{ Name = 'OPEN'; Bytes = $utf8.GetBytes("$hdr`n$(Row '2026-10-01 10:00:00.000 +00:00')`n""2026-10-01 11:00:00.000 +00:00"",""WS01,`nand on") })
        Set-Earlier $o | Out-Null
        $r = Build $o
        $r.Error | Should -BeLike "*because OPEN's timeline has a quoted field starting at line 3 that never closes.*"
        Assert-Untouched $o
    }

    It 'refuses to write through a link at the output path' {
        $o = New-CombinedRoot 'link' @(@{ Name = 'H1'; Bytes = (ConvertTo-CsvByte @($hdr, (Row '2026-10-01 10:00:00.000 +00:00'))) })
        $target = Join-TestPath $TestDrive 'elsewhere.txt'
        [System.IO.File]::WriteAllText($target, 'outside OutputRoot', $utf8)
        $link = Join-TestPath $o 'combined_timeline.csv'
        try {
            New-Item -ItemType SymbolicLink -Path $link -Target $target -ErrorAction Stop | Out-Null
        }
        catch {
            Set-ItResult -Skipped -Because "this session can't create a symbolic link: $($_.Exception.Message)"
            return
        }
        $r = Build $o
        $r.Reason | Should -BeExactly 'the output path is a link or junction'
        $r.Error | Should -BeLike "*because $link is a link or junction, which could point anywhere.*"
        [System.IO.File]::ReadAllText($target, $utf8) | Should -BeExactly 'outside OutputRoot'
    }

    It 'refuses a link at the temporary path too' {
        $o = New-CombinedRoot 'tmplink' @(@{ Name = 'H1'; Bytes = (ConvertTo-CsvByte @($hdr, (Row '2026-10-01 10:00:00.000 +00:00'))) })
        $target = Join-TestPath $TestDrive 'elsewhere-tmp.txt'
        [System.IO.File]::WriteAllText($target, 'outside OutputRoot', $utf8)
        try {
            New-Item -ItemType SymbolicLink -Path (Join-TestPath $o 'combined_timeline.csv.tmp') -Target $target -ErrorAction Stop | Out-Null
        }
        catch {
            Set-ItResult -Skipped -Because "this session can't create a symbolic link: $($_.Exception.Message)"
            return
        }
        (Build $o).Reason | Should -BeExactly 'the output path is a link or junction'
        [System.IO.File]::ReadAllText($target, $utf8) | Should -BeExactly 'outside OutputRoot'
    }

    It 'refuses a dangling link at <Leaf>, whose target is gone' -ForEach @(
        @{ Leaf = 'combined_timeline.csv' }
        @{ Leaf = 'combined_timeline.csv.tmp' }
    ) {
        $o = New-CombinedRoot "dangling-$($Leaf.Replace('.', '-'))" @(@{ Name = 'H1'; Bytes = (ConvertTo-CsvByte @($hdr, (Row '2026-10-01 10:00:00.000 +00:00'))) })
        $link = Join-TestPath $o $Leaf
        $skip = New-TestDanglingLink -Path $link
        if ($null -ne $skip) {
            Set-ItResult -Skipped -Because $skip
            return
        }
        $r = Build $o
        $r.Reason | Should -BeExactly 'the output path is a link or junction'
        $r.Error | Should -BeLike "*because $link is a link or junction, which could point anywhere.*"
        Test-Path -LiteralPath "$link.gone" | Should -BeFalse -Because 'nothing was written through the link to its old target'
    }

    It 'skips it with a warning when there isn''t the room' {
        Mock Get-FreeSpace { [long]10 }
        $o = New-CombinedRoot 'nospace' @(@{ Name = 'H1'; Bytes = (ConvertTo-CsvByte @($hdr, (Row '2026-10-01 10:00:00.000 +00:00'))) })
        Set-Earlier $o | Out-Null
        $r = Build $o
        $r.Reason | Should -BeExactly 'not enough free space'
        $r.Error | Should -BeLike "*has 10 bytes free and it needs about * bytes, the size of the hosts' timelines together.*"
        Assert-Untouched $o
    }

    It 'goes ahead when the free space can''t be read' {
        Mock Get-FreeSpace { $null }
        $o = New-CombinedRoot 'unknownspace' @(@{ Name = 'H1'; Bytes = (ConvertTo-CsvByte @($hdr, (Row '2026-10-01 10:00:00.000 +00:00'))) })
        (Build $o).Error | Should -BeNullOrEmpty
    }
}

Describe 'Hosts sharing a computer name' {
    It 'still writes it, and warns naming the collections and the name' {
        $o = New-CombinedRoot 'shared' @(
            @{ Name = 'KAPE-WS01'; Bytes = (ConvertTo-CsvByte @($hdr, (Row '2026-10-01 10:00:00.000 +00:00' 'WS01'))) }
            @{ Name = 'VR-WS01'; Bytes = (ConvertTo-CsvByte @($hdr, (Row '2026-10-01 11:00:00.000 +00:00' 'ws01'))) }
            @{ Name = 'DC01'; Bytes = (ConvertTo-CsvByte @($hdr, (Row '2026-10-01 11:00:00.000 +00:00' 'DC01'))) }
        )
        $r = Build $o
        $r.Error | Should -BeNullOrEmpty
        $r.Rows | Should -Be 3
        @($r.Warnings) | Should -Be @("Combined timeline: KAPE-WS01 and VR-WS01 both have rows for computer WS01, so those rows can't be told apart in it.")
    }

    It 'sanitises a computer name from the evidence before it goes in the warning' {
        $evil = "WS01$([char]27)]0;owned$([char]7)$([char]0x202E)"
        $o = New-CombinedRoot 'sharedevil' @(
            @{ Name = 'A'; Bytes = (ConvertTo-CsvByte @($hdr, (Row '2026-10-01 10:00:00.000 +00:00' $evil))) }
            @{ Name = 'B'; Bytes = (ConvertTo-CsvByte @($hdr, (Row '2026-10-01 10:00:00.000 +00:00' $evil))) }
        )
        $w = @((Build $o).Warnings)
        $w.Count | Should -Be 1
        $w[0] | Should -BeExactly "Combined timeline: A and B both have rows for computer WS01, so those rows can't be told apart in it."
    }
}

Describe 'Coverage' {
    BeforeAll {
        $script:okRow = ConvertTo-CsvByte @($hdr, (Row '2026-10-01 10:00:00.000 +00:00'))
        $script:noLevel = ConvertTo-CsvByte @('"Timestamp","Computer"', '"2026-10-01 10:00:00.000 +00:00","X"')
    }

    It 'lists nothing when every collection is in it, and the closing text is just the rows' {
        $o = New-CombinedRoot 'cover-all' @(@{ Name = 'WS01'; Bytes = $okRow }, @{ Name = 'WS02'; Bytes = $okRow })
        $r = Build $o
        $r.Collections | Should -Be 2
        $r.Hosts | Should -Be 2
        @($r.LeftOut).Count | Should -Be 0
        @($r.Warnings | Where-Object { $_ -like "*isn't in it*" -or $_ -like "*aren't in it*" }).Count | Should -Be 0
        Format-CombinedCoverage -Rows $r.Rows -Hosts $r.Hosts -Collections $r.Collections | Should -BeExactly '2 rows'
    }

    It 'names a Failed collection it leaves out' {
        $o = New-CombinedRoot 'cover-failed' @(@{ Name = 'WS01'; Bytes = $okRow }, @{ Name = 'WS05'; Status = 'Failed'; Bytes = $okRow })
        $r = Build $o
        $r.Collections | Should -Be 2
        $r.Hosts | Should -Be 1
        @($r.LeftOut | ForEach-Object { "$($_.Collection)=$($_.Reason)" }) | Should -Be @('WS05=Failed')
        @($r.Warnings) | Should -Contain "Combined timeline: 1 of 2 collections isn't in it, WS05 because it failed."
        Format-CombinedCoverage -Rows $r.Rows -Hosts $r.Hosts -Collections $r.Collections | Should -BeExactly '1 row from 1 of 2 collections'
    }

    It 'names a collection the rollup found Unreadable' {
        $o = New-CombinedRoot 'cover-unreadable' @(@{ Name = 'WS01'; Bytes = $okRow }, @{ Name = 'FS02'; Bytes = $noLevel })
        $r = Build $o
        @($r.LeftOut | ForEach-Object { "$($_.Collection)=$($_.Reason)" }) | Should -Be @('FS02=Unreadable')
        @($r.Warnings) | Should -Contain "Combined timeline: 1 of 2 collections isn't in it, FS02 because its timeline couldn't be read."
    }

    It 'names collections still Pending or Running after an interrupted batch' {
        $o = New-CombinedRoot 'cover-pending' @(
            @{ Name = 'WS01'; Bytes = $okRow }
            @{ Name = 'SQL01'; Status = 'Running'; Bytes = $null }
            @{ Name = 'SQL02'; Status = 'Pending'; Bytes = $null }
        )
        $r = Build $o
        @($r.LeftOut | ForEach-Object { "$($_.Collection)=$($_.Reason)" }) | Should -Be @('SQL01=Running', 'SQL02=Pending')
        @($r.Warnings) | Should -Contain "Combined timeline: 2 of 3 collections aren't in it, SQL01 and SQL02 because they haven't run yet."
    }

    It 'groups them by reason, failed first, each in the manifest''s order' {
        $o = New-CombinedRoot 'cover-groups' @(
            @{ Name = 'SQL01'; Status = 'Pending'; Bytes = $null }
            @{ Name = 'WS09'; Status = 'Failed'; Bytes = $null }
            @{ Name = 'DC01'; Bytes = $okRow }
            @{ Name = 'FS02'; Bytes = $noLevel }
            @{ Name = 'WS05'; Status = 'Failed'; Bytes = $okRow }
            @{ Name = 'SQL02'; Status = 'Running'; Bytes = $null }
            @{ Name = 'WS01'; Bytes = $okRow }
        )
        $r = Build $o
        $want = "Combined timeline: 5 of 7 collections aren't in it, WS09 and WS05 because they failed, FS02 because its timeline couldn't be read, and SQL01 and SQL02 because they haven't run yet."
        @($r.Warnings | Where-Object { $_ -like '*in it,*' }) | Should -Be @($want)
        $r.Hosts | Should -Be 2
        $r.Collections | Should -Be 7
    }

    It 'joins two groups with a comma and and' {
        Format-CombinedLeftOut -LeftOut @([pscustomobject]@{ Collection = 'A'; Reason = 'Failed' }, [pscustomobject]@{ Collection = 'B'; Reason = 'Pending' }) | Should -BeExactly "A because it failed, and B because it hasn't run yet"
    }

    It 'sanitises the names it lists' {
        $evil = "WS05$([char]27)[2J$([char]0x200B)"
        Format-CombinedLeftOut -LeftOut @([pscustomobject]@{ Collection = $evil; Reason = 'Failed' }) | Should -BeExactly 'WS05 because it failed'
    }

    It 'gives the same coverage on the dashboard and lists what''s left out' {
        $o = New-CombinedRoot 'cover-dashboard' @(
            @{ Name = 'WS01'; Bytes = $okRow }
            @{ Name = 'WS05'; Status = 'Failed'; Bytes = $null }
            @{ Name = 'SQL01'; Status = 'Pending'; Bytes = $null }
        )
        Invoke-Rollup -OutputRoot $o -WarningAction SilentlyContinue | Out-Null
        $html = [System.IO.File]::ReadAllText((Join-TestPath $o 'triage_dashboard.html'))
        $html | Should -Match ([regex]::Escape("holds the timelines of 1 of 3 collections in time order, 1 row, with Hayabusa's own columns. It leaves out WS05 because it failed, and SQL01 because it hasn&#39;t run yet."))
    }
}

Describe 'Memory' {
    It 'holds the same amount however many rows there are' {
        Initialize-CombinedTimelineType
        $peaks = foreach ($count in 200, 20000) {
            $dir = New-TestDirectory (Join-TestPath $TestDrive "mem-$count")
            $paths = foreach ($h in 1..3) {
                $p = Join-TestPath $dir "h$h.csv"
                $w = New-Object System.IO.StreamWriter($p, $false, $utf8)
                try {
                    $w.Write("$hdr`n")
                    $start = [datetime]::new(2026, 10, 1, 0, 0, 0, [System.DateTimeKind]::Utc).AddMilliseconds($h)
                    for ($i = 0; $i -lt $count; $i++) {
                        $t = $start.AddSeconds($i).ToString('yyyy-MM-dd HH:mm:ss.fff', [System.Globalization.CultureInfo]::InvariantCulture) + ' +00:00'
                        $w.Write((Row $t "H$h") + "`n")
                    }
                }
                finally {
                    $w.Dispose()
                }
                $p
            }
            $r = [HayabusaBulkRunner.CombinedTimeline]::Merge([string[]]@($paths), (Join-TestPath $dir 'out.csv'), 0, 1, 4096, 1MB, 64MB)
            $r.Rows | Should -Be (3 * $count)
            $r.PeakHeldBytes
        }
        $peaks[1] | Should -Be $peaks[0] -Because 'only one row per host and fixed buffers are held, so 100 times the rows holds the same'
    }
}

Describe 'In the rollup' {
    BeforeAll {
        $script:ro = New-CombinedRoot 'rollup' @(
            @{ Name = 'WS01'; Bytes = (ConvertTo-CsvByte @($hdr, (Row '2026-10-01 10:00:00.000 +00:00' 'WS01'), (Row '2026-10-01 12:00:00.000 +00:00' 'WS01'))) }
            @{ Name = 'WS02'; Bytes = (ConvertTo-CsvByte @($hdr, (Row '2026-10-01 11:00:00.000 +00:00' 'WS02'))) }
        )
    }

    It 'is built with the rest of the rollup and linked from the dashboard with its row count' {
        $r = Invoke-Rollup -OutputRoot $ro -WarningAction SilentlyContinue
        $r.CombinedTimeline.Path | Should -Be (Join-TestPath $ro 'combined_timeline.csv')
        $r.CombinedTimeline.Rows | Should -Be 3
        $r.CombinedTimeline.Hosts | Should -Be 2
        $html = [System.IO.File]::ReadAllText((Join-TestPath $ro 'triage_dashboard.html'))
        $html | Should -Match ([regex]::Escape('<a href="combined_timeline.csv">combined_timeline.csv</a> holds the timelines of 2 of 2 collections in time order, 3 rows, with Hayabusa''s own columns. Open it'))
    }

    It 'is left out with SkipCombinedTimeline, and the dashboard says it''s off' {
        $o = New-CombinedRoot 'rollup-off' @(@{ Name = 'WS01'; Bytes = (ConvertTo-CsvByte @($hdr, (Row '2026-10-01 10:00:00.000 +00:00'))) })
        $r = Invoke-Rollup -OutputRoot $o -SkipCombinedTimeline -WarningAction SilentlyContinue
        $r.CombinedTimeline.Enabled | Should -BeFalse
        $r.CombinedTimeline.Path | Should -BeNullOrEmpty
        Test-Path -LiteralPath (Join-TestPath $o 'combined_timeline.csv') | Should -BeFalse
        [System.IO.File]::ReadAllText((Join-TestPath $o 'triage_dashboard.html')) | Should -Match 'The combined timeline is turned off in the engagement config.'
    }

    It 'warns and still writes the triage files when it can''t be built' {
        $o = New-CombinedRoot 'rollup-bad' @(@{ Name = 'WS01'; Bytes = (ConvertTo-CsvByte @($hdr, (Row '2026-10-01 12:00:00.000 +00:00'), (Row '2026-10-01 10:00:00.000 +00:00'))) })
        $w = $null
        $r = Invoke-Rollup -OutputRoot $o -WarningVariable w -WarningAction SilentlyContinue
        $r.CombinedTimeline.Error | Should -BeLike "*WS01's timeline isn't in time order at line 3,*"
        @($w | ForEach-Object { "$_" }) | Should -Contain $r.CombinedTimeline.Error
        Test-Path -LiteralPath (Join-TestPath $o 'triage_hosts.csv') | Should -BeTrue
        $html = [System.IO.File]::ReadAllText((Join-TestPath $o 'triage_dashboard.html'))
        $html | Should -Match ([regex]::Escape("The combined timeline wasn't built this time, a host&#39;s timeline is out of time order"))
        $html | Should -Not -Match 'href="combined_timeline.csv"'
    }

    It 'is built by Invoke-HayabusaRollup.ps1' {
        $o = New-CombinedRoot 'rollup-script' @(
            @{ Name = 'WS01'; Bytes = (ConvertTo-CsvByte @($hdr, (Row '2026-10-01 10:00:00.000 +00:00' 'WS01'))) }
            @{ Name = 'WS02'; Bytes = (ConvertTo-CsvByte @($hdr, (Row '2026-10-01 09:00:00.000 +00:00' 'WS02'))) }
        )
        $iv = $null
        $r = & $RollupScript -OutputRoot $o -InformationVariable iv -InformationAction SilentlyContinue -WarningAction SilentlyContinue
        $r.CombinedTimeline.Rows | Should -Be 2
        (Get-CombinedLine $o)[1] | Should -BeLike '*"WS02"*'
        @($iv | ForEach-Object { "$_" }) | Should -Contain "The combined timeline is $(Join-TestPath $o 'combined_timeline.csv'), with 2 rows."
    }

    It 'gives the coverage from Invoke-HayabusaRollup.ps1 when collections are left out' {
        $o = New-CombinedRoot 'rollup-script-partial' @(
            @{ Name = 'WS01'; Bytes = (ConvertTo-CsvByte @($hdr, (Row '2026-10-01 10:00:00.000 +00:00' 'WS01'))) }
            @{ Name = 'WS05'; Status = 'Failed'; Bytes = $null }
        )
        $iv = $null
        $w = $null
        & $RollupScript -OutputRoot $o -InformationVariable iv -InformationAction SilentlyContinue -WarningVariable w -WarningAction SilentlyContinue | Out-Null
        @($iv | ForEach-Object { "$_" }) | Should -Contain "The combined timeline is $(Join-TestPath $o 'combined_timeline.csv'), with 1 row from 1 of 2 collections."
        @($w | ForEach-Object { "$_" }) | Should -Contain "Combined timeline: 1 of 2 collections isn't in it, WS05 because it failed."
    }
}

Describe 'The CombinedTimeline setting' {
    BeforeAll {
        $script:cfgDir = New-TestDirectory (Join-TestPath $TestDrive 'cfg')
        function script:Get-Setting([string]$Body) {
            $p = Write-TestText -Path (Join-TestPath $cfgDir "c$([guid]::NewGuid().ToString('N')).psd1") -Line @($Body)
            return (Get-CombinedTimelineSetting -Config (Import-EngagementConfig -Path $p))
        }
    }

    It 'is on by default, with or without a config' {
        Get-CombinedTimelineSetting -Config $null | Should -BeTrue
        Get-Setting '@{ Profile = ''standard'' }' | Should -BeTrue
    }

    It 'follows $true and $false' {
        Get-Setting '@{ CombinedTimeline = $false }' | Should -BeFalse
        Get-Setting '@{ CombinedTimeline = $true }' | Should -BeTrue
    }

    It 'refuses <Value>' -ForEach @(
        @{ Value = "'false'" }
        @{ Value = '0' }
        @{ Value = '$null' }
        @{ Value = '@($false)' }
    ) {
        Get-ThrownMessage { Get-Setting "@{ CombinedTimeline = $Value }" } | Should -BeLike '*sets CombinedTimeline to *. Set it to $true or $false, or remove the line.'
    }

    It 'is in the example config, commented out' {
        $example = [System.IO.File]::ReadAllText((Join-TestPath $RepoRoot 'config' 'engagement.example.psd1'))
        $example | Should -Match '(?m)^\s*# CombinedTimeline = \$false\s*$'
    }

    It 'reserves the file''s names, so no collection can take them' {
        $script:ReservedCollectionNames | Should -Contain 'combined_timeline.csv'
        $script:ReservedCollectionNames | Should -Contain 'combined_timeline.csv.tmp'
    }
}
