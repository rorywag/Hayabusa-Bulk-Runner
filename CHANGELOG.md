# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- README trimmed to a scannable front page. The full reference moved to `docs/USAGE.md`.
- Dashboard section "Provenance" renamed to "Run details".

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

[Unreleased]: https://github.com/rorywag/Hayabusa-Bulk-Runner/compare/v0.6.3...HEAD
[0.6.3]: https://github.com/rorywag/Hayabusa-Bulk-Runner/compare/v0.6.2...v0.6.3
[0.6.2]: https://github.com/rorywag/Hayabusa-Bulk-Runner/compare/v0.6.1...v0.6.2
[0.6.1]: https://github.com/rorywag/Hayabusa-Bulk-Runner/releases/tag/v0.6.1
