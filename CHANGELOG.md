# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Each disk image is hashed with SHA-256 just before its differencing disk is created and again after the differencing disk is dismounted and deleted. An image inside a ZIP is hashed as the extracted image that gets mounted. Both hashes and whether they match are recorded per host in run-meta, as `ImagePath`, `ImageSha256Before`, `ImageSha256After` and `ImageHashMatch` on each collection. Run-meta's SchemaVersion is now 7. If the hashes differ, the host is Failed with an "Evidence integrity check failed" error naming both, and the dashboard leads with a red notice. Each hash reads the whole image, so a large image adds a pause before and after its host, and the run says so at the start and before each hash. The README claimed this before-and-after hash, but only the integration tests took it.

### Fixed

- Each file extracted from a ZIP is now checked against the CRC-32 and uncompressed size the ZIP recorded for it. A damaged ZIP, with a flipped byte or data that ends short, used to extract without complaint, so Hayabusa scanned a corrupted or truncated log and the host came back Completed. Now that host is Failed with a message that the ZIP may be damaged, naming the entry, and the rest of the run carries on. The checksum is computed by a small class compiled once per session, the first time a ZIP is extracted.
- InputRoot is refused if it's inside OutputRoot, as OutputRoot inside InputRoot already was. The tool creates and deletes files under OutputRoot, and with InputRoot pointed at OutputRoot's `_diff` folder, for example images kept there by `-KeepArtifacts`, an input image had the same path as the differencing disk the tool clears before mounting, and was deleted.
- A host where Hayabusa exited 0 but wrote no CSV is now recorded as Failed, with Hayabusa's own error from stderr in Error, and is retried on the next run. It used to be recorded as Completed with no detections and a warning, and skipped on every rerun. Hayabusa does this when it stops on an error: for a `--timeline-start` it can't parse, 4.2.0 exits 0, writes no CSV, and prints the reason only on stderr. A run that matches nothing writes an empty CSV, which is still Completed with no detections. Hosts an earlier version already recorded this way stay Completed: find them by the warning "Hayabusa exited 0 but wrote no CSV" in `run_manifest.csv`, delete their rows and run again, or rerun everything with `-Force`.
- The compatibility self-test's FAIL line for a run that exits 0 with no CSV now gives Hayabusa's error from stderr, so the watcher's issue says why the run failed. Its note that the tool records a missing CSV as a failed host was wrong before this fix and is now right.

## [0.8.1] - 2026-10-15

### Security

- The compatibility watcher no longer runs the downloaded Hayabusa binary anywhere a token can write. The job that unpacks and runs it has a read-only token, held only by the steps that call `gh` before anything is unpacked. The issue is filed by a separate job on a fresh runner.

### Fixed

