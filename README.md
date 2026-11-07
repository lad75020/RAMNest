# RAMNest

RAMNest is a native macOS 27.0+ Apple Silicon app that keeps an existing folder accessible **at its original path** while its contents run in a FUSE-T memory filesystem. NFS/SMB mount there directly; new FSKit sessions use a private internal mountpoint and an original-path symlink. It includes a SwiftUI app, shared Swift core, detached C++ per-volume helper, and bundled `ramnest` CLI. Storage is local only. There is no telemetry, trial, licensing server, automatic updater, cloud credential handling, or S3 implementation.

Content uses transparent, default-on LZ4 compression through Apple's system Compression API. Each 64 KiB logical block owns anonymous `mmap` backing rounded to 16 KiB VM pages. Incompressible blocks stay raw; truncation/deletion releases mappings with `munmap`. Capacity is an uncompressed allocation ceiling, not an eager reservation. Sparse holes remain unallocated. [Memory and compression details](docs/MEMORY.md) explain counters, quotas, OS caching/compression/swap, and measured RSS.

## Build and run

The local `SymLinks` work adds FSKit mounting for external-source folders through
an internal target. See [the FSKit symlink layout](docs/FSKIT_SYMLINK_LAYOUT.md)
for behavior, recovery limits and verification. The earlier
[Trash-exclusion delivery report](docs/TRASH_EXCLUSION_DELIVERY.md) remains
historical evidence, not proof of this new layout.

