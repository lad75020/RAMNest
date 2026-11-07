# Verified delivery

This is the final host verification record. Earlier handoff notes and “final rerun” cells in the feature matrix describe earlier build stages; this record supersedes those pending labels for the checks listed here.

## Build and automated tests

- `scripts/test.sh`: passed. Five native suites cover filesystem operations, compression/export, actual process footprint, real libfuse dispatch and freeze-only temporary eject. Swift tests passed 12 integration scenarios; CLI and GUI-model/lifecycle checks passed.
- Xcode was explicitly launched before MCPO calls. MCPO `BuildProject` succeeded after regenerating the project with the unnecessary Objective-C header installation disabled for the pure-Swift core.
- Final `xcodebuild ... test` succeeded: one XCTest method, zero failures, running the shared integration scenarios. Result bundle: `artifacts/FinalTests.xcresult`; log: `artifacts/logs/xcode-final-tests.log`.
- Bundle signatures, minimum system version, archives and checksums are checked during packaging. This is an Apple Silicon, macOS 27.0+ development build, ad-hoc signed rather than notarized.

## Actual mounted filesystem

The bundled CLI was exercised through real FUSE-T NFS mounts at disposable existing-folder paths, not a mocked mount backend:

- 19 operation checks: same-path mounting, initial population, reads/writes and offsets, append, truncate/zero-fill, hardlinks/inodes, symlinks, rename, modes, current-user ownership, timestamps, xattrs, directory enumeration/removal, fsync, capacity, mmap and save/eject.
- 17 memory/lifecycle checks: incompressible checksum verification, real helper RSS growth, truncate/delete reclamation, sparse holes, open-unlink lifetime, remount persistence and external eject with no GUI.
- 11 compression checks: encoded data and real page savings, incompressible fallback, replacement/reclamation, save/eject/remount roundtrip and disabling compression at the next mount.
- 15 failure/lifecycle checks: temporary discard with lossless live resize, busy-process refusal, failed snapshot and failed restore recovery, explicit termination of the owned test helper, recovery of the last committed checkpoint, and renamed-folder tracking. The final moved-folder check passed after adding bounded retries for transient macOS bookmark resolution.
- The larger shipped host integration script also passed with its disposable-helper crash option. Expected NFS capacity errors are caught from writes, fsync and close.
- A separate final temporary-mode test confirmed unchanged originals, no exported stage and no RAM-only sentinel in retained on-disk storage.

Reports are collected under `artifacts/verification/`. Memory measurements distinguish mapped backing from helper RSS, temporary buffers and kernel caches; they do not promise that macOS never swaps.

## Actual GUI

Both Debug and Release windows launched and auto-mounted their isolated configured folders after correcting the initial SwiftUI scene lifecycle issue. The host exercised Normal/Advanced options, compression toggle and Discard, Settings, Dock/menu-mode toggling, the native chooser opening/cancellation, Open With folder prefill and GUI Create and Mount. The GUI-created folder mounted at its original path with its source files intact. A 4 GiB configured ceiling for that tiny folder allocated only a small backing mapping.

Normal application Quit saved and ejected two mounted folders. File contents were verified after exit and after Release relaunch. No login item, system permission, global FUSE setting or machine shutdown was changed for testing.

## Remaining limits

- Actual login registration, a real machine shutdown/power failure, exhaustive accessibility review and a full five-minute periodic-timer wait were not exercised.
- FSEvents suppression and several specialized FUSE operations are unavailable through the installed bridge. The complete SDK/transport distinction is in `FUSE_COMPATIBILITY.md`; unsupported operations return explicit errors.
- S3/cloud storage is intentionally absent. Snapshots/original holding copies are retained rather than automatically garbage-collected.
