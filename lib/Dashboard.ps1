# triage_dashboard.html is static: inline CSS, no script, no external requests. The
# Content Security Policy also forbids script outright, so even a value that
# somehow escaped encoding could not run.
$script:DashboardCsp = "default-src 'none'; style-src 'unsafe-inline'"

# How many rules the summary lists, and how many collections a rule row names.
$script:SummaryTopRules = 5
$script:RuleCollectionsShown = 10

# Only these values become CSS class names. Anything else maps to "other".
$script:KnownLevels = @('emergency', 'critical', 'high', 'medium', 'low', 'informational')
$script:KnownStatuses = @('Pending', 'Running', 'Completed', 'CompletedWithErrors', 'Failed', 'Skipped')

$script:DashboardCss = @'
:root {
  --bg: #f6f7f9; --panel: #ffffff; --text: #1d2330; --muted: #5b6577; --line: #dde1e8;
  --emer: #9b1470; --emer-bg: #f9e0f0;
  --crit: #b4232c; --crit-bg: #fbe4e5; --high: #b85a00; --high-bg: #fdebd8;
  --med: #8a6d00; --med-bg: #fbf3cf; --low: #2457a6; --low-bg: #e1ebfa;
  --info: #56606f; --info-bg: #eceef2; --ok: #2b7a3d; --ok-bg: #e0f2e4;
  --link: #2457a6;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #14171d; --panel: #1c2028; --text: #e4e7ed; --muted: #9aa3b2; --line: #2e3440;
    --emer: #ff8fd6; --emer-bg: #4a1a3b;
    --crit: #ff8a8f; --crit-bg: #4a1d21; --high: #ffb36b; --high-bg: #47301a;
    --med: #f0d264; --med-bg: #3f3818; --low: #8fb6ff; --low-bg: #1d2c47;
    --info: #b3bac6; --info-bg: #2a2f38; --ok: #7ed492; --ok-bg: #1d3a25;
    --link: #8fb6ff;
  }
}
* { box-sizing: border-box; }
body { margin: 0; padding: 24px 16px 48px; background: var(--bg); color: var(--text);
  font: 14px/1.45 -apple-system, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; }
main { max-width: 1400px; margin: 0 auto; }
h1 { font-size: 22px; margin: 0 0 4px; }
h2 { font-size: 17px; margin: 28px 0 10px; }
.meta { color: var(--muted); margin: 0 0 18px; }
.tiles { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 10px; }
.tile { background: var(--panel); border: 1px solid var(--line); border-radius: 8px; padding: 10px 12px; }
.tile .n { font-size: 24px; font-weight: 600; }
.tile .l { color: var(--muted); font-size: 12px; }
.tile.emer .n { color: var(--emer); } .tile.crit .n { color: var(--crit); } .tile.high .n { color: var(--high); }
.tile.med .n { color: var(--med); } .tile.low .n { color: var(--low); }
.tile.zero { background: transparent; }
.tile.zero .n { color: var(--muted); font-weight: 400; }
.panel { background: var(--panel); border: 1px solid var(--line); border-radius: 8px; padding: 12px 14px; margin-top: 12px; }
.panel h3 { font-size: 14px; margin: 0 0 8px; }
.panel ol { margin: 0; padding-left: 20px; }
.health { display: flex; flex-wrap: wrap; gap: 8px 18px; margin-top: 12px; color: var(--muted); }
.health b { color: var(--text); }
.wrap { overflow-x: auto; background: var(--panel); border: 1px solid var(--line); border-radius: 8px; }
table { border-collapse: collapse; width: 100%; }
th, td { text-align: left; padding: 7px 10px; border-bottom: 1px solid var(--line); vertical-align: top; }
th { font-size: 12px; color: var(--muted); font-weight: 600; white-space: nowrap; }
td.n, th.n { text-align: right; font-variant-numeric: tabular-nums; white-space: nowrap; }
tr:last-child td { border-bottom: none; }
.badge { display: inline-block; padding: 1px 7px; border-radius: 10px; font-size: 12px; font-weight: 600; white-space: nowrap; }
.lv-emergency { color: var(--emer); background: var(--emer-bg); }
.lv-critical { color: var(--crit); background: var(--crit-bg); }
.lv-high { color: var(--high); background: var(--high-bg); }
.lv-medium { color: var(--med); background: var(--med-bg); }
.lv-low { color: var(--low); background: var(--low-bg); }
.lv-informational, .lv-other { color: var(--info); background: var(--info-bg); }
.st-Completed { color: var(--ok); background: var(--ok-bg); }
.st-CompletedWithErrors { color: var(--high); background: var(--high-bg); }
.st-Failed { color: var(--crit); background: var(--crit-bg); }
.st-Pending, .st-Running, .st-Skipped, .st-other { color: var(--info); background: var(--info-bg); }
.tag { color: var(--muted); font-size: 12px; margin-left: 4px; }
.notes { color: var(--muted); font-size: 12px; max-width: 420px; overflow-wrap: anywhere; }
.err { color: var(--crit); }
.dim { color: var(--muted); }
.warnbox { border-left: 4px solid var(--high); background: var(--high-bg); padding: 8px 12px; border-radius: 4px; margin: 10px 0; }
a { color: var(--link); }
.links a { margin-right: 8px; white-space: nowrap; }
footer { color: var(--muted); font-size: 12px; margin-top: 28px; }
'@