Requires Xcode 27 / Swift 6, CMake, macOS 27.0+, and an independently installed [FUSE-T](https://github.com/macos-fuse-t/fuse-t/wiki) runtime. This build uses **only** `/Library/Application Support/fuse-t/include/fuse` and `/Library/Application Support/fuse-t/lib/libfuse-t-1.2.9.dylib`. It never picks global macFUSE headers or installs anything as root. The third-party FUSE-T runtime is not redistributed.

**Settings → Backend for next mount** selects **NFS**, **FSKit**, or **SMB3** for the next new mount of any folder. The app-wide `Configuration.backend` persists as `nfs`, `fskit`, or `smb`. NFS is the default, including existing configuration JSON that lacks this field; unknown or malformed values fail decoding. Existing mounts and helpers are never changed by this preference. A new session records its selected backend in the journal, and mounted captions use that record. Legacy sessions without a record are labeled “backend not recorded.”

Every new session explicitly passes its recorded `--backend` to the helper, which emits exactly one per-mount `backend=...` option. SMB3 uses the FUSE-T id `smb` and additionally forces `listen_addr=127.0.0.1:0,nobonjour`, without LAN advertising. FSKit uses the validated id `fskit` (the requested “fsdisk” choice is labeled FSKit). Before using FSKit, open `/Applications/fuse-t.app` and follow its instructions to manually enable the extension; registration alone does not prove activation. New FSKit sessions mount at `/Users/Shared/RAMNest-Mounts-<uid>/<original basename>` and publish a symlink at the original folder path, avoiding an OS mount on the external source volume. The private mount root is current-user-only, requires no elevation, and rejects basename collisions. NFS, SMB and existing absent-layout FSKit sessions keep their old paths. RAMNest never changes global `fuse-t.ini` or retries with a different backend. See [backend settings and FSKit validation](docs/FSKIT_BACKEND.md).

```sh
cd /Volumes/WDBlack4TB/Code/RAMNest
scripts/test.sh
scripts/package.sh
open artifacts/RAMNest.app
artifacts/ramnest --help
```

`build.sh` compiles the real Swift app/core/CLI and C++ helper, patches the helper's private FUSE-T dylib install name, and ad-hoc signs the bundle. It uses project-local caches and temporary files. No compiler or filesystem sandbox is disabled. SwiftPM's nested manifest sandbox cannot start in the coding sandbox here; direct `swiftc` builds cover exactly the same source targets. On an unrestricted development host, SwiftPM remains available:

```sh
export CLANG_MODULE_CACHE_PATH="$PWD/.build/cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
swift test --scratch-path .build/swift --cache-path .build/cache
```

An XcodeGen specification is included. The symlink-layout work is verified using
`BuildProject` for the Release app and `RunSomeTests`/`RunAllTests` for enabled
Debug XCTest cases; its static shared core, bundled CLI and native helper are built together.
The direct-build scripts above are historical alternatives, not this delivery's
accepted packaging path: the direct-build variant failed a rootless-legacy
metadata check by acquiring an additional OS provenance attribute. That failure
was not hidden by changing metadata rules. Bundles are local ad-hoc signed, not
Developer ID signed/notarized or App Store sandboxed.

## Working with a folder

Directories named exactly `.Trashes`, at any depth, are excluded from snapshots,
verification, population and reload. The check uses no-follow directory metadata
before entering the subtree or reading its permissions, ACLs, xattrs or contents.
Files and symlinks named `.Trashes`, and names such as `.trashes`, `.Trash` and
`.TrashesBackup`, retain the normal strict preservation contract. Finder can
create Trash in RAM and that usage counts toward capacity. **Trash created in RAM
is disposable at eject and is never checkpointed or restored.**

Preexisting disk Trash is preserved. Mount preparation moves originals through
the normal durable evacuation journal into a private holding directory. A holding
that contains excluded Trash is retained with its snapshot pins and a nonfatal
cleanup warning containing the recovery location. Nested Trash retains that
holding too; a filtered comparison never authorizes recursive deletion. See
[Trash exclusion and recovery](docs/TRASH_EXCLUSION.md) before removing any retained
holding manually.

Use **New RAM Folder**, drop a folder on the window/Dock, or select an existing directory. Choose capacity in MB/GB (binary MiB/GiB), optional unique display name, synchronization and compression. The original folder path remains usable, directly for NFS/SMB and through a managed symlink for new FSKit sessions. The physical mount retains the original folder basename; `--name` and `rename` set only the RAMNest display alias, which remains usable for CLI lookup. Minimum capacity is 16 MiB; maximum is 75% of physical memory. Close writers before the first conversion. Root/home/system directories, app sandbox storage, arbitrary symlink traversal, overlapping RAM folders, app-support nesting and foreign/nested mounts are rejected. The runtime FSKit link is a narrow journal-owned exception, not a relaxation of those checks.

Capacity must cover the uncompressed logical payload: each non-hardlinked file rounds up to 64 KiB, plus symlink and extended-attribute bytes. Compression does not lower this quota. Metadata has a separate `max(64 KiB, capacity / 4)` budget with no fixed 64 MiB ceiling; neither budget preallocates memory. For a roughly 55,000-entry tree with about 4.1 GiB of rounded payload, choose **8GB** (8 GiB) as a starting point: that allows 2 GiB of metadata, with room for attributes and growth subject to the existing 75%-of-RAM limit. Preflight errors report which budget failed, required/allowed bytes and entry counts before any files move.

Before changing the selected directory, RAMNest copies and checksum-verifies its contents into private local storage. Direct mounts move exact top-level entries into a 0700 sibling holding directory. New FSKit sessions instead move the complete original directory into that private wrapper's `data` child, preserving original objects while vacating the public path. With a negotiated `pre-mount-population-v1` helper, the coordinator pins the authenticated control identity, populates the **guarded tree before mounting**, then explicitly authorizes the mount. Its first callbacks therefore expose the populated namespace and root mode. RAMNest observes the physical mount identity, strictly verifies mounted data including xattrs/hardlinks, checks retained originals, publishes the bound FSKit symlink where applicable, journals verification, and only then enables writes. Older helpers retain their legacy ordering for direct mounts. Source files remain recoverable throughout. It does not use `hdiutil`, native RAM devices, tmpfs, or a disk mirror.

The sidebar displays all configured folders; detail shows logical allocation, capacity, file bytes, encoded payload and mapped backing. Options have Apply/Discard and unsaved-change guards. Compression and Finder visibility changes take effect on the next mount. Resize changes the live capacity without unmounting, including temporary mode, and rejects shrink below allocated usage. Names, paths and `ram://` percent-encoded names all work in the CLI.

Defaults: mount at app launch, `nobrowse`, synchronization and compression on; periodic save off, selected interval 15 minutes. Available intervals are 5/15/30/60/360/720/1440 minutes. Periodic saves are scheduled by the detached helper while it is alive, so they continue after a GUI crash. FSEvents suppression is unavailable: no unsupported mount option is advertised. Mounts explicitly select the recorded session backend and retain `namedattr,use_ino` and the ordinary rename callback. Production `renamex` remains omitted as a conservative wire-decoder workaround pending separate FSKit evidence; this omission does not select the backend. See the [complete callback matrix](docs/FUSE_COMPATIBILITY.md).

## Save, eject and recovery

Snapshot copies preserve existing `com.apple.quarantine` bytes along with other verified metadata, including on read-only files and directories. macOS's copy API can rewrite quarantine flags; RAMNest restores only the manifest-validated source value on its new private copy and restores the exact final permissions. It does not strip quarantine, invent approval flags, or change Gatekeeper settings. Verification failures identify a bounded entry path and differing field/attribute without exposing file contents or attribute values; source files remain untouched.

A save serializes against all RAM operations, exports a coherent tree, handles short writes/EINTR, syncs files, reads back allocated bytes against held RAM, verifies metadata/content, and atomically promotes an immutable revision. RAMNest normally keeps **only the latest verified committed snapshot per RAM drive** after a successful idle operation. While mounted, it also retains the initial snapshot needed for temporary eject/crash rollback and any active restore revision. Pending cleanup of completed-session originals also pins the snapshots needed to validate that cleanup. An older committed revision is retired only after the latest snapshot is verified and its journal is durable, under the repository lock. Snapshots are never overwritten in place. Periodic/manual saves update the private snapshot; **eject restores the committed snapshot to the selected folder**. In temporary mode, eject returns the original entries unchanged instead of saving RAM changes.

Eject freezes writes until unmount/restore completes; an unmount failure thaws a previously active tree. The GUI lists busy processes and offers Cancel/Ignore. It never force-kills applications. Normal Quit saves and ejects all mounted folders, offers Stay on failure, and uses the normal macOS termination callback; actual machine shutdown is deliberately not tested. Menu-bar mode keeps the app running after window close. A native status item handles this presentation outside the SwiftUI scene graph; the application delegate owns the single model and starts it once after launch. SMAppService registration is triggered only by the Open at Login setting.

The detached helper closes inherited descriptors and survives a GUI crash. A GUI restart reconnects by private per-session Unix socket and checks the mount device. When Finder, `diskutil`, or `umount` externally ejects the volume, the FUSE destroy callback **does not free the RAM tree**. After the FUSE loop exits, the helper invokes the bundled coordinator to export, commit and restore the held tree. On failure it retains memory and retries; a helper crash/power loss can preserve only the latest already committed local revision. A forced unmount may lose kernel-cached/unsubmitted writes. No claim is made to save after SIGKILL or power loss.

On an unclean session, startup auto-mount is gated before any snapshot can be replaced. Recovery refuses unknown files rather than guessing a merge. Active originals remain throughout mounted, temporary, crashed, uncertain and unfinished transactions. After verified restore/rollback and durable idle, exact journal-attributed sibling containers can be cleaned: normal-mode originals must still match the initial verified manifest; rollback holdings and recorded restore-stage data must be empty. A durable identity/manifest queue supports retry after partial cleanup and preserves required snapshot pins. Changed originals, unknown entries, incomplete stages, identity replacements and missing legacy provenance are retained with a nonfatal `cleanupWarning` in status JSON and stderr. Older journals remain readable; an attributed legacy holding with a valid recorded identity and initial snapshot can be cleaned at the next safe operation. Unreferenced legacy directories remain for manual inspection. Cleanup never guesses a historical purge or replaces a recovery error. See [recovery instructions](docs/RECOVERY.md). Configuration removal retains the remaining recovery storage.

```sh
# Use disposable data while validating a new build.
mkdir -p artifacts/example-folder
artifacts/ramnest create "$PWD/artifacts/example-folder" --size 256MB --name 'Fast Work'
artifacts/ramnest info 'ram://Fast%20Work' --json
artifacts/ramnest save 'Fast Work'
artifacts/ramnest resize 'Fast Work' --size 512MB
artifacts/ramnest unmount 'Fast Work' --ignore-busy
artifacts/ramnest delete 'Fast Work' --keep
```

Shared state defaults to `~/Library/Application Support/RAMNest`; use `--store PATH` for an isolated repository. `delete` defaults to keeping files. Removing the selected directory requires **both** `--destroy --confirm-delete`; durable snapshots remain retained. `export REF NEW_DIRECTORY [--revision UUID] [--live]` rescues snapshots/current RAM. CLI installation is explicit via the app's Install Command Line Tool action or `ramnest install-cli DIRECTORY`, and creates a launcher only in the chosen existing directory. No system installation or mandatory sudo occurs.

## Verification and distribution differences

See [historical host verification results](docs/VERIFICATION_RESULTS.md) for the executed NFS filesystem, real-memory/compression, temporary-file, Xcode and GUI/normal-Quit checks. These reports predate explicit FSKit selection and do not validate FSKit mounts. The selector has focused configuration, session, Settings-model and installed-libfuse parser coverage. Run `scripts/backend-selector-tests.sh` for these no-mount checks; products, fixtures and logs belong under `artifacts/backend-selector`. Host packaging, GUI interaction, extension activation and isolated backend mount validation remain separate checks in [backend settings and FSKit validation](docs/FSKIT_BACKEND.md). For disposable working data, turn **Save changes on eject** off: temporary eject restores the original folder without exporting RAM-only content to a local stage.

[FEATURE_MATRIX.md](FEATURE_MATRIX.md) records implemented, tested, deviation and unverified scope. [HOST_VERIFICATION.md](docs/HOST_VERIFICATION.md) gives exact parent-host mount, process-footprint, lifecycle and GUI checks. Automated tests use disposable fixtures, the real memory engine, real libfuse dispatcher and real subprocesses; they do not substitute a mock backend and call it mount proof. Logs are in `artifacts/logs`.

The operational reference was [RAM Folder's help center](https://less-software.sh/ram-folder/help-center), including its linked creation/options/synchronization/data-safety/mounting/memory/remote/CLI/troubleshooting pages. RAMNest has independent branding and code. Its deliberate differences include FUSE-T instead of tmpfs, no privileged helper or license/trial restriction, no telemetry/update server, local-only storage by user instruction, lossless in-place resize, stricter blocking recovery and supported metadata preservation. Snapshot retention is latest-only, with no history UI. It does not redistribute the reference help text or vendor assets. Source packaging explicitly excludes `docs/reference` captures.

Run `bash scripts/latest-snapshot-tests.sh green` for focused retention tests without mounts, native-helper builds, GUI operations or packaging. The compiler commands, RED/GREEN logs and owned fixtures are under `artifacts/latest-snapshot`. These coordinator fixtures exercise real snapshot/journal/deletion behavior through a controlled helper-session boundary; actual NFS verification remains a separate host check.

Run `bash scripts/holding-cleanup-tests.sh green` for completed-session sibling cleanup and the existing retention/recovery scenarios. Its RED/GREEN logs, compiler products and fixtures are under `artifacts/holding-cleanup`; the process uses a 96-descriptor limit and a 1 MiB stack. Xcode and live mount/distribution checks are separate parent-owned validation.
