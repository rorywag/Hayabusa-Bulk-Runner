BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers/TestHelpers.ps1')

    $script:expectedHeader = '"Host","Collection","Source","RunId","InputType","Status","Detections","Emergency","Critical","High","Warning","Error","DurationSec","Timestamp"'
    function script:New-ManifestPath {
        $p = Join-TestPath $TestDrive ("m{0}.csv" -f [guid]::NewGuid().ToString('N'))
        Initialize-RunManifest -Path $p | Out-Null
        $p
    }
}

Describe 'Manifest file' {
    It 'has the expected header and no BOM' {
        $p = New-ManifestPath
        Get-Content -LiteralPath $p -TotalCount 1 | Should -Be $expectedHeader
        $b = [System.IO.File]::ReadAllBytes($p)
        ($b[0] -eq 0xEF -and $b[1] -eq 0xBB) | Should -BeFalse
    }

    It 'refuses an existing manifest with the wrong columns, including the earliest and pre-emergency layouts' -ForEach @(
        @{ Header = '"Host","InputType","Status"' }
        @{ Header = '"Host","RunId","InputType","Status","Detections","Critical","High","Error","DurationSec","Timestamp"' }
        @{ Header = '"Host","Collection","Source","RunId","InputType","Status","Detections","Critical","High","Warning","Error","DurationSec","Timestamp"' }
    ) {
        $p = Write-TestText -Path (Join-TestPath $TestDrive ("old{0}.csv" -f [guid]::NewGuid().ToString('N'))) -Line @($Header)
        Get-ThrownMessage { Initialize-RunManifest -Path $p } | Should -BeLike '*unexpected columns*'
        Get-ThrownMessage { Assert-RunManifestHeader -Path $p } | Should -BeLike '*unexpected columns*'
    }
}

Describe 'Manifest rows' {
    It 'upserts by collection, case-insensitively' {
        $p = New-ManifestPath
        Set-RunManifestEntry -Path $p -Collection 'HOST01' -Source 'HOST01' -RunId 'r1' -InputType Loose -Status Running
        Set-RunManifestEntry -Path $p -Collection 'HOST02' -Source 'HOST02.zip' -RunId 'r1' -InputType Zip -Status Failed -ErrorMessage "line1`r`nline2"
        Set-RunManifestEntry -Path $p -Collection 'host01' -Source 'HOST01' -RunId 'r2' -InputType Loose -Status Completed -Detections 5 -Emergency 1 -Critical 1 -High 2 -DurationSec 12.345 -HostName 'WS01'
        $rows = @(Import-Csv -LiteralPath $p)
        $rows.Count | Should -Be 2
        $rows[0].RunId | Should -Be 'r2'
        $rows[0].Host | Should -Be 'WS01'
        $rows[0].Emergency | Should -Be '1'
        $rows[0].DurationSec | Should -Be '12.3'
        $rows[0].Timestamp | Should -Match '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$'
        $rows[1].Source | Should -Be 'HOST02.zip'
        $rows[1].Error | Should -Be 'line1 line2'
        Test-Path -LiteralPath ($p + '.tmp') | Should -BeFalse
        $e = Get-RunManifest -Path $p
        $e.Contains('host02') | Should -BeTrue
    }

    It 'accepts CompletedWithErrors and rejects unknown statuses' {
        $p = New-ManifestPath
        Set-RunManifestEntry -Path $p -Collection 'A' -Source 'A' -RunId 'r' -InputType Loose -Status CompletedWithErrors
        Get-ThrownMessage { Set-RunManifestEntry -Path $p -Collection 'H' -Source 'H' -RunId 'r' -InputType Loose -Status Done } | Should -BeLike '*Done*'
    }

    It 'Add-PendingCollection adds new collections only and leaves existing rows alone' {
        $p = New-ManifestPath
        Set-RunManifestEntry -Path $p -Collection 'HOST01' -Source 'HOST01' -RunId 'old' -InputType Loose -Status Completed -HostName 'WS01' -Detections 3
        $cols = @(
            [pscustomobject]@{ Collection = 'HOST01'; Source = 'HOST01'; InputType = 'Loose'; Warnings = @() }
            [pscustomobject]@{ Collection = 'HOST03'; Source = 'HOST03.VHDX'; InputType = 'Vhdx'; Warnings = @() }
            [pscustomobject]@{ Collection = 'IMG'; Source = 'IMG.zip'; InputType = 'Zip'; Warnings = @('Skipped evidence: x') }
        )
        Add-PendingCollection -Path $p -Collections $cols -RunId 'new' | Should -Be 2
        $rows = @{}; Import-Csv -LiteralPath $p | ForEach-Object { $rows[$_.Collection] = $_ }
        $rows.HOST01.Status | Should -Be 'Completed'
        $rows.HOST01.RunId | Should -Be 'old'
        $rows.HOST03.Status | Should -Be 'Pending'
        $rows.HOST03.Host | Should -Be ''
        $rows.HOST03.Source | Should -Be 'HOST03.VHDX'
        $rows.IMG.Warning | Should -BeLike 'Skipped evidence*'
        Add-PendingCollection -Path $p -Collections $cols -RunId 'x' | Should -Be 0
    }
}

