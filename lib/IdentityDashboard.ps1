# identity_dashboard.html: one row per host, read from the
# <Collection>_identity.json files the host identity engine writes. It is
# static and self-contained like triage_dashboard.html, with the same
# styles, encoding and Content Security Policy. The name shown is the
# registry computer name, kept separate from the names the triage view
# takes from Hayabusa's output.

$script:IdentityDashboardName = 'identity_dashboard.html'

# Statuses an identity file can hold, and the two the dashboard adds: no
# file yet, and a file it can't use.
$script:IdentityStatuses = @('Complete', 'Partial', 'Failed', 'NoRegistryHives')
$script:IdentityNotReadStatus = 'NotRead'
$script:IdentityUnreadableStatus = 'Unreadable'

$script:IdentityStatusLabel = @{
    Complete        = 'Complete'
    Partial         = 'Partial'
    Failed          = 'Failed'
    NoRegistryHives = 'No registry hives'
    NotRead         = 'Not read'
    Unreadable      = 'Unreadable'
}

# The triage dashboard's badge colours, reused.
$script:IdentityStatusClass = @{
    Complete        = 'st-Completed'
    Partial         = 'st-CompletedWithErrors'
    Failed          = 'st-Failed'
    Unreadable      = 'st-Failed'
    NoRegistryHives = 'st-other'
    NotRead         = 'st-other'
}

# Shown in place of the values of a host with none to show.
$script:IdentityStatusMessage = @{
    Failed          = 'Host identity could not be read. See the notes.'
    NoRegistryHives = 'No registry hives in this collection, as in one of event logs only.'
    NotRead         = 'Host identity has not been read for this collection.'
}

$script:IdentityDashboardCss = @'
details { margin-top: 3px; }
details summary { cursor: pointer; color: var(--muted); font-size: 12px; }
details ul { margin: 4px 0 0; padding-left: 16px; }
td.nm .chip { white-space: nowrap; overflow-wrap: normal; }
.sub { color: var(--muted); font-size: 12px; }
.chip.off { opacity: 0.6; }
'@

function ConvertTo-IdentityCellText {
    <#
    .SYNOPSIS
        A value read from an identity file as text, or null when empty.
    .DESCRIPTION
        PowerShell 7 reads a time such as 2026-01-01T00:00:00Z from JSON as
        a date. It's written back in that same UTC form, never in the
        local culture's.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($Value -is [datetime]) {
        return $Value.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
    }
    return (ConvertTo-IdentityText -Value $Value)
}