function ConvertTo-HtmlText {
    <#
    .SYNOPSIS
        Encodes text for HTML element content and quoted attribute values.
    .DESCRIPTION
        Replaces &, <, >, " and '. Written out rather than using
        WebUtility.HtmlEncode so the result is identical on Windows
        PowerShell 5.1 and PowerShell 7. Every value written into triage_dashboard.html
        goes through this, since rule titles and computer names come from
        the evidence and could be crafted to inject markup.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [object]$Text
    )

    if ($null -eq $Text) {
        return ''
    }
    $s = [string]$Text
    $s = $s.Replace('&', '&amp;')
    $s = $s.Replace('<', '&lt;')
    $s = $s.Replace('>', '&gt;')
    $s = $s.Replace('"', '&quot;')
    $s = $s.Replace("'", '&#39;')
    return $s
}

function ConvertTo-RelativeHref {
    # URL-encodes each path segment, joins them with /, then HTML-encodes
    # the result for use in a quoted href attribute.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string[]]$Segment
    )

    $encoded = ($Segment | ForEach-Object { [System.Uri]::EscapeDataString($_) }) -join '/'
    return (ConvertTo-HtmlText -Text $encoded)
}

function Get-LevelBadge {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Level
    )

    $class = 'other'
    if ($script:KnownLevels -contains $Level) {
        $class = $Level
    }
    return "<span class=`"badge lv-$class`">$(ConvertTo-HtmlText -Text $Level)</span>"
}

function Get-StatusBadge {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Status
    )

    $class = 'other'
    if ($script:KnownStatuses -contains $Status) {
        $class = $Status
    }
    return "<span class=`"badge st-$class`">$(ConvertTo-HtmlText -Text $Status)</span>"
}