Describe 'Manifest formula escaping' {
    It 'ConvertTo-ManifestCell and ConvertFrom-ManifestCell round-trip <Value>' -ForEach @(
        @{ Value = '=cmd|calc' }, @{ Value = '+SUM(1)' }, @{ Value = '-HOST' }, @{ Value = '@SUM(1)' }
        @{ Value = "`tTAB" }, @{ Value = "'=already" }, @{ Value = "''two" }, @{ Value = 'WS01' }, @{ Value = '' }
    ) {
        $escaped = ConvertTo-ManifestCell -Value $Value
        if ($Value -match "^['=+\-@\t\r]") { $escaped | Should -BeExactly ("'" + $Value) } else { $escaped | Should -BeExactly $Value }
        ConvertFrom-ManifestCell -Value $escaped | Should -BeExactly $Value
    }

    It 'escapes evidence-derived cells on write and returns the exact values on read' {
        $p = New-ManifestPath
        $hostValue = '=HYPERLINK("http://x","y")'
        $warn = '+cmd|calc'
        $err = "@SUM(1)"
        Set-RunManifestEntry -Path $p -Collection '-HOST' -Source '-HOST' -RunId 'r1' -InputType Loose -Status Completed -HostName $hostValue -WarningMessage @($warn) -ErrorMessage @($err)
        $raw = @(Import-Csv -LiteralPath $p)
        $raw[0].Host | Should -BeExactly ("'" + $hostValue)
        $raw[0].Collection | Should -BeExactly "'-HOST"
        $raw[0].Source | Should -BeExactly "'-HOST"
        $raw[0].Warning | Should -BeExactly "'+cmd|calc"
        $raw[0].Error | Should -BeExactly "'@SUM(1)"
        $raw[0].RunId | Should -BeExactly 'r1'
        $cells = foreach ($r in $raw) { foreach ($prop in $r.PSObject.Properties) { [string]$prop.Value } }
        @($cells | Where-Object { $_ -match '^[=+\-@\t\r]' }).Count | Should -Be 0

        $back = (Get-RunManifest -Path $p)['-HOST']
        $back.Host | Should -BeExactly $hostValue
        $back.Collection | Should -BeExactly '-HOST'
        $back.Warning | Should -BeExactly $warn
        $back.Error | Should -BeExactly $err
    }

    It 'stays lossless across repeated rewrites' {
        $p = New-ManifestPath
        Set-RunManifestEntry -Path $p -Collection 'A' -Source 'A' -RunId 'r1' -InputType Loose -Status Completed -HostName "'=quoted"
        foreach ($i in 1..3) { Set-RunManifestEntry -Path $p -Collection "B$i" -Source "B$i" -RunId 'r' -InputType Loose -Status Pending }
        (Get-RunManifest -Path $p)['A'].Host | Should -BeExactly "'=quoted"
        @(Import-Csv -LiteralPath $p | Where-Object Collection -eq 'A')[0].Host | Should -BeExactly "''=quoted"
    }
}