- A config that sets `RulesPath` to an empty value is refused at load. It used to fall back to the config file's own folder, so every host ran against the wrong rules with no warning.
- A host's log from an earlier run is removed as soon as the host is run again. A rerun that failed before Hayabusa started, for example an image that wouldn't mount or a ZIP over a limit, used to leave the earlier log, with its results summary, linked from the new Failed row.
- A Completed host whose timeline CSV the rollup can't read is now shown as Unreadable, with a red badge, in the dashboard and `triage_hosts.csv`, and is listed after the Failed hosts. It used to show a green Completed badge with blank counts and sort among the clean hosts. The manifest keeps the status the run recorded.
- `TimelineStart` and `TimelineEnd` reach Hayabusa in the documented `yyyy-MM-dd HH:mm:ss +00:00` form. An offset written as `+5:30` or `+0530` was accepted by the check but passed on as typed. It's now passed on as `+05:30`, the value that was checked.
- The dashboard only removes OutputRoot from a note where it starts a path. It used to remove it anywhere, so an OutputRoot of `D:\` turned "failed: disk" into "faile disk".
- The compatibility self-test now checks each filter is applied, not just accepted. Two runs are added, `-e critical` and `--include-tag` with a tag the sample's rule doesn't carry, and they and the `--exclude-tag` run fail if the sample is still detected. The `--exclude-tag` run used to pass either way, and nothing checked `-e` or `--include-tag`, so a release that accepted a filter but ignored it passed.
- The compatibility watcher files one issue per release and stays quiet until something changes. When the result flips it comments and retitles the issue to the new result, so the next run matches it instead of commenting again every week. Closed issues count too, so a release closed without adopting it isn't filed again. A FAIL whose failing checks change gets a comment naming the new ones, where it used to say nothing.
- Timestamps in the manifest, run-meta, logs, the dashboard and file names are written the same way whatever the Windows region settings. A locale with a different time separator used to write times like `10.20.30`, and one with another calendar, such as Thai, a different year.
- USAGE and the 0.7.0 notes said a `MinLevel` or `ExactLevel` of emergency, with the standard rules, matches nothing and the run carries on. Hayabusa loads no rules, stops with "No rules were loaded" and exits 1, so every host fails, as the startup notice says. They now say that.
- The README said to keep `lib` beside the two scripts. There are three: `Invoke-BulkHayabusa.ps1`, `Invoke-HayabusaRollup.ps1` and `Test-HayabusaCompatibility.ps1`.
- The USAGE step for adopting a new Hayabusa release named only the README's tested-version markers. It now names the ones in USAGE too.

## [0.8.0] - 2026-10-15

### Added

- A scheduled Hayabusa compatibility watcher. Once a week, and on demand, a workflow checks for a new Hayabusa release, runs `Test-HayabusaCompatibility.ps1` against it when it isn't the tested version, and files a `hayabusa-compat` issue with the result. It never changes the repo.

### Changed

- Tested against Hayabusa 4.2.0. The startup notice no longer fires on 4.2.0.
- The dashboard summary tiles show a plain count per severity, and now include an informational tile. The host subtext on the emergency, critical and high tiles is removed, so all six read the same way.
- Host names in the dashboard's host table, and the collections in the rules table's "Seen on" column, are shown as grey chips that wrap within the cell, so a long name no longer widens the table.
- The dashboard's host table heads its first column Hostname instead of Host. `triage_hosts.csv` keeps its Host column.
- The host table and `triage_hosts.csv` list hosts with results first, worst first, and hosts without results, such as Failed, Running and Pending, below them.

## [0.7.0] - 2026-10-14

### Added

- A compatibility self-test, `Test-HayabusaCompatibility.ps1`, that runs a Hayabusa binary against a generated sample and checks the flags, output columns and severity levels the tool relies on, plus a startup notice when the Hayabusa version differs from the tested one.

### Changed

- README trimmed to a scannable front page. The full reference moved to `docs/USAGE.md`.
- Dashboard section "Provenance" renamed to "Run details".
- The default severity floor is now medium instead of high.
- A run whose severity level resolves to emergency now warns at startup that no shipped Hayabusa rule is emergency, so without level-tuning no rules load and every host fails.

## [0.6.3] - 2026-10-13

### Added

- `-Help` and `-h` on both entry scripts. Prints a short usage summary and exits. PowerShell's `-?` and `Get-Help -Full` still work as before.

### Changed

- Expanded docs: worked example commands for customising a run, the output profile explained, and the ZIP limits spelled out.
- Sample output folder renamed from `Hayabusa` to `Output` so it isn't mistaken for the binary.

## [0.6.2] - 2026-10-13

### Fixed

- Rerun result attribution. A rerun no longer shows a previous run's detections or report as the new run's. A host that fails or produces nothing shows no stale counts.
- Atomic writes for the manifest, triage CSVs and dashboard, so an interrupted save can't wipe resume state on Windows PowerShell 5.1.
- A ZIP with an entry name Windows can't hold now fails only that collection instead of stopping the whole run on 5.1.
- Only a genuine path-length problem gets the shorter-OutputRoot advice. A non-ASCII disk-image path is refused with a message naming it.
- Per-host cleanup now runs even when a run is interrupted.
- A config with an empty severity level is refused at load.

## [0.6.1] - 2026-10-12

### Added

- First public release. Runs Hayabusa 4.1.0 across a folder of KAPE collections, one run per host, producing a per-host alert report, CSV timeline and log, plus a cross-host triage dashboard.
- Handles loose folders, ZIPs and VHD/VHDX disk images, extracting or mounting each as needed. Evidence is mounted read-only through a differencing child so the parent stays untouched, verified by hash before and after.
- ZIP handling hardened against path traversal, zip bombs and Windows long paths.
- Tested in CI on Windows PowerShell 5.1, PowerShell 7 on Windows, and PowerShell 7 on Linux.

[Unreleased]: https://github.com/rorywag/Hayabusa-Bulk-Runner/compare/v0.8.1...HEAD
[0.8.1]: https://github.com/rorywag/Hayabusa-Bulk-Runner/compare/v0.8.0...v0.8.1
[0.8.0]: https://github.com/rorywag/Hayabusa-Bulk-Runner/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/rorywag/Hayabusa-Bulk-Runner/compare/v0.6.3...v0.7.0
[0.6.3]: https://github.com/rorywag/Hayabusa-Bulk-Runner/compare/v0.6.2...v0.6.3
[0.6.2]: https://github.com/rorywag/Hayabusa-Bulk-Runner/compare/v0.6.1...v0.6.2
[0.6.1]: https://github.com/rorywag/Hayabusa-Bulk-Runner/releases/tag/v0.6.1
