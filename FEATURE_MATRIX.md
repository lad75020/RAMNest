# RAMNest feature and verification matrix

**Historical host results:** [VERIFICATION_RESULTS.md](docs/VERIFICATION_RESULTS.md) records the completed mounted filesystem, physical memory/compression, recovery, Xcode and GUI/normal-Quit checks. It supersedes earlier pending rerun labels below for those verified workflows, but does not validate the new backend selector or FSKit/SMB mounts.

Scope: macOS 27.0+, Apple Silicon, FUSE-T with app-wide NFS/FSKit/SMB3 selection (NFS default), local-only persistence. Remote/S3 was explicitly removed by the user in LOCAL_ONLY_SCOPE.md. “Native” means executed against the real C++ engine/installed libfuse dispatcher; “Swift/CLI” means executed with real disposable files/processes. “Parent probe” means the separately frozen host helper plus the three now-integrated transport corrections, not a final-package GUI certification. Parent frozen-release reports additionally record 62 PASS checks: 19 operations, 17 memory/lifecycle, 11 compression and 15 failure/recovery; those reports predate the GUI lifecycle correction. Final host rerun commands are in [HOST_VERIFICATION.md](docs/HOST_VERIFICATION.md).

| Feature / contract | Implemented | Tested | Deviation / limits | Unverified |
|---|---|---|---|---|
| Independent native app/core/CLI/helper | Yes | Direct Swift/CMake debug build; app packaging | No third-party dependencies downloaded | Final GUI workflow |
| macOS27.0 minimum everywhere | Yes | Build target/plist/package specs | Apple Silicon artifact only | Intel build |
| Multiple named RAM folders | Yes | Eight real concurrent CLI creators | Global repository lock serializes transactions | GUI multi-folder display |
| Unique case-insensitive names | Yes | Swift/CLI duplicate rejection | Unicode uses Foundation case comparison | Locale edge cases |
| Name/path/UUID/percent-encoded ram:// references | Yes | Swift/CLI | Path references use persisted current path | Host bookmark relocation |
| Shared app/CLI state and locking | Yes | Concurrent CLI subprocesses | Coarse lock may delay other operations during large copies | Multi-GUI-instance workflow |
| Folder chooser, drag/drop, Dock/Open With | Yes | App compiles | Existing directories required; CLI does not auto-create source | Host UI input paths |
| Creation sheet name, MB/GB, sync/compression | Yes | CLI/size preflight tests; UI builds | Conservative source allocation estimate | UI validation display |
| Root/home/system path rejection | Yes | Swift | Normal user-owned data locations only | Every protected host location |
| Containers/Group Containers, support nesting | Yes | Validation implementation and overlap tests | Fails before conversion | TCC-protected folders |
| Symlink traversal, nested/foreign mounts rejection | Yes | Swift symlink/overlap; live mount enumeration | No bypass of macOS protections | Host nested foreign-mount fixture |
| Source too large rejected before moves | Yes | 257 tiny-file preflight regression | 64 KiB slots charge each independent file; sparse estimate conservative | Large host sparse source |
| Follow moved/renamed folders by bookmark+identity | Yes, at mount | Bookmark creation executed | Uncertain identity blocks; path refresh occurs on mount | Host move/rename resolution |
| Sidebar status/detail/capacity/reveal | Yes | Compiles | Phase/progress text, not per-file percent | Host visuals/accessibility |
| Name editing and live resize | Yes | CLI rename/resize; native shrink rejection | Resize does not remount; temporary mode remains lossless | Final mounted statfs refresh |
| Mount/eject/save/delete/recover/export | Yes | Swift state/recovery, CLI, native; parent probe eject | Configuration removal retains recovery storage | Final package lifecycle |
| Responsive native UI and error/progress | Yes | Debug build plus headless lifecycle/command-metadata regression | Delegate-owned/deferred startup; native status item outside AppGraph | Parent must confirm corrected Debug/Release window launch and interaction |
| App-wide backend for next mount | Yes | Legacy configuration/strict decoding, persistence/readback, session capture, Settings model and installed-libfuse option parser | Running helpers unchanged; legacy live backend stays unknown; SMB loopback/no Bonjour; no fallback | Parent package/GUI/backend mount probes; FSKit external-volume EPERM unresolved |
| Menu-bar/Dock mode | Yes | Headless persistence and idempotent lifecycle tests; builds | Native NSStatusItem avoids observed SwiftUI scene insertion; Dock close uses normal quit callback | Corrected host behavior |
| Startup mount and unclean recovery gate | Yes | Explicit gate regression | Any unfinished disconnected session pauses startup mounts | Login launch |
| SMAppService Open at Login | Yes | Compiles | User action only; no tests register it | Host opt-in workflow |
| System memory bar | Yes | Builds | Active+wired+compressor estimate | Host rendering/values |
| Normal/Advanced Apply/Discard safeguards | Yes | Builds | Native dialogs on selection/mount/eject/quit | Host interaction |
| Defaults and interval choices | Yes | CLI options/default assertions | Detached helper performs periodic saves even with GUI absent | Actual 5-minute schedule |
| FSEvents suppression | Explicitly unsupported | UI/CLI explain limitation | No unsupported FUSE option sent | Watcher behavior depends on bridge |
| Size+mtime/checksum comparison | Yes | Snapshot verification tests | All promoted revisions checksum-verified; export from RAM is full, not a delta stream | Performance at scale |
| True detached in-process RAM storage | Yes | Native engine; parent actual mount | Anonymous pages remain subject to OS swap | Final helper crash-survival rerun |
| Lazy backing grows/shrinks with content | Yes, mmap/munmap | Mach RSS random/truncate/unlink test; independent parent native test | Metadata/workspace/kernel overhead separate | Final mounted RSS rerun |
| Real-time compression/default-on option | Yes, system LZ4 | Native roundtrip/random/partial/corrupt/concurrent; CLI persistence | 64 KiB logical blocks; next-mount setting; raw fallback | Final mounted compressed remount |
| Separate logical/content/payload/mapped/savings metrics | Yes | Native counters/RSS and CLI JSON | Backing counters are not RSS | GUI presentation |
| Sparse offsets/truncation/overflow | Yes | Native and parent probe | 4 MiB individual callback I/O request bound | Extreme host offsets |
| ENOSPC/statfs ceiling/reclamation | Yes | Native and parent probe | Uncompressed allocated slots plus attribute/target content | Final package mounted stress |
| Rename, symlink, hardlink, open-unlink lifetime | Yes | Native/dispatcher and parent probe | Production renamex disabled for broken NFS wire decoder | Extended-flag host requests |
| Modes/ownership/timestamps/xattrs | Yes | Native/Swift and parent probe | Ownership current uid/gid; backup/change/birth dates not fully durable | Backend timestamp coalescing |
| Thread safety and metadata quota | Yes | Native concurrent writes/quota sentinel | 64 KiB–64 MiB metadata budget, fixed handle/inode caps | Long-running stress |
| Full installed SDK callback matrix | Yes, all 57 | Automated header/table/registration agreement | 51 native, 50 production registrations; unsupported reasons explicit | Individual bridge reachability |
| Post-mount population at same emptied path | Yes | Parent corrected probe; native guarded-state design | Writes enabled only after mounted manifest and retained-original verification | Final packaged helper rerun |
| Verified private snapshot before moves | Yes | Swift real snapshot roundtrips/failure tests | Original sibling copy retained beyond verification | Power failure during fsync |
| Exact-entry evacuation/no-follow safety | Yes | Anchored no-replace/symlink substitution regressions | Malicious same-uid/admin code outside threat model | Filesystem hostile race stress |
| Rollback every known pre-mount failure | Yes | Failed executable launch regression | Uncertain spawned mounts remain gated rather than guessing | Host mount timeout timing |
| Original copy retained through population | Yes | Swift fixture and journal | Retained recovery storage requires manual cleanup | Concurrent original-writer host fixture |
| Source write race checks and mounted identity | Yes | Snapshot checks; negative-fsid and descriptor tests | Close source writers before conversion; uncertain writes block | Host adversarial writers |
| Coherent save/frozen eject/no post-snapshot write loss | Yes | Native freeze/export, parent probe eject | Accepted writes serialized; kernel-unsubmitted writes outside guarantee | Final concurrent mounted eject |
| Durable journal/pending-restore authority | Yes | Swift restore, conflict and unclean gate regressions | One private JSON journal per volume | Actual power cut excluded |
| Atomic immutable revisions/latest-only retention | Yes | Behavioral RED/GREEN owned-directory tests: repeated saves, anchors, journal/cleanup failures, corruption and symlinks | Mounted rollback/restore anchors retained until idle; unknown or damaged recovery data preserved | Parent host NFS cycle and full-disk production recovery |
| Save failure retains RAM and recoverable files | Yes | Injected short/EINTR/zero export, corrupt-block tests | External helper retries failed finalization | Host disk-full export |
| Sync off preserves original folder | Yes | Swift original-inode temporary recovery | Explicit live export can rescue temporary data | Final mounted temporary cycle |
| Clean GUI quit save/eject with Stay/Cancel | Yes | Compiles | No forced application termination or actual shutdown test | Parent GUI/quit checks |
| External eject while GUI absent | Yes | Parent probe saved-after-eject | Helper tree retained after destroy; failures keep memory and retry | Final package Finder/diskutil/umount |
| GUI crash survival/reconnect | Yes | Detached architecture and socket identity | Helper crash loses unsaved RAM | Parent actual GUI force-quit |
| Busy process detection/Cancel/Ignore | Yes | CLI route builds | No automatic app termination; user closes writers | Host lsof/UI confirmation |
| Unexpected helper termination recovery | Yes | Swift journal-based crash simulation | Latest durable revision only; orphan mount needs host unmount | Parent explicit disposable SIGKILL check |
| Power loss/forced eject limits documented | Yes | Docs reviewed | No impossible unsaved-data guarantee | Actual host shutdown deliberately excluded |
| S3/remote/providers/signing/credentials | Intentionally excluded | No remote model, storage or CLI commands | Explicit latest user instruction: local only | Not applicable |
| Headless help/version/list/info/create/actions | Yes | Real CLI tests | Existing folder required | Final mounted CLI suite |
| Delete keep default and explicit destructive confirmation | Yes | CLI confirmation/keep tests | Durable revisions/originals retained | UI delete dialogs |
| Snapshot export/recover and JSON/actionable codes | Yes | Swift/CLI | Removed configurations require direct retained-directory rescue | Host damaged-storage recovery |
| Explicit user-selected CLI install | Yes | Real launcher/version/reinstall rejection | No automatic system installation | GUI panel |
| Build/test/package scripts and Xcode specification | Yes | Direct builds/tests; parent Xcode build and 1/1 XCTest passed with preserved fixture/settings | Direct script is packaging path; parent Xcode generation/build evidence is separate | Corrected GUI Xcode rerun and host SwiftPM |
| App/CLI/zip/source delivery | Yes | Package/signature/plist/archive checks | Ad-hoc development signing; FUSE-T external | Notarization deliberately absent |
| Vendor trial/license/telemetry/updater differences | Yes | No such endpoints/code | Independent branding; reference help text excluded from delivery | Not applicable |