Describe 'Run metadata files' {
    It 'is never overwritten, but -Update rewrites its own file' {
        $p = Join-TestPath $TestDrive '_runs' 'run_meta_x.json'
        Save-RunMeta -Path $p -RunMeta ([ordered]@{ a = 1 }) | Out-Null
        Get-ThrownMessage { Save-RunMeta -Path $p -RunMeta ([ordered]@{ a = 2 }) } | Should -BeLike '*will not be overwritten*'
        Save-RunMeta -Path $p -RunMeta ([ordered]@{ RunId = 'x'; CompletedUtc = '2026-10-11T00:00:00Z' }) -Update | Out-Null
        [System.IO.File]::ReadAllText($p) | Should -Match '"CompletedUtc":\s*"2026-10-11T00:00:00Z"'
    }

    It 'does not truncate deep objects' {
        $p = Join-TestPath $TestDrive 'deep.json'
        Save-RunMeta -Path $p -RunMeta ([ordered]@{ a = [ordered]@{ b = [ordered]@{ c = [ordered]@{ d = @('e') } } } }) | Out-Null
        (Get-Content -LiteralPath $p -Raw | ConvertFrom-Json).a.b.c.d[0] | Should -Be 'e'
    }

    It 'names two runs in the same second differently, using the RunId' {
        $t = New-Object DateTime 2026, 10, 11, 9, 0, 0, ([DateTimeKind]::Utc)
        $id1 = [guid]::NewGuid().ToString(); $id2 = [guid]::NewGuid().ToString()
        $p1 = Get-RunMetaPath -OutputRoot $TestDrive -StartedUtc $t -RunId $id1
        $p2 = Get-RunMetaPath -OutputRoot $TestDrive -StartedUtc $t -RunId $id2
        $p1 | Should -Not -Be $p2
        Split-Path -Leaf $p1 | Should -Be "run_meta_20261011T090000Z_$id1.json"
    }
}

Describe 'Image hash in run-meta' {
    It 'records both hashes and the match per collection, null where there was no image' {
        $meta = [ordered]@{
            Collections = @(
                [ordered]@{ Collection = 'IMG'; Source = 'IMG.vhdx'; InputType = 'Vhdx'; ImagePath = $null; ImageSha256Before = $null; ImageSha256After = $null; ImageHashMatch = $null }
                [ordered]@{ Collection = 'LOOSE'; Source = 'LOOSE'; InputType = 'Loose'; ImagePath = $null; ImageSha256Before = $null; ImageSha256After = $null; ImageHashMatch = $null }
                [ordered]@{ Collection = 'SKIPPED'; Source = 'SKIPPED.vhdx'; InputType = 'Vhdx'; ImagePath = $null; ImageSha256Before = $null; ImageSha256After = $null; ImageHashMatch = $null }
            )
        }
        $hashes = [ordered]@{
            IMG   = [pscustomobject]@{ ImagePath = 'D:\Evidence\IMG.vhdx'; Before = 'A' * 64; After = 'A' * 64; Match = $true }
            LOOSE = $null
        }
        Set-RunMetaImageHash -RunMeta $meta -ImageHash $hashes
        $p = Join-TestPath $TestDrive 'hash-meta.json'
        Save-RunMeta -Path $p -RunMeta $meta | Out-Null
        $c = @((Get-Content -LiteralPath $p -Raw | ConvertFrom-Json).Collections)
        $c[0].ImagePath | Should -Be 'D:\Evidence\IMG.vhdx'
        $c[0].ImageSha256Before | Should -BeExactly ('A' * 64)
        $c[0].ImageSha256After | Should -BeExactly ('A' * 64)
        $c[0].ImageHashMatch | Should -BeTrue
        foreach ($entry in $c[1], $c[2]) {
            $entry.ImageSha256Before | Should -BeNullOrEmpty
            $entry.ImageHashMatch | Should -BeNullOrEmpty
        }
    }
}