function Get-IdentityRow {
    <#
    .SYNOPSIS
        One dashboard row from a collection's identity file.
    .DESCRIPTION
        Copies only the fields the dashboard shows, by name, so nothing
        else in the file, such as a field a later version adds or one
        edited in by hand, can reach the page. Read flags say which hives
        were read, so a missing value from a hive that wasn't read is told
        apart from one the hive doesn't hold.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$OutputRoot,

        [Parameter(Mandatory)]
        [string]$Collection
    )

    $text = { param($o, [string[]]$n) ConvertTo-IdentityCellText -Value (Get-JsonValue -Object $o -Name $n) }
    $read = Read-HostIdentity -OutputRoot $OutputRoot -Collection $Collection

    $row = [pscustomobject]@{
        Collection       = $Collection
        Status           = $script:IdentityNotReadStatus
        HasData          = $false
        Message          = $null
        Hostname         = $null
        OsProduct        = $null
        OsBuild          = $null
        Membership       = $null
        DomainName       = $null
        DnsDomain        = $null
        TimeZoneName     = $null
        UtcOffset        = $null
        Interfaces       = @()
        InteractiveUsers = @()
        OtherUsers       = @()
        SystemRead       = $false
        SoftwareRead     = $false
        SamRead          = $false
        Notes            = @()
    }

    if (-not $read.Exists) {
        $row.Message = $script:IdentityStatusMessage[$script:IdentityNotReadStatus]
        return $row
    }
    if ($null -ne $read.Error) {
        $row.Status = $script:IdentityUnreadableStatus
        $row.Message = $read.Error
        return $row
    }

    $id = $read.Identity
    $status = & $text $id 'Status'
    if ($script:IdentityStatuses -notcontains $status) {
        $row.Status = $script:IdentityUnreadableStatus
        $row.Message = 'Its identity file has no status this tool knows.'
        return $row
    }
    $row.Status = $status
    $row.Notes = @(Get-JsonValue -Object $id -Name 'Notes' | ForEach-Object { ConvertTo-IdentityCellText -Value $_ } | Where-Object { $null -ne $_ })
    if ($status -eq 'Failed' -or $status -eq 'NoRegistryHives') {
        $row.Message = $script:IdentityStatusMessage[$status]
        return $row
    }

    $row.HasData = $true
    $row.SystemRead = ((Get-JsonValue -Object $id -Name 'Source', 'Hives', 'SYSTEM', 'Read') -eq $true)
    $row.SoftwareRead = ((Get-JsonValue -Object $id -Name 'Source', 'Hives', 'SOFTWARE', 'Read') -eq $true)
    $row.SamRead = ((Get-JsonValue -Object $id -Name 'Source', 'Hives', 'SAM', 'Read') -eq $true)
    $row.Hostname = & $text $id 'Hostname'
    $row.OsProduct = & $text $id 'Os', 'ProductName'
    $row.OsBuild = & $text $id 'Os', 'Build'
    $row.Membership = & $text $id 'Domain', 'Membership'
    $row.DomainName = & $text $id 'Domain', 'CachePrimaryDomain'
    $row.DnsDomain = & $text $id 'Domain', 'DnsDomain'
    if ($null -eq $row.DnsDomain) {
        $row.DnsDomain = & $text $id 'Domain', 'NvDomain'
    }
    $row.TimeZoneName = & $text $id 'TimeZone', 'KeyName'
    $row.UtcOffset = & $text $id 'TimeZone', 'ActiveUtcOffset'

    $row.Interfaces = @(foreach ($i in @(Get-JsonValue -Object $id -Name 'Interfaces')) {
            if ($null -eq $i) {
                continue
            }
            [pscustomobject]@{
                Address          = & $text $i 'Address'
                NetworkName      = & $text $i 'NetworkName'
                LeaseObtainedUtc = & $text $i 'LeaseObtainedUtc'
                LikelyActive     = ((Get-JsonValue -Object $i -Name 'LikelyActive') -eq $true)
            }
        })

    $interactive = New-Object System.Collections.Generic.List[object]
    $other = New-Object System.Collections.Generic.List[object]
    foreach ($u in @(Get-JsonValue -Object $id -Name 'Users')) {
        if ($null -eq $u) {
            continue
        }
        $user = [pscustomobject]@{
            UserName    = & $text $u 'UserName'
            AccountType = & $text $u 'AccountType'
            Disabled    = ((Get-JsonValue -Object $u -Name 'Flags', 'AccountDisabled') -eq $true)
        }
        if ($user.AccountType -eq 'Interactive') {
            $interactive.Add($user)
        }
        else {
            $other.Add($user)
        }
    }
    $row.InteractiveUsers = $interactive.ToArray()
    $row.OtherUsers = $other.ToArray()
    return $row
}

function Get-IdentityRollupData {
    <#
    .SYNOPSIS
        The rows of the identity dashboard, one per collection.
    .DESCRIPTION
        The collections are this run's, given with Collection, those in
        the manifest when there is one, and any collection folder under
        OutputRoot holding an identity file, so a host read by an earlier
        run is still shown. A collection with no identity file is Not read.
        Hosts with a registry name come first, by that name, then the rest
        by collection. Nothing is written.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$OutputRoot,

        [AllowEmptyCollection()]
        [string[]]$Collection = @()
    )

    $warnings = New-Object System.Collections.Generic.List[string]
    $names = New-Object System.Collections.Generic.List[string]
    $seen = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)
    $add = {
        param($n)
        if (-not [string]::IsNullOrEmpty($n) -and $seen.Add($n)) {
            $names.Add($n)
        }
    }

    foreach ($c in $Collection) {
        & $add $c
    }
    $manifestPath = Join-Path -Path $OutputRoot -ChildPath 'run_manifest.csv'
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        try {
            Assert-RunManifestHeader -Path $manifestPath
            foreach ($k in (Get-RunManifest -Path $manifestPath).Keys) {
                & $add ([string]$k)
            }
        }
        catch {
            $warnings.Add("run_manifest.csv could not be read, so only collections with an identity file are listed: $($_.Exception.Message)")
        }
    }
    foreach ($dir in @(Get-ChildItem -LiteralPath $OutputRoot -Directory -ErrorAction SilentlyContinue | Sort-Object -Property Name)) {
        if ($dir.Name.StartsWith('_')) {
            continue
        }
        if (Test-Path -LiteralPath (Get-HostIdentityPath -OutputRoot $OutputRoot -Collection $dir.Name) -PathType Leaf) {
            & $add $dir.Name
        }
    }

    $rows = foreach ($n in $names) {
        Get-IdentityRow -OutputRoot $OutputRoot -Collection $n
    }
    $sorted = @($rows | Sort-Object -Property @(
            @{ Expression = { if ($null -ne $_.Hostname) { 0 } else { 1 } } }
            @{ Expression = { [string]$_.Hostname } }
            @{ Expression = { $_.Collection } }
        ))

    return [pscustomobject]@{
        OutputRoot = $OutputRoot
        BuiltUtc   = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
        Hosts      = $sorted
        Warnings   = $warnings.ToArray()
    }
}

