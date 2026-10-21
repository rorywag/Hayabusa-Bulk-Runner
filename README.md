# Hayabusa-Bulk-Runner

A PowerShell wrapper that runs [Hayabusa](https://github.com/Yamato-Security/hayabusa) across a folder of KAPE collections, one run per host, and rolls the results up into a single cross-host triage view.

Hayabusa already takes a whole directory with `-d`, and its HTML summary breaks the results down by computer. A folder of KAPE collections still leaves two jobs to do by hand. Each ZIP has to be extracted and each disk image mounted before Hayabusa can read it, and a run over all of them gives one combined output, with no report or timeline of its own for each host. This does that part. Point it at a folder with one entry per host and you get, for each host, Hayabusa's HTML alert report, a CSV timeline and a log, plus a dashboard showing which hosts are worst and which rules fired where.

**Full usage reference: [docs/USAGE.md](docs/USAGE.md)**

## Screenshots

The dashboard after a run over eight hosts, with the severity floor at medium:

![Triage dashboard: severity totals, the top rules, every rule that fired and the hosts it fired on, then one row per host, worst first](docs/images/dashboard.png)

The console during the same run:

![Console output of a run: a warning for a ZIP the tool can't extract, one progress line per host and the end-of-run summary](docs/images/console.png)

## What it does

- Runs Hayabusa once per host, so each host gets its own HTML report, CSV timeline and log instead of one combined output.
- Extracts each KAPE ZIP and mounts each disk image for you, then tears it all down again once the host is done.
- Builds a cross-host dashboard: totals by severity, the rules that fired and the hosts each one hit, and every host ranked worst first.
- Reads the host name from Hayabusa's own `Computer` field, so loose output that KAPE named after a drive still lands under the right host.
- Resumes a case. Run the same command again and it skips the hosts already finished and picks up the rest.
- Treats the evidence as read-only the whole way through. Each disk image is hashed with SHA-256 before it's mounted and again after teardown, both hashes go in the run's record, and a host whose image changed fails.
- Takes an engagement config so every host in a case runs against the same settings.
- Optionally reads each host's identity from its registry hives with RECmd, the computer name, OS, domain, time zone, local users and IP addresses, into a separate identity dashboard. `-IdentityOnly` does just that, without Hayabusa.

## Status

Released. It's early days, so bugs may surface. It's been run against real Hayabusa <!--tested-version-->4.2.0<!--/tested-version--> and KAPE images and ZIPs on Windows, and the test suite runs in CI on Windows PowerShell 5.1, PowerShell 7 on Windows, and PowerShell 7 on Linux. Two behaviours still need the right evidence to confirm, listed under [Not yet confirmed on Windows](docs/USAGE.md#not-yet-confirmed-on-windows). Check that list before relying on one of them in a report.

## Requirements

- Windows. This tool runs Hayabusa and mounts disk images on Windows only. The rollup can be rebuilt anywhere PowerShell runs.
- Windows PowerShell 5.1 or PowerShell 7.
- Hayabusa <!--tested-version-->4.2.0<!--/tested-version--> with its rules. Run `hayabusa.exe update-rules` once at the start of the engagement and leave the rules alone until it's finished, so every host is checked against the same set.
- An elevated session if any collection is a disk image, including a disk image inside a ZIP.

## Getting it

Clone the repository, or download it as a ZIP from GitHub and extract it:

```powershell
git clone https://github.com/rorywag/Hayabusa-Bulk-Runner.git
```

Keep the `lib` folder beside the three scripts, `Invoke-BulkHayabusa.ps1`, `Invoke-HayabusaRollup.ps1` and `Test-HayabusaCompatibility.ps1`, since they load everything from it. Windows marks files from a downloaded ZIP as coming from the internet. The Process-scope execution policy shown below already allows them, so there's nothing to unblock.

## Quick start

```powershell
.\Invoke-BulkHayabusa.ps1 -InputRoot D:\Cases\Case01\KAPE -OutputRoot D:\Cases\Case01\Output -HayabusaPath D:\Tools\hayabusa\hayabusa.exe
```

It prints one line per host as it goes, then a short summary and where to look:

```
[1/4] DC01 ... Completed, 12 detections
[2/4] FS02 ... Completed, 6 detections
WARNING: [3/4] WS03 ... Failed: Hayabusa exited with code 2. See D:\Cases\Case01\Output\WS03\WS03_hayabusa.log. No CSV was written.
[4/4] WS04 ... skipped, already Completed
Done: 3 processed, 2 completed, 0 completed with errors, 1 failed, 1 skipped.
Output is in D:\Cases\Case01\Output. Open triage_dashboard.html there to start triage.
```

In a fresh PowerShell window the script may be blocked by the execution policy. This allows it for that window only, and changes nothing on the machine:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

`.\Invoke-BulkHayabusa.ps1 -Help`, or `-h`, prints a short usage summary. For the full parameter list, worked examples, the input and output model and the engagement config, see [docs/USAGE.md](docs/USAGE.md).

## Evidence integrity

The evidence is only ever read.

- Disk images are never mounted directly. KAPE images are dirty when they're created, so a read-only mount shows no volume at all. Instead the tool mounts a differencing disk under `OutputRoot\_diff` with the evidence image as its parent. Windows replays the journal into the child and the parent is only read.
- Every run checks that. Each disk image is hashed with SHA-256 just before its differencing disk is created, and again once the differencing disk is dismounted and deleted. For an image inside a ZIP, the hash is of the extracted image that gets mounted. Both hashes and whether they match are recorded per host in the run's record under `OutputRoot\_runs`. If they differ, the host is Failed with an "Evidence integrity check failed" error naming both hashes, and the dashboard leads with it. Each hash reads the whole image, so a large image adds a noticeable pause before and after its host. Loose folders, and ZIPs with no disk image in them, aren't hashed.
- An image that's already attached is refused, not reused or dismounted, since this run didn't attach it.
- ZIPs are extracted to a working copy under `OutputRoot\_work`. The ZIP itself is only read. Each extracted file is checked against the size and CRC-32 the ZIP recorded, so a damaged ZIP fails its host instead of handing Hayabusa a truncated or corrupted log.
- After each host, teardown runs in a fixed order, whatever happened: remove the folder mount point if one was used, dismount the child, remove the empty mount folder, delete the child, hash the image again, delete the extract. Nothing is ever deleted recursively through a folder that might still be a mount point. The tool only deletes inside its own `_work`, `_mnt` and `_diff` folders, plus a host's own previous report and timeline just before that host is rerun. If a dismount fails, everything after it is left in place and the error says what's still there.
- OutputRoot is refused if its path is inside InputRoot, so output doesn't land next to the evidence. InputRoot is refused if its path is inside OutputRoot, since the tool creates and deletes files there. Pointing InputRoot at a `_diff` folder kept by `-KeepArtifacts`, for example, would let an evidence image share the path of a differencing disk the tool is about to clear.
- Nothing from the evidence is ever run. Values from it, such as rule titles and computer names, are encoded wherever they're written out.

## Documentation

[docs/USAGE.md](docs/USAGE.md) covers the rest:

- Every command-line parameter, with worked examples
- How InputRoot entries are read: folders, disk images and ZIPs
- ZIP handling, and the size and long-path limits
- The full list of outputs and the tool's working folders
- Rerunning, resuming and what each status means
- The engagement config and every setting it takes
- Reading host identity from registry hives with RECmd, the identity dashboard and `-IdentityOnly`
- Running the tests

## Security

See [SECURITY.md](SECURITY.md) for how to report a vulnerability privately.

## Licence

MIT. See [LICENSE](LICENSE).

This tool is independent and is not affiliated with or endorsed by Yamato Security. It runs Hayabusa as a separate external program and includes none of its code. Hayabusa is published by Yamato Security under the GNU AGPL-3.0, and its detection rules under their own licences. Download Hayabusa and its rules from Yamato Security.