function ConvertTo-CountCell {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return '<td class="n dim"></td>'
    }
    return "<td class=`"n`">$(ConvertTo-HtmlText -Text $Value)</td>"
}

function ConvertTo-RelativeNote {
    # Shows paths under OutputRoot relative to it, so a shared dashboard
    # does not carry the case's full folder layout in its notes.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text,

        [Parameter(Mandatory)]
        [string]$OutputRoot
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return $Text
    }
    $root = $OutputRoot.TrimEnd('\', '/')
    $pattern = [regex]::Escape($root) + '[\\/]?'
    return [regex]::Replace($Text, $pattern, '', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
}

function New-DashboardHtml {
    <#
    .SYNOPSIS
        Builds triage_dashboard.html from the rollup data.
    .DESCRIPTION
        Order: summary leading with the top emergency, critical and high
        rules, the full rule table, the host table with links to each
        host's report, timeline and log, then run details. Every value is
        HTML-encoded. Links are relative paths under OutputRoot and only
        appear when the file exists. Severity tiles with a count of zero are
        dimmed so the levels that fired stand out. Each distinct note on a
        host row is shown once, errors first.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds a string only.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Data
    )

    $hosts = @($Data.Hosts)
    $rules = @($Data.Rules)
    $sb = New-Object System.Text.StringBuilder
    $e = { param($v) ConvertTo-HtmlText -Text $v }

    $sum = { param($prop) $t = 0; foreach ($h in $hosts) { if ($null -ne $h.$prop) { $t += [int]$h.$prop } }; $t }
    $withAny = { param($prop) @($hosts | Where-Object { $null -ne $_.$prop -and [int]$_.$prop -gt 0 }).Count }
    $emerTotal = & $sum 'Emergency'
    $critTotal = & $sum 'Critical'
    $highTotal = & $sum 'High'
    $medTotal = & $sum 'Medium'
    $lowTotal = & $sum 'Low'
    $hostsEmer = & $withAny 'Emergency'
    $hostsCrit = & $withAny 'Critical'
    $hostsHigh = & $withAny 'High'
    $failed = @($hosts | Where-Object { $_.Status -eq 'Failed' }).Count
    $withErrors = @($hosts | Where-Object { $_.Status -eq 'CompletedWithErrors' }).Count
    $notRun = @($hosts | Where-Object { $_.Status -eq 'Pending' -or $_.Status -eq 'Running' }).Count
    $unknown = @($hosts | Where-Object { $_.HostUnknown }).Count

    [void]$sb.AppendLine('<!DOCTYPE html>')
    [void]$sb.AppendLine('<html lang="en">')
    [void]$sb.AppendLine('<head>')
    [void]$sb.AppendLine('<meta charset="utf-8">')
    [void]$sb.AppendLine("<meta http-equiv=`"Content-Security-Policy`" content=`"$(& $e $script:DashboardCsp)`">")
    [void]$sb.AppendLine('<meta name="viewport" content="width=device-width, initial-scale=1">')
    [void]$sb.AppendLine('<meta name="referrer" content="no-referrer">')
    [void]$sb.AppendLine('<title>Hayabusa triage</title>')
    [void]$sb.AppendLine("<style>$script:DashboardCss</style>")
    [void]$sb.AppendLine('</head>')
    [void]$sb.AppendLine('<body><main>')

    # Summary
    [void]$sb.AppendLine('<h1>Hayabusa triage</h1>')
    [void]$sb.AppendLine("<p class=`"meta`">Built $(& $e $Data.BuiltUtc) from $(& $e $hosts.Count) collection(s). $(& $e $rules.Count) rule(s) fired.</p>")
    # A zero tile is dimmed, so the eye goes to the levels that fired.
    $tile = {
        param($Class, $Count, $Label)
        if ($Count -eq 0) {
            $Class = "$Class zero"
        }
        "<div class=`"tile $Class`"><div class=`"n`">$(& $e $Count)</div><div class=`"l`">$Label</div></div>"
    }
    [void]$sb.AppendLine('<div class="tiles">')
    [void]$sb.AppendLine((& $tile 'emer' $emerTotal "emergency detections on $(& $e $hostsEmer) host(s)"))
    [void]$sb.AppendLine((& $tile 'crit' $critTotal "critical detections on $(& $e $hostsCrit) host(s)"))
    [void]$sb.AppendLine((& $tile 'high' $highTotal "high detections on $(& $e $hostsHigh) host(s)"))
    [void]$sb.AppendLine((& $tile 'med' $medTotal 'medium detections'))
    [void]$sb.AppendLine((& $tile 'low' $lowTotal 'low detections'))
    [void]$sb.AppendLine('</div>')

    $topLevels = @('emergency', 'critical', 'high')
    $top = @($rules | Where-Object { $topLevels -contains $_.Level } | Select-Object -First $script:SummaryTopRules)
    [void]$sb.AppendLine('<div class="panel"><h3>Top emergency, critical and high rules</h3>')
    if ($top.Count -eq 0) {
        [void]$sb.AppendLine('<p class="dim">No emergency, critical or high rules fired.</p>')
    }
    else {
        [void]$sb.AppendLine('<ol>')
        foreach ($r in $top) {
            [void]$sb.AppendLine("<li>$(Get-LevelBadge -Level $r.Level) $(& $e $r.RuleTitle) <span class=`"dim`">on $(& $e $r.HostsAffected) host(s), $(& $e $r.TotalHits) hit(s)</span></li>")
        }
        [void]$sb.AppendLine('</ol>')
    }
    [void]$sb.AppendLine('</div>')

    [void]$sb.AppendLine('<div class="health">')
    [void]$sb.AppendLine("<span><b>$(& $e $hosts.Count)</b> hosts</span>")
    [void]$sb.AppendLine("<span><b>$(& $e $failed)</b> Failed</span>")
    [void]$sb.AppendLine("<span><b>$(& $e $withErrors)</b> CompletedWithErrors</span>")
    [void]$sb.AppendLine("<span><b>$(& $e $notRun)</b> not yet run</span>")
    [void]$sb.AppendLine("<span><b>$(& $e $unknown)</b> host name unknown</span>")
    [void]$sb.AppendLine('</div>')

    if ($Data.MixedFloors) {
        [void]$sb.AppendLine("<div class=`"warnbox`">Rows come from runs with different severity floors ($(& $e ($Data.Floors -join ', '))). A host with no detections is only clean at the floor its run used. See Run details.</div>")
    }

    # Rules
    [void]$sb.AppendLine('<h2 id="rules">Rules fired</h2>')
    if ($rules.Count -eq 0) {
        [void]$sb.AppendLine('<p class="dim">No detections at the severity floor.</p>')
    }
    else {
        [void]$sb.AppendLine('<div class="wrap"><table>')
        [void]$sb.AppendLine('<thead><tr><th>Level</th><th>Rule</th><th class="n">Hosts</th><th class="n">Hits</th><th>Seen on</th></tr></thead><tbody>')
        foreach ($r in $rules) {
            $seen = @($r.Collections | Select-Object -First $script:RuleCollectionsShown | ForEach-Object { & $e $_ }) -join ', '
            $more = @($r.Collections).Count - $script:RuleCollectionsShown
            if ($more -gt 0) {
                $seen += " <span class=`"dim`">and $(& $e $more) more</span>"
            }
            [void]$sb.AppendLine("<tr><td>$(Get-LevelBadge -Level $r.Level)</td><td>$(& $e $r.RuleTitle)</td><td class=`"n`">$(& $e $r.HostsAffected)</td><td class=`"n`">$(& $e $r.TotalHits)</td><td>$seen</td></tr>")
        }
        [void]$sb.AppendLine('</tbody></table></div>')
    }

    # Hosts
    [void]$sb.AppendLine('<h2 id="hosts">Hosts</h2>')
    if ($hosts.Count -eq 0) {
        [void]$sb.AppendLine('<p class="dim">No collections in the manifest.</p>')
    }
    else {
        [void]$sb.AppendLine('<div class="wrap"><table>')
        [void]$sb.AppendLine('<thead><tr><th>Host</th><th>Collection</th><th>Status</th><th class="n">Emer</th><th class="n">Crit</th><th class="n">High</th><th class="n">Med</th><th class="n">Low</th><th class="n">Total</th><th>Top rule</th><th>Open</th><th>Notes</th></tr></thead><tbody>')
        foreach ($h in $hosts) {
            if ($h.HostUnknown) {
                $hostCell = "$(& $e $h.Collection)<span class=`"tag`">host unknown</span>"
            }
            elseif ($h.Multiple -and $h.Host -eq '[multiple]') {
                # Names could not be read from the CSV.
                $hostCell = "<span class=`"tag`">$(& $e $h.Host)</span>"
            }
            elseif ($h.Multiple) {
                $hostCell = "$(& $e $h.Host)<span class=`"tag`">multiple</span>"
            }
            else {
                $hostCell = & $e $h.Host
            }

            $topCell = ''
            if ($null -ne $h.TopRule) {
                $topCell = "$(Get-LevelBadge -Level $h.TopRuleLevel) $(& $e $h.TopRule)"
            }

            $linkParts = foreach ($name in $h.Links.Keys) {
                "<a href=`"$(ConvertTo-RelativeHref -Segment $h.Links[$name])`">$(& $e $name)</a>"
            }
            $linkCell = @($linkParts) -join ''

            # The manifest joins several messages with " | ". Each distinct
            # one is shown once, errors first, so a message stored as both
            # a warning and an error by an earlier run appears only once.
            $notes = New-Object System.Collections.Generic.List[string]
            $seen = New-Object System.Collections.Generic.List[string]
            $rel = { param($t) ConvertTo-RelativeNote -Text $t -OutputRoot $Data.OutputRoot }
            $noteSets = @(
                @('err', '', [string]$h.Error),
                @('err', 'Rollup could not read the CSV: ', [string]$h.ReadError),
                @('', '', [string]$h.Warning)
            )
            foreach ($set in $noteSets) {
                foreach ($part in ($set[2] -split ' \| ')) {
                    $text = $part.Trim()
                    if ($text.Length -eq 0 -or $seen.Contains($text)) {
                        continue
                    }
                    $seen.Add($text)
                    $noteHtml = & $e "$($set[1])$(& $rel $text)"
                    if ($set[0] -eq 'err') {
                        $noteHtml = "<span class=`"err`">$noteHtml</span>"
                    }
                    $notes.Add($noteHtml)
                }
            }
            $source = ''
            if ($h.Source -ne $h.Collection) {
                $source = "<div class=`"dim`">$(& $e $h.Source)</div>"
            }

            [void]$sb.Append("<tr><td>$hostCell</td><td>$(& $e $h.Collection)$source</td><td>$(Get-StatusBadge -Status $h.Status)</td>")
            [void]$sb.Append((ConvertTo-CountCell -Value $h.Emergency))
            [void]$sb.Append((ConvertTo-CountCell -Value $h.Critical))
            [void]$sb.Append((ConvertTo-CountCell -Value $h.High))
            [void]$sb.Append((ConvertTo-CountCell -Value $h.Medium))
            [void]$sb.Append((ConvertTo-CountCell -Value $h.Low))
            [void]$sb.Append((ConvertTo-CountCell -Value $h.Total))
            [void]$sb.AppendLine("<td>$topCell</td><td class=`"links`">$linkCell</td><td class=`"notes`">$($notes.ToArray() -join '<br>')</td></tr>")
        }
        [void]$sb.AppendLine('</tbody></table></div>')
        [void]$sb.AppendLine('<p class="dim">Blank counts mean no readable results for that collection. "host unknown" means no detections named a computer: a clean host at the floor, or one that has not produced results. HostsAffected counts collections, so a collection tagged multiple counts once however many computers it holds.</p>')
    }

    # Provenance
    [void]$sb.AppendLine('<h2 id="provenance">Run details</h2>')
    $prov = @($Data.Provenance)
    if ($prov.Count -eq 0) {
        [void]$sb.AppendLine('<p class="dim">No runs referenced by the manifest.</p>')
    }
    else {
        [void]$sb.AppendLine('<div class="wrap"><table>')
        [void]$sb.AppendLine('<thead><tr><th>RunId</th><th>Started (UTC)</th><th>Floor</th><th>Profile</th><th>Hayabusa</th><th>Rules</th><th class="n">Rows</th></tr></thead><tbody>')
        foreach ($p in $prov) {
            if ($p.Found) {
                [void]$sb.AppendLine("<tr><td>$(& $e $p.RunId)</td><td>$(& $e $p.StartedUtc)</td><td>$(& $e $p.Floor)</td><td>$(& $e $p.Profile)</td><td>$(& $e $p.Hayabusa)</td><td>$(& $e $p.RulesVersion)</td><td class=`"n`">$(& $e $p.Rows)</td></tr>")
            }
            else {
                [void]$sb.AppendLine("<tr><td>$(& $e $p.RunId)</td><td colspan=`"5`" class=`"dim`">run-meta not found in _runs</td><td class=`"n`">$(& $e $p.Rows)</td></tr>")
            }
        }
        [void]$sb.AppendLine('</tbody></table></div>')
    }

    [void]$sb.AppendLine('<footer>Files beside triage_dashboard.html: triage_rules.csv, triage_hosts.csv, run_manifest.csv, _runs, and one folder per collection.</footer>')
    [void]$sb.AppendLine('</main></body>')
    [void]$sb.AppendLine('</html>')
    return $sb.ToString()
}
