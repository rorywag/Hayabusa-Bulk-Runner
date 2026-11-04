# Usage

Reference for Hayabusa-Bulk-Runner. For what the tool is, how to get it and a first run, see the [README](../README.md).

## Parameters

The command line takes InputRoot, OutputRoot, HayabusaPath, MinLevel, Threads, Force, KeepArtifacts, ConfigPath, IdentityOnly and PassThru. Everything else goes in the [engagement config](#engagement-config): ExactLevel, IncludeTags or ExcludeTags, a time window, the output profile, a custom rules path and the ZIP limits. MinLevel is the only setting that can go in both, and the command line wins. The tool exposes this fixed set on purpose and leaves everything else at Hayabusa's defaults.

| Parameter | What it does |
|---|---|
| `-InputRoot` | Parent folder holding one entry per host |
| `-OutputRoot` | Where everything is written. Created if missing. Must not be inside InputRoot, or hold it |
| `-HayabusaPath` | Full path to `hayabusa.exe` itself, outside InputRoot and OutputRoot and not on a share. See [Where the tools can be](#where-the-tools-can-be) |
| `-MinLevel` | Severity floor: informational, low, medium, high, critical or emergency. Default medium |
| `-Threads` | Passed to Hayabusa. Leave it out to let Hayabusa decide |
| `-Force` | Rerun hosts that already finished |
| `-KeepArtifacts` | Keep extracted ZIPs and differencing disks after each host, for debugging |
| `-ConfigPath` | Engagement config file, see below |
| `-IdentityOnly` | Read [host identity](#identity-only) with RECmd and nothing else. Needs `RECmdPath` in the config, and takes no `-HayabusaPath` |
| `-PassThru` | Return an object describing the run, for scripting. Without it nothing is returned. See [Quiet mode and -PassThru](#quiet-mode-and--passthru) |
| `-Help` | Print a usage summary and exit. `-h` is the same |

`-MinLevel` takes any of the six levels, informational, low, medium (the default), high, critical or emergency, and means that level and up.

A rerun skips hosts that already finished, whatever the settings. On a case that's already been run, add `-Force` so a new floor or config applies to those hosts too.

### Where the tools can be

Hayabusa and RECmd run with the analyst's rights against every host, and Hayabusa loads its rules from wherever RulesPath points, so before anything is written the run refuses a tool or the rules folder that's inside InputRoot or OutputRoot, where the evidence could have put it, or given as a UNC path to a network share. `-HayabusaPath` has to name Hayabusa's own `.exe`, so a `.cmd` or `.bat` wrapper is refused, and run-meta records the SHA-256 of both executables beside their paths.

Add `-Verbose` for more detail as the run goes, and see [Reading the console](#reading-the-console) for what each line means. `-InformationAction SilentlyContinue` hides the console lines and leaves only the warnings, and the [run log](#the-run-log) is still written. `.\Invoke-BulkHayabusa.ps1 -Help`, or `-h`, prints a short usage summary, PowerShell's own `-?` shows the syntax, and `Get-Help .\Invoke-BulkHayabusa.ps1 -Full` lists every parameter.

### Examples

Each of these is a complete command. Copy one and change the paths:

```powershell
# Default triage run, floor at medium. Start here on a new case.
.\Invoke-BulkHayabusa.ps1 -InputRoot D:\Cases\Case01\KAPE -OutputRoot D:\Cases\Case01\Output -HayabusaPath D:\Tools\hayabusa\hayabusa.exe

# Narrow to high-confidence detections only, when medium is too noisy.
.\Invoke-BulkHayabusa.ps1 -InputRoot D:\Cases\Case01\KAPE -OutputRoot D:\Cases\Case01\Output -HayabusaPath D:\Tools\hayabusa\hayabusa.exe -MinLevel high

# Cap Hayabusa at two threads, on a box that's busy with other work.
.\Invoke-BulkHayabusa.ps1 -InputRoot D:\Cases\Case01\KAPE -OutputRoot D:\Cases\Case01\Output -HayabusaPath D:\Tools\hayabusa\hayabusa.exe -Threads 2

# Rerun every host, finished ones included, after fixing something such as the rules.
.\Invoke-BulkHayabusa.ps1 -InputRoot D:\Cases\Case01\KAPE -OutputRoot D:\Cases\Case01\Output -HayabusaPath D:\Tools\hayabusa\hayabusa.exe -Force

# Keep extracted ZIPs and differencing disks, to debug a host that failed.
.\Invoke-BulkHayabusa.ps1 -InputRoot D:\Cases\Case01\KAPE -OutputRoot D:\Cases\Case01\Output -HayabusaPath D:\Tools\hayabusa\hayabusa.exe -KeepArtifacts

# Engagement settings from a config: ExactLevel, tag filters, a time window and the output profile live there.
.\Invoke-BulkHayabusa.ps1 -InputRoot D:\Cases\Case01\KAPE -OutputRoot D:\Cases\Case01\Output -HayabusaPath D:\Tools\hayabusa\hayabusa.exe -ConfigPath D:\Cases\Case01\engagement.psd1

# Who, what and where only: host identity from the registry, no Hayabusa. The config sets RECmdPath.
.\Invoke-BulkHayabusa.ps1 -InputRoot D:\Cases\Case01\KAPE -OutputRoot D:\Cases\Case01\Output -ConfigPath D:\Cases\Case01\engagement.psd1 -IdentityOnly
```

## Reading the console

A run starts with a short header giving the version and the mode, and where it reads from and writes to, with the collections counted by type. A full run also shows the Hayabusa version and rules it uses, and RECmd's path when host identity is read. A long path is shortened in the middle, so its file name always shows.

`Before the run` only appears when there's something to say before the first host starts, such as a ZIP the tool can't extract or a Hayabusa version it wasn't tested with. A line starting with `!` is a warning, and if the run stops on an error before it gets that far, the warnings it had so far are written as ordinary warnings just ahead of the error, so none are lost. When the run holds disk images it also says how many will be hashed, since each one is read in full twice.

Each host then gets a block of its own. Its header line is written as soon as it starts, with its type and, for an image, its size, so whatever happens to the host lands under its name:

```
[3/5] 2026-10-11T072226_RW-Test-VHD  VHD, 4.1 GB
      Hash before mount     done                           38s
      Mount                 done                            4s
      Read identity         Complete, RW-LENOVO            12s
      Hayabusa              12 detections                2m10s
      Teardown              done                            3s
      Hash after teardown   unchanged                      37s
      Completed in 3m44s
```

Each step gets a line when it finishes, with its result and how long it took, and a step that fails says `failed` with a short reason. A warning about the host shows inside its block, above the closing line, which gives the host's status and its total time. A folder has nothing to extract or mount, so a block only shows the steps that host really had. A host that's already finished gets a single line saying it was skipped.

While a step runs, PowerShell's progress bars show which host and step the run is on. A hash shows how much of the image it has read, and Hayabusa shows how long it's been running and the last line it printed. `$ProgressPreference = 'SilentlyContinue'` turns the bars off.

The run ends with a summary table, one row per collection in the run, then the counts with the total time, and where to find each dashboard, the combined timeline and the run log. A long collection name is shortened in the middle to keep the table inside the window.

The layout fits the window's width, or 120 columns when the output goes to a file or a pipe, and setting the `COLUMNS` environment variable to a whole number between 60 and 500 lets you pick the width yourself.

Status words are coloured:

| Colour | Status |
|---|---|
| Green | Complete, Completed |
| Yellow | Partial, CompletedWithErrors, NoRegistryHives |
| Red | Failed, and a hash that changed |
| Dark grey | skipped |

Colour is off when the `NO_COLOR` environment variable is set, or when the output is redirected. With colour on, a coloured line reaches `-InformationVariable` in pieces, so set `NO_COLOR` or read the run log when you need whole lines.

Computer names, user names, network names and Hayabusa's own output all come from the evidence, so whoever built that evidence chose them, and a crafted hostname could carry escape codes that move the cursor or rewrite what's already on screen. Every value goes through one sanitiser before it reaches the console, a progress bar or the run log. It strips escape sequences and every other control character, along with every Unicode format character, which takes out the overrides that reverse the direction of text and the invisible ones like a zero-width space hidden inside a computer name, and it turns line breaks into spaces and cuts anything very long short.

## The run log

Every run writes the same lines to `_runs\run_<time>_<RunId>.log`, with the same time and RunId as its run-meta, so the two sit side by side. Each line starts with the time in UTC, and the warnings go in too, each starting with `WARNING`. It's plain UTF-8 text with no colour or progress bars, written line by line so you can follow it with `Get-Content -Wait`, even in quiet mode. An `-IdentityOnly` run writes one as well, under a RunId of its own, though it has no run-meta. If the log can't be written, for example because `_runs` is a link, the run warns once and carries on without it.

## Quiet mode and -PassThru

`-InformationAction SilentlyContinue` hides every console line and leaves only the warnings, and the run log is still written in full.

The script returns nothing unless you add `-PassThru`, so a run ends with its summary and not a dump of an object. With `-PassThru` it returns the same object it always used to, now with `RunLogPath` added, for scripting against:

```powershell
$run = .\Invoke-BulkHayabusa.ps1 -InputRoot D:\Cases\Case01\KAPE -OutputRoot D:\Cases\Case01\Output -HayabusaPath D:\Tools\hayabusa\hayabusa.exe -InformationAction SilentlyContinue -PassThru
if ($run.Summary.Failed -gt 0) { Get-Content -LiteralPath $run.RunLogPath }
```

`Get-Help .\Invoke-BulkHayabusa.ps1 -Full` lists what it holds.

## Lay out each case the same way

Give each case one folder, and keep its OutputRoot in the same place for the life of the case:

```
D:\Cases\Case01\
  KAPE\              InputRoot: one entry per host
  Output\            OutputRoot: every run for this case goes here
  engagement.psd1    the case's config, if it has one
```

Always rerun into the same OutputRoot. Its manifest is what a rerun resumes from, as [Rerunning and resuming](#rerunning-and-resuming) explains, and pointing a rerun at a new folder starts the whole case from scratch.

## Input model

Each top-level entry in InputRoot is one collection, normally one host:

- a folder: KAPE's loose output, used as is
- a `.vhdx` or `.vhd`: a KAPE container image, mounted for the run
- a `.zip`: extracted to a working folder. If it holds one disk image, that image is mounted. A ZIP holding two or more disk images is warned about at the start and fails. Otherwise the extracted folder is used as loose output

Hayabusa recurses, so it doesn't matter how deep the logs are inside each entry.

Everything else is skipped: KAPE's own `_ConsoleLog.txt`, `_CopyLog.csv` and `_SkipLog.csv` quietly, any other loose file with a warning. Links and junctions are skipped too, since they could point outside InputRoot, and so are `$RECYCLE.BIN` and `System Volume Information` when InputRoot is a drive root.

Each entry gets a collection name, used for its output folder: the entry name without the container extension, with anything outside `A-Z a-z 0-9 . _ -` replaced by `_`. Two entries that end up with the same name, say `HOST01` and `host01.zip`, stop the run before anything is written, and you rename one.

The collection name isn't the host name: KAPE often names loose output after the drive, so the folder is just `C`. The Host column comes from the `Computer` field in Hayabusa's results instead. A collection with more than one `Computer` value is covered under [Outputs](#outputs). A host with no detections at the floor has nothing to take a name from: `triage_hosts.csv` shows it as `[unknown]`, the dashboard tags it "host unknown", and the manifest leaves its Host blank.

Things that trip people up, and get a warning:

- InputRoot pointed at one host's volume root, so Windows, Users and the rest would each become a "host"
- a disk image sitting inside a loose folder. It won't be mounted there. Put the image directly in InputRoot
- a ZIP holding a disk image and loose event logs as well. The image is processed and the loose logs are skipped
- a ZIP inside a ZIP. Only one level is opened

## ZIPs: extract them first if the tool says so

The ZIP reader in .NET only handles the two common compression methods, Stored and Deflate, and no encryption. A ZIP made with Deflate64, BZip2, LZMA, Zstandard, XZ or PPMd, or with a password, can't be extracted by this tool.

Every ZIP is checked when InputRoot is read, before anything runs. Each one that can't be extracted gets one short warning at the start of the run, followed by what to do:

```
WARNING: HOST07.zip can't be extracted by this tool (unsupported compression or encryption).
  To include them, extract each one yourself, put the extracted folder in InputRoot, and rerun. Hosts already done are skipped.
```

The host is marked Failed. The manifest and dashboard carry the same one-line message, and the technical detail, such as which entry uses which compression method, goes in that host's `HOST07_hayabusa.log`, linked from the dashboard.

The fix is to extract the ZIP with 7-Zip or similar, put the extracted folder in InputRoot in place of the ZIP, and rerun. If the ZIP held a disk image, put the `.vhdx` or `.vhd` itself directly in InputRoot, not the folder around it, so it gets mounted.

If the check can't make sense of a ZIP at all, or an entry has a name Windows can't hold, it's treated the same way. That covers a character no Windows file name can use, such as `|`, `?`, `*` or a control character, a colon, which Windows would take as an alternate data stream, a folder or file name ending in a dot or space, and a reserved device name such as `CON` or `aux`. These are the same rules extraction applies, so such a ZIP is listed at the start, marked Failed and never half-extracted. A name that could write outside the extraction folder, such as one with `..` in it, is refused at extraction as an unsafe archive. A ZIP that can't be read never counts as readable.

ZIPs that can be extracted are still treated as hostile. Before anything is written, every entry name is checked for path traversal and names Windows can't hold, and the declared size and compression ratio are checked against limits. The defaults are 100 GB of uncompressed content and a 250:1 ratio of extracted size to ZIP size. Both are set in the engagement config, as `ZipMaxUncompressedGB` and `ZipMaxRatio`. Extraction counts the bytes actually written, and stops if an entry writes more than it claimed. Each extracted file must also come to exactly the size the ZIP recorded and match the CRC-32 checksum the ZIP stored for it. If it doesn't, the ZIP may be damaged, for example by a bad copy, so that host is marked Failed with a message naming the entry, and the rest of the run carries on. Copy the ZIP again from the original and rerun. It also checks there's room for the extract on the OutputRoot volume, and warns if it can't tell, as on some network shares.

Deep paths are fine. KAPE output can run past Windows' 260-character path limit, for example the crash reports under `C\ProgramData\Microsoft\Windows\WER\ReportArchive`. The tool writes, lists and removes the extract through Windows' extended-length paths, so those extract like anything else. If a path still can't be created, that collection fails with a message saying so. For a long path the fix is a shorter OutputRoot, such as `D:\Out`, or extracting the ZIP yourself nearer the drive root. A single name over 255 characters can't be created anywhere on Windows, so extract that ZIP yourself with a tool that can shorten or skip the entry, then apply the same fix as above.

## Disk images and elevation

Mounting a disk image needs an elevated session. If any collection is a disk image, or a ZIP holding one, and the session isn't elevated, the run stops at the start before anything is written and says which collections need it. Rerun from an Administrator PowerShell prompt. A run with only folders and plain ZIPs doesn't need elevation.

The differencing disk is created with diskpart, which can't reliably read non-ASCII characters in a path. A disk image whose path, or whose OutputRoot, holds any is refused with a message saying so, before diskpart runs.

For how the mount keeps the evidence read-only, see [Evidence integrity](../README.md#evidence-integrity) in the README.

Before an image is hashed or mounted, the tool reads its own format headers and refuses a differencing disk, a VHD or VHDX that names a parent image, since attaching it would make Windows open that parent wherever it points, on this machine or on a share. Merge such an image into a standalone one and rerun. An image whose headers don't parse cleanly, or whose content doesn't match its extension, is refused the same way, and either refusal fails that host only, with nothing mounted or written.

Each disk image is hashed with SHA-256 before it's mounted and again after teardown, to show it wasn't changed. Each hash reads the whole image, so expect a pause before and after a large one. The run says how many images it will hash before it starts, each host's header gives its image's size, and a progress bar shows how much of the image each hash has read. A ZIP holding a disk image is hashed as the extracted image. Loose folders aren't hashed.

### Less common image layouts

KAPE writes its VHD and VHDX containers with one volume, and Velociraptor offline collectors produce ZIPs, so neither reaches the paths below. They matter for a full-disk image added as a VHD or VHDX, such as a cloud VM's OS disk or a Disk2vhd capture, and they're covered by the unit tests but haven't yet been run against a real image of that kind.

- When an image has several volumes, the tool uses the one holding `Windows\System32\winevt\Logs` and refuses the image if none or more than one does, rather than guess. A `Windows` folder that's a link doesn't count, so a link can't make it pick the wrong partition.
- A full-disk image, with `Windows\System32\winevt\Logs` at the volume root, is read from that folder only, and its Mount step says `winevt\Logs only`. A real Windows volume is full of junctions whose targets would resolve against this machine's own drives, and Hayabusa follows links as it walks a folder, so it isn't given the whole volume. Event logs kept anywhere else on such an image aren't read. Every other layout, a KAPE container with its logs one folder down among them, is still read whole.
- When Windows gives the mounted volume no drive letter, the tool mounts it at `_mnt\<collection>` under OutputRoot and points Hayabusa at that folder instead, then removes it at teardown.

## Outputs

Everything lands under OutputRoot:

| Path | What it is |
|---|---|
| `<Collection>\<Collection>_report.html` | Hayabusa's own alert summary for that host |
| `<Collection>\<Collection>_timeline.csv` | Hayabusa's CSV timeline, UTC |
| `<Collection>\<Collection>_hayabusa.log` | The exact arguments, Hayabusa's output and its exit code |
| `run_manifest.csv` | One row per collection with its latest status, counts, warnings and errors |
| `_runs\run_<time>_<RunId>.log` | The run's console lines as plain text, timestamped in UTC, warnings included. See [The run log](#the-run-log) |
| `_runs\run_meta_<time>_<RunId>.json` | What each run used: Hayabusa and rules versions, settings and where each came from, config hash, ZIP limits, collections, summary, and each disk image's SHA-256 before and after its host. See [Run-meta](#run-meta) |
| `triage_hosts.csv` | One row per collection, worst first, with counts by level and the top rule |
| `triage_rules.csv` | One row per rule and level, by severity, then how many hosts it fired on |
| `triage_dashboard.html` | The dashboard |
| `combined_timeline.csv` | Every included host's Hayabusa timeline in one file, in time order, with the same columns. See [The combined timeline](#the-combined-timeline) |
| `<Collection>\<Collection>_identity.json` | That host's identity from its registry hives, when `RECmdPath` is set. See [Host identity from registry hives](#host-identity-from-registry-hives) |
| `identity_dashboard.html` | The host identity dashboard, when `RECmdPath` is set |

The dashboard is rule-first: a summary of totals by severity and the top rules, then the rule table, then the host table with links to each host's report, timeline and log, then where each row came from. Counts, report and timeline are only shown for a Completed or CompletedWithErrors host. A Failed host's files may be left from an earlier run, so it shows only its error and its log. If the rollup can't read a Completed or CompletedWithErrors host's timeline CSV, that host is shown as Unreadable instead, with the reason in its notes, and listed after the Failed hosts rather than among the clean ones. The manifest keeps the status the run recorded. It's one static file with no script and nothing loaded from the internet. Every value taken from the evidence is HTML-encoded, and a Content Security Policy blocks script outright, so a rule title like `<script>` just shows up as text. Paths are shown relative to OutputRoot, so the dashboard can be shared without giving away the case's folder layout.

A collection whose results name more than one computer is never given just one of them. The manifest marks its host `[multiple]` with a count of each name, and the dashboard and `triage_hosts.csv` show the names as its host, up to three of them and then `+N` for the rest, for example `WS01, WS01.corp.local`. The dashboard tags it "multiple" and its notes list every name with its count. A severity tile with nothing in it is greyed out, so the levels that did fire stand out.

Values a spreadsheet would treat as a formula, anything starting with `=`, `+`, `-`, `@`, a tab or a carriage return, get a leading `'` in the triage CSVs and the manifest, so opening them in Excel can't run anything. The tool strips that `'` again when it reads its own manifest back.

Severity follows Hayabusa's six levels: emergency, critical, high, medium, low, informational. One emergency outranks any number of criticals.

### The combined timeline

`combined_timeline.csv` covers the same collections as the dashboard, those the manifest has as Completed or CompletedWithErrors and whose timeline the rollup could read, so a Failed host's leftover CSV and an Unreadable one never go in. It's built with the rest of the rollup on every run and by `Invoke-HayabusaRollup.ps1`, so it always matches the per-host files, and an `-IdentityOnly` run doesn't build it. The dashboard links it with its row count, and the run's closing lines give its path, or a short reason it wasn't built.

A timeline that quietly covered 35 of 40 hosts would read as the whole case, so the run says which collections aren't in it. When any are left out, the closing line gives the coverage, as in `combined_timeline.csv, 1204331 rows from 35 of 40 collections`, and one warning names them grouped by why, so failed and unreadable hosts are told apart from ones still Pending or Running after an interrupted batch. The dashboard's line about it says the same, and run-meta records the count and the names with their reasons. When every collection is in it, the closing line gives just the path and rows.

Every row is copied exactly as Hayabusa wrote it, quoted fields included, even ones holding commas or line breaks, and the header is written once. The byte order mark and line endings stay as Hayabusa wrote them. Hayabusa runs with `-U` and `-s`, so each host's timeline is already in time order with every Timestamp in UTC as `yyyy-MM-dd HH:mm:ss.fff +00:00`, and the hosts are merged on that. Rows with the same Timestamp keep the collections' order in the manifest, then their order in the host's own file. It's streamed a row per host at a time, so a large run doesn't need more memory, but it does need free space about the size of all the timelines together, and without it the combined timeline is skipped with a warning. A host that detected nothing adds no rows.

It's all of the included hosts or none, since a timeline missing some would read as complete, so when it can't be trusted the run warns and leaves any earlier `combined_timeline.csv` as it was. Every host must have the same columns, which differ when hosts were run under different output profiles, and the warning names each set of columns with its hosts, so rerunning those hosts with `-Force` under one profile fixes it. A Timestamp that isn't in that form, or a host's file that isn't in time order, stops it too, and the warning names the host and the line. When two collections have rows for the same computer name, such as one machine collected twice, it's still written, and a warning names them, since those rows can't be told apart in it.

Open it in Timeline Explorer rather than Excel. It isn't formula-escaped like the triage CSVs, since it has to match Hayabusa's own per-host timelines exactly, and a large run can pass Excel's limit of 1,048,576 rows.

`CombinedTimeline = $false` in the engagement config skips it, for a run too large to keep a second copy of every timeline. An earlier `combined_timeline.csv` is left where it is then, and the dashboard says it's off. `Invoke-HayabusaRollup.ps1` doesn't read the config, so it always builds it.

### Working folders

Some folders under OutputRoot belong to the tool:

| Folder | What it's for |
|---|---|
| `_runs` | One provenance record and one run log per run. The record is written when the run starts, updated as each host finishes and completed when it ends, and neither is overwritten by a later run. Together they show what every row in the manifest was produced with |
| `_diff` | The differencing disks a disk image is mounted through. Each one is deleted when its host finishes, unless `-KeepArtifacts` is given, so after a clean run without it this folder is empty. Anything left in it means a teardown didn't finish, and the run's warnings will say which |
| `_work` | Extracted ZIPs, deleted after each host unless `-KeepArtifacts` is given |
| `_mnt` | Empty folders a volume is attached to when Windows gives it no drive letter |

### Run-meta

Each run writes `_runs\run_meta_<time>_<RunId>.json` when it starts, rewrites it as each host finishes, and completes it when it ends. Each rewrite goes through a temporary file swapped into place, so a run that's interrupted, even mid-write, keeps the record of every host it finished, image hashes included. `Summary` holds the counts so far, and `CompletedUtc` stays null until the run ends, so a record with no `CompletedUtc` is from a run that didn't finish. `RunLog` is the path of the run's log, null if it couldn't be written. `Rollup` records the rollup's files and counts. Its `CombinedTimeline` is the combined timeline's path, null when it wasn't built, and `CombinedTimelineError` says why. `CombinedTimelineRows` and `CombinedTimelineHosts` count its rows and the hosts in it. `CombinedTimelineCollections` counts the collections in the manifest, and `CombinedTimelineLeftOut` lists each one that isn't in it with its status as the reason. `Hayabusa` holds the SHA-256 of `hayabusa.exe` beside its path, and `RECmd` holds the same for `RECmd.exe` when host identity is read. `SchemaVersion` is 10. Under `Collections` it lists every collection the run found, with these fields:

| Field | What it holds |
|---|---|
| `Collection`, `Source`, `InputType` | The collection's name, its original name in InputRoot, and Loose, Zip, Vhd or Vhdx |
| `ImagePath` | The disk image that was hashed and mounted. For a ZIP holding an image, the extracted image under `_work` |
| `ImageSha256Before` | Its SHA-256 just before the differencing disk was created |
| `ImageSha256After` | Its SHA-256 after the differencing disk was dismounted and deleted |
| `ImageHashMatch` | `true` when the two match. `false` means the image changed during the run, and the host is Failed. Null when the second hash couldn't be taken, for example because the image couldn't be dismounted, which the host's Error says |

The four image fields are null for a loose folder, a ZIP with no disk image, and a collection skipped because an earlier run already finished it. With `-KeepArtifacts` the differencing disk is kept, and the second hash is taken once it's dismounted.

## Rerunning and resuming

The manifest is the record of what's been done. On a rerun, hosts that are Completed or CompletedWithErrors are skipped, and everything else is tried again: Failed, Pending, and anything left Running by a run that was interrupted. `-Force` reruns the lot. Rerunning a host removes its previous report and timeline just before Hayabusa runs, so what's recorded is always that run's own result. So after fixing a problem, say extracting a ZIP the tool couldn't, just run the same command again.

| Status | Meaning |
|---|---|
| Completed | Hayabusa exited cleanly and wrote a timeline. No detections is still Completed: Hayabusa writes an empty timeline when nothing matches |
| CompletedWithErrors | Hayabusa exited non-zero but still wrote a timeline. Counts are kept and the exit code is in Error |
| Failed | The input couldn't be prepared, Hayabusa wrote no timeline, the results couldn't be read, or teardown failed. Hayabusa can stop on an error and still exit 0 without writing a timeline, so that's Failed too, with Hayabusa's own error message in Error. A host whose disk image hashed differently after the run than before it is Failed whatever else happened, with an "Evidence integrity check failed" error first. After a teardown failure, the manifest keeps the counts from a finished Hayabusa run, but the dashboard and triage CSVs leave them out, as they do for every Failed host |
| Pending | Found but not run yet |
| Running | Being run, or the run was interrupted |

One host failing never stops the batch.

To rebuild the triage files, the dashboard and the combined timeline from an existing OutputRoot without rerunning anything, on any machine:

```powershell
.\Invoke-HayabusaRollup.ps1 -OutputRoot D:\Cases\Case01\Output
```

## Engagement config

Settings that should stay the same for a whole engagement go in a `.psd1` file passed with `-ConfigPath`. Copy [config/engagement.example.psd1](../config/engagement.example.psd1), which lists every setting with a comment, and edit it. It can set the rules path, `MinLevel` or `ExactLevel`, Sigma tag filters, a time window, the output profile and the ZIP limits, and `RECmdPath`, for [host identity from registry hives](#host-identity-from-registry-hives). Use `IncludeTags` or `ExcludeTags`, not both: Hayabusa 4.1.0 won't take the two together, so a config that sets both is refused before anything runs.

`CombinedTimeline = $false` turns off the [combined timeline](#the-combined-timeline), which is on unless it's set. It takes only `$true` or `$false`, so a quoted `'false'` or a `0` is refused before anything runs rather than read the wrong way.

`ExactLevel` sets a single level instead of a floor, for example only critical. MinLevel and ExactLevel are mutually exclusive: a config that sets both is refused, and `-MinLevel` on the command line replaces a config's ExactLevel.

No rule Hayabusa ships is emergency level. Emergency only appears when level-tuning raises a rule to it, so a `MinLevel` or `ExactLevel` of emergency loads no rules unless your rules have been raised that way. With no rules loaded, Hayabusa stops with "No rules were loaded" and exits 1, so every host is marked Failed. The tool warns at startup when either is set to emergency, then runs as asked, since your rules may have been raised. When reading results, both `emer` and `emergency` are accepted as the emergency level.

`Profile` sets the columns in each host's timeline CSV, and takes any of the output profiles your Hayabusa offers whose columns include `Level`, `Computer` and `RuleTitle`. The default is `standard`. The list is read from `config\profiles.yaml` beside `hayabusa.exe` when the run starts, so a profile a new release adds can be used without a change to this tool. The tool's counts and dashboard only read those three columns, so the profile changes the per-host detail and never the triage view. A profile Hayabusa doesn't offer is refused, and so is one whose columns don't include all three, naming the column it lacks. If `profiles.yaml` can't be found or read, the run warns and allows only `standard` and `verbose`. `Test-HayabusaCompatibility.ps1` lists which profiles a release offers and which of them the tool accepts.

It's read as data only, so it can't run code. Unknown keys are rejected, so a typo can't silently drop a filter. A setting given on the command line wins over the config, which wins over the default, and run-meta records which one each setting came from. Real configs are git-ignored when they're under `config\` or named `engagement*.psd1` or `*.local.*`, and only the example is tracked. A config with any other name elsewhere in the repo, such as `case01.psd1` at the root, would be tracked, so keep it outside the repo or name it to match.

## Checking a new Hayabusa release

The tool is tested against Hayabusa <!--tested-version-->4.3.1<!--/tested-version-->, and a run with any other version starts with a warning saying so. Before using a new release on a case, run the compatibility self-test against the new binary and its rules:

```powershell
.\Test-HayabusaCompatibility.ps1 -HayabusaPath D:\Tools\hayabusa-4.3.1\hayabusa.exe -RulesPath D:\Tools\hayabusa-4.3.1\rules
```

It builds a one-event Security log in a temporary folder and runs Hayabusa over it five times, with arguments built by the same code as a real run, so between them every flag the tool can pass is sent. It then prints PASS or FAIL for each check: the version was read, every flag was sent, Hayabusa read the sample's one event, each run was accepted and its filters applied, the CSV has the `Level`, `Computer` and `RuleTitle` columns, and every `Level` value maps to one of the six severities. It exits 0 when everything passes and 1 otherwise. It needs Windows but not an elevated session, and `-KeepArtifacts` keeps the temporary folder with each run's CSV, report and log.

The sample event is Security 1102, which Hayabusa's own "Log Cleared" rule detects at level high. A detection is needed because Hayabusa writes an empty CSV, with no header row, when it detects nothing, which leaves no columns to check. Three runs must drop that detection: `-e critical`, `--include-tag` with a tag the rule doesn't carry, and `--exclude-tag` with the tag it does. Each passes only when it detects nothing, so a release that accepts a filter but ignores it fails the check. They also show a clean run with no detections passes. The sample check reads the event count from Hayabusa's own summary in the baseline run's log. If Hayabusa read anything but the one event, the sample this check builds is at fault, not the release, and the FAIL line says so.

- **Green:** raise `$script:TestedHayabusaVersion` in `lib\Hayabusa.ps1`, then set the same version between each pair of tested-version markers: two in the README, under Status and Requirements, and one in this file, in this section. A test fails if any of them doesn't match. No code change is needed.
- **Red:** the FAIL line names the flag, column or level that changed, and for a refused flag, what Hayabusa said on stderr. Fix `New-HayabusaArgument` in `lib\Hayabusa.ps1`, or the result handling in `lib\Results.ps1`, then run the check again.

## Host identity from registry hives

The tool can read each collection's host identity from its registry hives: the computer name, domain, OS, time zone, local users and IP addressing. It's separate from how hosts are named in the manifest and the triage dashboard, which still comes from the `Computer` column of Hayabusa's output.

When the engagement config sets `RECmdPath`, a normal run reads each collection's identity while the collection is extracted or mounted for Hayabusa, so nothing is extracted or mounted twice, and writes `identity_dashboard.html` beside the triage dashboard at the end. Each host's progress line ends with its identity status. Without `RECmdPath`, nothing is read and a run is exactly as before. Reading identity never changes a host's status, its manifest row or run-meta: if it fails, the host's identity file says why and its triage results stand. A host a rerun skips as already finished keeps the identity it has, so run `-IdentityOnly` to read one it doesn't have yet.

It runs Eric Zimmerman's RECmd, tested with version <!--tested-recmd-version-->2026.5.0<!--/tested-recmd-version-->. The tool doesn't download it. Set `RECmdPath` in the engagement config to the full path of `RECmd.exe`, or to a path relative to the config file. It must be outside the evidence and the output and not on a share, as [Where the tools can be](#where-the-tools-can-be) says, and a `RECmd.exe` inside the collection being read is refused again as each host is read.

How it reads a collection:

- It looks for `Windows\System32\config`, in any case, at the collection root or up to six folders down. That covers the drive letter folder KAPE writes, such as `C\Windows`, and the deeper layout of a Velociraptor offline collection, `data\uploads\auto\C%3A\Windows`. The search stops at the first level that holds hives, so a shallow collection isn't searched any deeper. Only SYSTEM, SOFTWARE and SAM are read, never NTUSER.DAT. A collection with none of the three, such as one of event logs only, gives a `NoRegistryHives` result rather than an error.
- Each hive and its `.LOG`, `.LOG1` and `.LOG2` files are copied to a folder of their own under `OutputRoot\_work`, and RECmd runs on the copies, so the evidence is only ever read. RECmd applies the transaction logs in memory and doesn't change the files. The SHA-256 of each hive as collected is recorded. The work folder holds the copy of SAM and RECmd's full output for it, which includes password hints and the answers to security questions, so it's removed once the hives are read, whatever happens.
- A Velociraptor offline collector stores some files sparse: it takes the unused holes out and writes a small index beside the file, `<name>.idx`, saying where each piece of data really belongs. Read as stored, the hive's offsets are wrong after the first hole and RECmd can't parse it. So a hive or log with an index beside it is rebuilt at its original size in the work folder, its holes as zeros, before RECmd reads it. Each file is checked on its own, since a log can be sparse when its hive isn't. A file without an index, as KAPE collects them, is copied byte for byte. The recorded SHA-256 is still of the file as collected, so it matches the evidence, and `Rehydrated` and `RehydratedTransactionLogs` on each hive's entry say which files were rebuilt. The index comes from the collection, so it's checked first: a value that isn't a whole number from 0 up to the hive size limit, or an original size over that limit, is refused, and nothing is read past the end of the stored file. A hive or log whose index can't be used is copied as collected, with a note, the same way a dirty hive with no logs is still read.
- RECmd runs with `lib\HostIdentity.reb`, a short batch file made from entries in RECmd's standard batch files, so the columns it writes stay the same from run to run. Deleted keys and values are not recovered.
- A dirty hive with no transaction logs beside it is read again without them, with a note that changes Windows hadn't yet written to it are missing.
- The active control set comes from `SYSTEM\Select\Current`, rather than being taken to be ControlSet001.

What it records, saved as `OutputRoot\<Collection>\<Collection>_identity.json`:

- **Hostname:** the ComputerName value. The DNS domain is recorded beside it, so a full name can be formed later. Nothing is matched against the Computer names in Hayabusa's output.
- **Domain:** the DNS domain from Tcpip, and Winlogon's `CachePrimaryDomain` and `DefaultDomainName`. `Membership` is `Domain` when `CachePrimaryDomain` names a domain other than the computer itself. A workgroup's name is kept in the SECURITY hive, which isn't read, so a computer with no domain evidence is `NoDomainEvidence`.
- **OS:** the product name, edition, release, build, install date, registered owner and organization. Windows 11 keeps the Windows 10 product name in the registry, so a build of 22000 or later named Windows 10 gets a note.
- **Time zone:** the key name, the standard and daylight names, and the bias, both the standard one and the one in force when the hive was last written, in signed minutes and as a UTC offset.
- **Users:** each local account in SAM, with its name, full name, RID, the times it was created, last logged in and last changed its password, its login counts, groups, comment and account flags. Each is `Interactive`, a RID of 1000 or more on a normal user account that Windows or other software doesn't manage, `BuiltIn`, a RID under 1000 such as Administrator and Guest, or `System`, the rest, such as defaultuser0 and trust accounts, with the reason. The password hint and the security question answers are never read.
- **Interfaces:** every interface in the active control set, virtual ones such as Hyper-V, WSL and VPN adapters included. Each has its address, whether it's static or from DHCP, the mask, gateway, DNS servers and DHCP server, the network name from the DHCP network hint, and the lease times. They're ordered newest lease first. `LikelyActive` flags the newest leased interface with an address and a network name, so a Hyper-V or WSL adapter, which has no network name, isn't taken for the real connection. Only when no interface with an address has a network name is the newest leased one with an address flagged, or the only one with an address.

Every time is UTC, in the form `2026-01-01T00:00:00Z`, in a field whose name ends in `Utc`. RECmd gives each of the times read here in UTC, so none is local only. `Status` is `Complete` when all three hives were read, `Partial` when only some were, `Failed` when none were, and `NoRegistryHives` as above. `Notes` says what was missing and why. `SchemaVersion` is 2, and an identity file from version 1, which had no `Rehydrated` fields, is still read.

### Identity only

`-IdentityOnly` is the quick who, what and where pass. It needs `RECmdPath` in the config given with `-ConfigPath`, and takes no `-HayabusaPath`:

```powershell
.\Invoke-BulkHayabusa.ps1 -InputRoot D:\Cases\Case01\KAPE -OutputRoot D:\Cases\Case01\Output -ConfigPath D:\Cases\Case01\engagement.psd1 -IdentityOnly
```

It finds the collections and extracts or mounts each one the same way a normal run does, with the same ZIP limits and the same hash of a disk image before it's mounted and after teardown. It reads the host's identity, tears the collection down, and then writes `identity_dashboard.html`. Disk images need an elevated session, as in a normal run. Hayabusa isn't run, and the manifest, run-meta and triage files aren't written or changed, so it can run before, after or between normal runs into the same OutputRoot. A collection whose identity is already Complete, or has no registry hives, is skipped unless `-Force` is given. A ZIP the tool can't extract is saved as Failed with the same advice as a normal run, and an image whose hash changed is warned about and noted first in that host's identity.

### The identity dashboard

`identity_dashboard.html` has one row per host: the registry computer name, the collection, its status, the OS and build, the domain, the time zone, the likely active address with its network name, and the interactive users. The other interfaces, newest lease first, the built-in and system accounts, and the host's notes are folded under each row, so a row stays one line until it's opened. A host with no registry hives, or whose identity couldn't be read, says so across its row. A value from a hive that wasn't read shows as not read, and one the hive doesn't hold as not found, so nothing is ever filled in.

It lists every collection with an identity file, and every collection in the manifest, so a host not read yet shows as Not read. It's static like the triage dashboard: no script, nothing loaded from the internet, a Content Security Policy that blocks script, and every value HTML-encoded. It copies only the fields it shows from each identity file, so a field added to a file by hand can't appear either. The password hint, the answers to security questions and the Microsoft account name are never in an identity file to begin with. The next run with `RECmdPath` set, or with `-IdentityOnly`, rebuilds it.

### Checking a new RECmd release

The RECmd compatibility test builds throwaway SYSTEM and SOFTWARE hives from made-up keys in a temporary folder, without reading or saving the live registry, runs RECmd over them, and checks it still writes every column the parser reads and gives back the planted computer name. It needs Windows:

```powershell
$env:RECMD_COMPAT_PATH = 'D:\Tools\RECmd\RECmd.exe'
Invoke-Pester -Path .\tests\HostIdentity.Tests.ps1 -TagFilter Compatibility
```

SAM isn't covered, since a valid SAM can't be made up, so check the users against a real collection too. When it passes, raise `$script:TestedRECmdVersion` in `lib\HostIdentity.ps1`, then set the same version between the tested-recmd-version markers in this file. A test fails if they don't match.

## Running the tests

The tests use [Pester](https://pester.dev) 5 and a fake Hayabusa written in PowerShell, so they don't need the real binary or any evidence.

```powershell
Install-Module Pester -RequiredVersion 5.7.1 -Scope CurrentUser -Force -SkipPublisherCheck
Invoke-Pester -Path .\tests
```

Most of the suite runs anywhere. The end-to-end run with the fake binary needs Windows. `tests\Mount.Integration.Tests.ps1` builds a small VHDX, mounts it the same way a real run does, and checks the image's hash is unchanged afterwards. It only runs on Windows in an elevated session and skips everywhere else. `tests\Compatibility.Tests.ps1` also runs the self-test against a real Hayabusa when `HAYABUSA_COMPAT_PATH` is set to its `hayabusa.exe`, on Windows, and skips otherwise. `tests\HostIdentity.Tests.ps1` runs RECmd against throwaway hives when `RECMD_COMPAT_PATH` is set to its `RECmd.exe`, on Windows, and skips otherwise too.

Lint with [PSScriptAnalyzer](https://github.com/PowerShell/PSScriptAnalyzer), which includes the Windows PowerShell 5.1 compatibility rules:

```powershell
Install-Module PSScriptAnalyzer -RequiredVersion 1.23.0 -Scope CurrentUser
foreach ($p in '.\Invoke-BulkHayabusa.ps1', '.\Invoke-HayabusaRollup.ps1', '.\Test-HayabusaCompatibility.ps1', '.\lib') {
    Invoke-ScriptAnalyzer -Path $p -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
}
Invoke-ScriptAnalyzer -Path .\tests -Recurse -Settings .\tests\PSScriptAnalyzerSettings.psd1
```

CI runs both, plus gitleaks, on every push and pull request.
