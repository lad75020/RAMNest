# Parent-host verification handoff

The procedure below is retained for reproducibility. Completed host evidence and remaining limits are now recorded in [VERIFICATION_RESULTS.md](VERIFICATION_RESULTS.md).

Run these commands outside the coding sandbox on macOS 27.0+ with the installed FUSE-T 1.2.9 runtime. They use only disposable project artifacts. No sudo, global FUSE configuration, TCC changes or system installations are part of this procedure. Do not run a real shutdown test. The final package is ad-hoc signed and deliberately has no cloud setup.

## Local automated verification

```sh
cd /Volumes/WDBlack4TB/Code/RAMNest
scripts/test.sh
scripts/package.sh
cat artifacts/logs/native-tests.log
cat artifacts/logs/core-tests.log
cat artifacts/logs/cli-tests.log
cat artifacts/logs/callback-coverage.log
codesign --verify --deep --strict artifacts/RAMNest.app
otool -L artifacts/ramnest-helper
```

The helper must link `/Library/Application Support/fuse-t/lib/libfuse-t-1.2.9.dylib` directly, not the missing `@rpath/libfuse-t.dylib`. Source archives exclude captured vendor help text and all third-party runtime binaries.

## Real mounted operations and physical memory

```sh
python3 scripts/host-integration.py
```

This creates a fresh `artifacts/host-integration-UUID`, mounts the same selected seeded path, verifies initial population/provenance, read/write/pread/pwrite/append, rename/hardlinks/open-unlink, directories, symlink, xattr CRUD, sparse zeros, ENOSPC, live resize, coherent save, repeated mount/eject, external `umount` while GUI absent, temporary discard and remount preservation. It checks the helper's independent `ps` RSS against incompressible 128 MiB, delayed truncation/unlink and compressible 128 MiB, separately from logical/payload/mapped counters. `commands.json` and `report.json` retain actual results. A failure leaves files and snapshots available; inspect the printed recovery command, do not remove the fixture blindly.

```sh
# Optional, explicitly destructive ONLY to this disposable test helper:
python3 scripts/host-integration.py --crash-helper
```

That opt-in run SIGKILLs only the pid returned by the fresh fixture's same-user helper socket after saving a durable sentinel, force-unmounts its orphaned test mount, verifies the startup gate, and recovers the last committed snapshot. It never terminates user applications. Do not infer helper-crash behavior from a GUI crash.

For an additional independent memory trace, obtain the helper pid from the fixture socket (the status response fields are `OK`, UUID, pid, mounted/retained, logical bytes, capacity, active/guarded), then use:

```sh
ps -o pid,rss,vsz,command -p HELPER_PID
vmmap -summary HELPER_PID
```

Use incompressible bytes, checksum-read them, truncate/delete directly, close all open handles and allow time for measurement before comparing. An open-unlinked file correctly retains backing until its last handle closes. OS caches/compression/swap and runtime overhead prevent a promise of zero disk writes or exact RSS==mapped bytes.

## GUI, menu-bar, crash survival and clean quit

Prepare isolated UI data and launch a fresh app instance:

```sh
cd /Volumes/WDBlack4TB/Code/RAMNest
ui_fixture="$PWD/artifacts/gui-host-$(date +%Y%m%d-%H%M%S)"
mkdir -m 700 "$ui_fixture" "$ui_fixture/source" "$ui_fixture/support"
printf 'GUI seed\n' > "$ui_fixture/source/seed.txt"
open -n "$PWD/artifacts/RAMNest.app" --args --store "$ui_fixture/support"
```

1. Create a RAM folder using the chooser, optional unique name, 256 MB, compression on and sync on. Confirm the same path, seed contents, sidebar status and capacity. Repeat with a dropped folder; test Dock/Open With separately if Launch Services registration is available.
2. Edit the name and normal/advanced options. Switch selection, mount/eject and attempt quit with unsaved changes. Exercise Apply/Discard/Cancel. Confirm compression/visibility labels explicitly say next mount. Test resize while mounted and reject shrink below logical allocation.
3. Check file/payload/mapped/savings metrics while writing compressible and incompressible data. Check the memory bar, Finder reveal/open, Save Snapshot, Export and Recover controls.
4. In Settings, toggle Dock/menu-bar mode and verify close-window behavior. Leave Open at Login unchanged unless explicitly testing its user opt-in; if tested, restore its previous setting afterwards.
5. Write a sentinel, record the helper pid, then force-quit **only this disposable RAMNest GUI**. Confirm the same selected path still works and the helper pid remains alive. Relaunch with the same `--store` and confirm reconnection with no duplicate mount or snapshot overwrite.
6. With the GUI absent, normally eject the disposable volume through Finder, `diskutil unmount PATH`, and `/sbin/umount PATH` on separate cycles. Wait until journal phase becomes idle and check sentinel files restored at the original path. Retained RAM is exported after FUSE teardown; restore is not assumed complete merely because the mount vanished.
7. Reopen, mount and use normal Quit. Confirm the save/eject progress and final ordinary folder contents before declaring quit successful. To test busy handling, hold a file/CWD in a disposable child shell and choose Cancel/Stay, then close that shell yourself and retry. Never kill unrelated apps.
8. Create temporary mode, modify data and live-resize, then eject. Confirm original contents return and RAM-only edits disappear. Explicit live export should still rescue temporary data when requested before eject.

Record screenshots, exact paths, pids, journal phases and final ordinary-folder checks. GUI compilation is not visual/workflow proof. Login registration, Finder UI, host crash/quit and actual periodic timing remain UNVERIFIED until these commands/steps produce evidence on the final bundle.

## Existing parent evidence and remaining boundary

The parent-provided `ramnest-host-operations-legacyrename/report.json` has 19 PASS checks and no unsupported checks on the frozen probe plus `namedattr,use_ino` and omitted production renamex. Those exact transport corrections are integrated. The parent separately measured native LZ4 physical savings/reclamation in `artifacts/parent-native-compression.json`. Neither result alone certifies the final GUI/package lifecycle; rerun the above on the final artifacts and retain outputs.

## GUI launch regression handoff

The parent has already verified 62 core checks (19+17+11+15) on the earlier frozen release and built/tested the Xcode scheme (1/1 XCTest, 11 internal scenarios). The actual remaining blocker was a pre-window AppGraph recursion. A corrected signed Debug bundle is kept separately so Release packaging cannot replace it during host testing:

```sh
open -n /Volumes/WDBlack4TB/Code/RAMNest/artifacts/RAMNest-Debug.app --args --store /Volumes/WDBlack4TB/.hermes/cache/scratch/ramnest-final-gui/store
# After observing a visible responsive window, quit this instance normally.
open -n /Volumes/WDBlack4TB/Code/RAMNest/artifacts/RAMNest.app --args --store /Volumes/WDBlack4TB/.hermes/cache/scratch/ramnest-final-gui/store
```

Confirm both windows become visible and remain responsive, the seeded file is preserved, and normal quit saves/ejects if startup mounts it. Then test switching Dock/menu mode, closing and reopening the main window from the status item, New RAM Folder and Settings, and the existing clean-quit checks. Avoid launching two GUI instances against this same store concurrently. If a launch fails, preserve the new `.ips` path (including `Retired/` if macOS moved it) and report the actual window outcome; headless lifecycle tests are not launch proof.

The parent corrected the large ENOSPC harness: catch capacity errors from the entire with/fsync/close, since NFS may repeat a delayed write error on context-manager exit. No filesystem quota/statfs changes were made. Keep the parent's cleanup/xattr changes when rerunning `python3 scripts/host-integration.py --crash-helper`.