function Get-IdentityStatusBadge {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Status
    )

    $class = 'st-other'
    $label = $Status
    if ($script:IdentityStatusClass.ContainsKey($Status)) {
        $class = $script:IdentityStatusClass[$Status]
        $label = $script:IdentityStatusLabel[$Status]
    }
    return "<span class=`"badge $class`">$(ConvertTo-HtmlText -Text $label)</span>"
}

function New-IdentityDashboardHtml {
    <#
    .SYNOPSIS
        Builds identity_dashboard.html from the identity rollup data.
    .DESCRIPTION
        One row per host: the registry computer name, collection, status,
        OS and build, domain, time zone, the likely active address with its
        network name, and the interactive users. The other interfaces,
        newest lease first, and the built-in and system accounts are folded
        under each row. A host with nothing to show says why across its
        row. A value from a hive that wasn't read shows as not read, and
        one the hive doesn't hold as not found. Every value is
        HTML-encoded.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds a string only.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Data
    )

    $hosts = @($Data.Hosts)
    $sb = New-Object System.Text.StringBuilder
    $e = { param($v) ConvertTo-HtmlText -Text $v }
    $chip = { param($v, $class) "<span class=`"chip $class`">$(& $e $v)</span>" }
    $sub = { param($v) "<div class=`"sub`">$(& $e $v)</div>" }
    # A value, or why there is none: its hive wasn't read, or it doesn't
    # hold the value.
    $missing = { param($wasRead) if ($wasRead) { '<span class="dim">not found</span>' } else { '<span class="dim">not read</span>' } }
    $rel = { param($t) ConvertTo-RelativeNote -Text $t -OutputRoot $Data.OutputRoot }

    $count = { param($s) @($hosts | Where-Object { $_.Status -eq $s }).Count }

    [void]$sb.AppendLine('<!DOCTYPE html>')
    [void]$sb.AppendLine('<html lang="en">')
    [void]$sb.AppendLine('<head>')
    [void]$sb.AppendLine('<meta charset="utf-8">')
    [void]$sb.AppendLine("<meta http-equiv=`"Content-Security-Policy`" content=`"$(& $e $script:DashboardCsp)`">")
    [void]$sb.AppendLine('<meta name="viewport" content="width=device-width, initial-scale=1">')
    [void]$sb.AppendLine('<meta name="referrer" content="no-referrer">')
    [void]$sb.AppendLine('<title>Host identity</title>')
    [void]$sb.AppendLine("<style>$script:DashboardCss$script:IdentityDashboardCss</style>")
    [void]$sb.AppendLine('</head>')
    [void]$sb.AppendLine('<body><main>')

    [void]$sb.AppendLine('<h1>Host identity</h1>')
    [void]$sb.AppendLine("<p class=`"meta`">Built $(& $e $Data.BuiltUtc) from $(& $e $hosts.Count) collection(s). Names, addresses and users come from each host's registry hives.</p>")
    [void]$sb.AppendLine('<div class="health">')
    [void]$sb.AppendLine("<span><b>$(& $e $hosts.Count)</b> hosts</span>")
    foreach ($s in @('Complete', 'Partial', 'Failed', 'NoRegistryHives', 'NotRead', 'Unreadable')) {
        [void]$sb.AppendLine("<span><b>$(& $e (& $count $s))</b> $(& $e $script:IdentityStatusLabel[$s])</span>")
    }
    [void]$sb.AppendLine('</div>')

    $changed = @($hosts | Where-Object { @($_.Notes | Where-Object { ([string]$_).StartsWith($script:EvidenceChangedPrefix) }).Count -gt 0 })
    if ($changed.Count -gt 0) {
        $names = @($changed | ForEach-Object { & $e $_.Collection }) -join ', '
        [void]$sb.AppendLine("<div class=`"warnbox evidence`">$(& $e $script:EvidenceChangedPrefix) for $(& $e $changed.Count) collection(s): $names. See the host's notes before relying on that evidence.</div>")
    }

    [void]$sb.AppendLine('<h2 id="hosts">Hosts</h2>')
    if ($hosts.Count -eq 0) {
        [void]$sb.AppendLine('<p class="dim">No collections with host identity.</p>')
    }
    else {
        [void]$sb.AppendLine('<div class="wrap"><table>')
        [void]$sb.AppendLine('<thead><tr><th>Hostname</th><th>Collection</th><th>Status</th><th>OS</th><th>Domain</th><th>Time zone</th><th>Active IP</th><th>Users</th></tr></thead><tbody>')
        foreach ($h in $hosts) {
            $statusCell = Get-IdentityStatusBadge -Status $h.Status
            $notes = @($h.Notes)
            if ($notes.Count -gt 0) {
                $items = @($notes | ForEach-Object {
                        $n = & $e (& $rel $_)
                        if (([string]$_).StartsWith($script:EvidenceChangedPrefix)) {
                            $n = "<span class=`"err`">$n</span>"
                        }
                        "<li>$n</li>"
                    }) -join ''
                $word = 'notes'
                if ($notes.Count -eq 1) {
                    $word = 'note'
                }
                $statusCell += "<details><summary>$(& $e $notes.Count) $word</summary><ul class=`"notes`">$items</ul></details>"
            }

            if (-not $h.HasData) {
                [void]$sb.AppendLine("<tr><td><span class=`"dim`">not read</span></td><td>$(& $e $h.Collection)</td><td>$statusCell</td><td colspan=`"5`" class=`"dim`">$(& $e (& $rel $h.Message))</td></tr>")
                continue
            }

            $hostCell = & $missing $h.SystemRead
            if ($null -ne $h.Hostname) {
                $hostCell = & $chip $h.Hostname ''
            }

            $osCell = & $missing $h.SoftwareRead
            if ($null -ne $h.OsProduct -or $null -ne $h.OsBuild) {
                $osCell = ''
                if ($null -ne $h.OsProduct) {
                    $osCell = & $e $h.OsProduct
                }
                if ($null -ne $h.OsBuild) {
                    # Windows 11 keeps the Windows 10 product name in the
                    # registry, so its build is tagged.
                    $tag = ''
                    $build = 0
                    if ([int]::TryParse($h.OsBuild, [ref]$build) -and $build -ge 22000 -and [string]$h.OsProduct -like 'Windows 10*') {
                        $tag = '<span class="tag">Windows 11</span>'
                    }
                    $osCell += "<div class=`"sub`">build $(& $e $h.OsBuild)$tag</div>"
                }
            }

            # Membership comes from Winlogon in SOFTWARE, the DNS domain from SYSTEM.
            $domainCell = & $missing $h.SoftwareRead
            if ($h.Membership -eq 'Domain' -and $null -ne $h.DomainName) {
                $domainCell = & $e $h.DomainName
            }
            elseif ($h.SoftwareRead) {
                $domainCell = '<span class="dim">no domain evidence</span>'
            }
            if ($null -ne $h.DnsDomain -and $h.DnsDomain -ine [string]$h.DomainName) {
                $domainCell += & $sub $h.DnsDomain
            }

            $tzCell = & $missing $h.SystemRead
            if ($null -ne $h.TimeZoneName -or $null -ne $h.UtcOffset) {
                $tzCell = & $e $h.TimeZoneName
                if ($null -ne $h.UtcOffset) {
                    $tzCell += & $sub "UTC$($h.UtcOffset)"
                }
            }

            $interfaces = @($h.Interfaces)
            $active = @($interfaces | Where-Object { $_.LikelyActive }) | Select-Object -First 1
            $ipCell = & $missing $h.SystemRead
            if ($interfaces.Count -gt 0) {
                if ($null -ne $active) {
                    $ipCell = & $chip $active.Address ''
                    if ($null -ne $active.NetworkName) {
                        $ipCell += & $sub $active.NetworkName
                    }
                }
                else {
                    $ipCell = '<span class="dim">none flagged</span>'
                }
                $rest = @($interfaces | Where-Object { -not $_.LikelyActive })
                if ($rest.Count -gt 0) {
                    $items = @($rest | ForEach-Object {
                            $line = '<span class="dim">no address</span>'
                            if ($null -ne $_.Address) {
                                $line = & $e $_.Address
                            }
                            if ($null -ne $_.NetworkName) {
                                $line += " $(& $e $_.NetworkName)"
                            }
                            if ($null -ne $_.LeaseObtainedUtc) {
                                $line += " <span class=`"dim`">$(& $e $_.LeaseObtainedUtc)</span>"
                            }
                            "<li>$line</li>"
                        }) -join ''
                    $label = "$($rest.Count) more"
                    if ($null -eq $active -and $rest.Count -eq 1) {
                        $label = '1 interface'
                    }
                    elseif ($null -eq $active) {
                        $label = "$($rest.Count) interfaces"
                    }
                    $ipCell += "<details><summary>$(& $e $label)</summary><ul>$items</ul></details>"
                }
            }
            elseif ($h.SystemRead) {
                $ipCell = '<span class="dim">none found</span>'
            }

            $userCell = & $missing $h.SamRead
            if ($h.SamRead) {
                $interactive = @($h.InteractiveUsers)
                $others = @($h.OtherUsers)
                if ($interactive.Count -gt 0) {
                    $userCell = @($interactive | ForEach-Object {
                            if ($_.Disabled) {
                                "$(& $chip $_.UserName 'off')<span class=`"tag`">disabled</span>"
                            }
                            else {
                                & $chip $_.UserName ''
                            }
                        }) -join ' '
                }
                else {
                    $userCell = '<span class="dim">no interactive users</span>'
                }
                if ($others.Count -gt 0) {
                    $items = @($others | ForEach-Object { "<li>$(& $e $_.UserName) <span class=`"dim`">$(& $e $_.AccountType)</span></li>" }) -join ''
                    $userCell += "<details><summary>$(& $e $others.Count) built-in or system</summary><ul>$items</ul></details>"
                }
            }

            [void]$sb.AppendLine("<tr><td class=`"nm`">$hostCell</td><td>$(& $e $h.Collection)</td><td>$statusCell</td><td>$osCell</td><td>$domainCell</td><td>$tzCell</td><td class=`"nm`">$ipCell</td><td>$userCell</td></tr>")
        }
        [void]$sb.AppendLine('</tbody></table></div>')
        [void]$sb.AppendLine('<p class="dim">Hostname is the ComputerName in the registry, which can differ from the computer names in the triage dashboard. Active IP is the interface with the newest DHCP lease, or the only one with an address. The other interfaces, newest lease first, and the built-in and system accounts are folded under each row. Not read means the hive holding that value was not read. Time zone offsets are the ones in force when the hive was last written.</p>')
    }

    [void]$sb.AppendLine("<footer>Files beside $(& $e $script:IdentityDashboardName): one Collection_identity.json in each collection's folder. Times are UTC.</footer>")
    [void]$sb.AppendLine('</main></body>')
    [void]$sb.AppendLine('</html>')
    return $sb.ToString()
}

function Invoke-IdentityRollup {
    <#
    .SYNOPSIS
        Writes identity_dashboard.html under OutputRoot.
    .DESCRIPTION
        Built only from the identity files and the manifest, so it can be
        rebuilt at any time without reading a hive again. Nothing it reads
        is modified, and the dashboard is written atomically.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$OutputRoot,

        [AllowEmptyCollection()]
        [string[]]$Collection = @()
    )

    $data = Get-IdentityRollupData -OutputRoot $OutputRoot -Collection $Collection
    $path = Join-Path -Path $OutputRoot -ChildPath $script:IdentityDashboardName
    if ($PSCmdlet.ShouldProcess($path, 'Write identity dashboard')) {
        Write-TextFileAtomic -Path $path -Text (New-IdentityDashboardHtml -Data $data)
    }
    foreach ($w in $data.Warnings) {
        Write-Warning "Identity dashboard: $w"
    }
    $counts = [ordered]@{}
    foreach ($s in @('Complete', 'Partial', 'Failed', 'NoRegistryHives', 'NotRead', 'Unreadable')) {
        $counts[$s] = @($data.Hosts | Where-Object { $_.Status -eq $s }).Count
    }
    [pscustomobject]@{
        Dashboard = $path
        HostCount = @($data.Hosts).Count
        Counts    = $counts
        Warnings  = $data.Warnings
        BuiltUtc  = $data.BuiltUtc
    }
}
