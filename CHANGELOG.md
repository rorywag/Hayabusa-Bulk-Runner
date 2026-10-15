# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Security

- The compatibility watcher no longer runs the downloaded Hayabusa binary anywhere a token can write. The job that unpacks and runs it has a read-only token, held only by the steps that call `gh` before anything is unpacked. The issue is filed by a separate job on a fresh runner.

### Fixed

- A config that sets `RulesPath` to an empty value is refused at load. It used to fall back to the config file's own folder, so every host ran against the wrong rules with no warning.
- A host's log from an earlier run is removed as soon as the host is run again. A rerun that failed before Hayabusa started, for example an image that wouldn't mount or a ZIP over a limit, used to leave the earlier log, with its results summary, linked from the new Failed row.

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
- A run whose severity level resolves to emergency now warns at startup that no shipped Hayabusa rule is emergency, so the run matches nothing without level-tuning.

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

[Unreleased]: https://github.com/rorywag/Hayabusa-Bulk-Runner/compare/v0.8.0...HEAD
[0.8.0]: https://github.com/rorywag/Hayabusa-Bulk-Runner/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/rorywag/Hayabusa-Bulk-Runner/compare/v0.6.3...v0.7.0
[0.6.3]: https://github.com/rorywag/Hayabusa-Bulk-Runner/compare/v0.6.2...v0.6.3
[0.6.2]: https://github.com/rorywag/Hayabusa-Bulk-Runner/compare/v0.6.1...v0.6.2
[0.6.1]: https://github.com/rorywag/Hayabusa-Bulk-Runner/releases/tag/v0.6.1