Describe 'Path helpers' {
    It 'strips trailing separators and keeps drive roots' {
        $d = New-TestDirectory (Join-TestPath $TestDrive 'norm')
        ConvertTo-NormalizedPath -Path ($d + [System.IO.Path]::DirectorySeparatorChar) | Should -Be $d
        Test-PathIsWithin -Path (Join-TestPath $d 'x') -Parent $d | Should -BeTrue
        Test-PathIsWithin -Path ($d + 'x') -Parent $d | Should -BeFalse
    }

    It 'Write-TextFileAtomic refuses a folder in the way' {
        $d = New-TestDirectory (Join-TestPath $TestDrive 'blocker' 'triage_dashboard.html')
        Get-ThrownMessage { Write-TextFileAtomic -Path $d -Text 'x' } | Should -BeLike '*folder of that name is in the way*'
    }
}

Describe 'Atomic replace' {
    It 'swaps an existing file with File.Replace, not the move fallback' {
        Mock Move-Item { }
        $p = Join-TestPath $TestDrive 'atomic.txt'
        [System.IO.File]::WriteAllText($p, 'one')
        Write-TextFileAtomic -Path $p -Text 'two'
        [System.IO.File]::ReadAllText($p) | Should -BeExactly 'two'
        Test-Path -LiteralPath ($p + '.tmp') | Should -BeFalse
        Should -Invoke Move-Item -Times 0 -Exactly
    }
    It 'updates an existing manifest with File.Replace, not the move fallback' {
        Mock Move-Item { }
        $m = Join-TestPath $TestDrive 'atomic_manifest.csv'
        Initialize-RunManifest -Path $m | Out-Null
        Set-RunManifestEntry -Path $m -Collection 'A1' -Source 'A1' -RunId 'r' -InputType Loose -Status Completed
        (Get-RunManifest -Path $m).Contains('A1') | Should -BeTrue
        Test-Path -LiteralPath ($m + '.tmp') | Should -BeFalse
        Should -Invoke Move-Item -Times 0 -Exactly
    }
}

Describe 'Timestamps under another culture' {
    BeforeAll {
        # Thai uses the Buddhist calendar, 543 years ahead, and this copy also
        # uses '.' as its time separator, as some locales do.
        $script:culture = ([System.Globalization.CultureInfo]::new('th-TH')).Clone()
        $script:culture.DateTimeFormat.TimeSeparator = '.'
        $script:stampPattern = '^20\d\d-\d\d-\d\dT\d\d:\d\d:\d\dZ$'
        function script:Invoke-InCulture([scriptblock]$Script) {
            $thread = [System.Threading.Thread]::CurrentThread
            $saved = $thread.CurrentCulture
            try {
                $thread.CurrentCulture = $culture
                & $Script
            }
            finally {
                $thread.CurrentCulture = $saved
            }
        }
    }

    It 'names the run-meta file with Gregorian digits' {
        $t = New-Object DateTime 2026, 10, 11, 9, 5, 7, ([DateTimeKind]::Utc)
        $leaf = Invoke-InCulture { Split-Path -Leaf (Get-RunMetaPath -OutputRoot $TestDrive -StartedUtc $t -RunId 'r1') }
        $leaf | Should -BeExactly 'run_meta_20261011T090507Z_r1.json'
    }
    It 'writes the manifest Timestamp and the rollup build time in the invariant form' {
        $o = New-TestDirectory (Join-TestPath $TestDrive 'culture-out')
        $m = Join-TestPath $o 'run_manifest.csv'
        Initialize-RunManifest -Path $m | Out-Null
        $built = Invoke-InCulture {
            Set-RunManifestEntry -Path $m -Collection 'H1' -Source 'H1' -RunId 'r1' -InputType Loose -Status Pending
            (Get-RollupData -OutputRoot $o).BuiltUtc
        }
        (Get-RunManifest -Path $m)['H1'].Timestamp | Should -Match $stampPattern
        $built | Should -Match $stampPattern
    }
}
