# Proven parent-host integration fixes (apply to product)

Parent built and ran real FUSE-T mounted tests outside coding sandbox using frozen artifacts and a separate scratch helper source. These are observed findings with a passing combined workaround, not hypothetical suggestions. Production source has NOT been edited by parent.

## Required product changes

1. Add explicit **namedattr** mount option. Installed go-nfsv4 1.2.9 default is false. Without it, source `com.apple.provenance` xattr is retained inside tree but invisible from mounted NFS; full population manifest comparison fails. Actual mounted data/mode/nanosecondmtime match, but xattrs empty. Forcing `namedattr` exposes xattrs and both startup verification and xattr CRUD pass. Don't skip provenance verification as workaround.
2. Add **use_ino** mount option so FUSE respects Node::ino. Without it, hardlink paths get different exposed inode numbers; source hardlinks cannot pass population manifest checks. With use_ino, st_ino matches and st_nlink>=2.
3. **Leave renamex UNREGISTERED in the installed NFS bridge path.** Native renamex implementation may remain for direct unit coverage/possible future backend. Registering it corrupts NFS rename decoding in installed bridge/libfuse. Actual trace on `rename /file -> /renamed` was `renamex /amed -> / flags=1701603686 = -45`: flags are bytes from filename, and paths are shifted. Omitting `ops.renamex` preserves ordinary `ops.rename` and host rename succeeds. Do NOT attempt to repair garbage filenames in callback. Document SDK implementation versus safely enabled NFS transport callbacks and honest ENOTSUP behavior for extended flags. Adapt callback matrix/check/tests to distinguish native implementation from production bridge registration.

## Passing host fixture

Scratch source `/Volumes/WDBlack4TB/.hermes/cache/scratch/ramnest-namedattr-probe/{Helper.cpp,MemoryFS.cpp,MemoryFS.hpp}` is a snapshot of your source plus exact opts `,noattrcache,namedattr,use_ino` and omitted `ops.renamex` registration. It includes temporary rename logging; do NOT copy that instrumentation into production.

Passing report `/Volumes/WDBlack4TB/.hermes/cache/scratch/ramnest-host-operations-legacyrename/report.json`: 19 checks PASS, no unsupported checks: same-path actual mount, create/open/write/read, pread/pwrite, getattr, append, truncate zero-fill, hardlinks inode/nlink, symlink/readlink, rename hardlink, chmod, chown self, utimens, xattr CRUD, directories/readdir/unlink/rmdir, flush/fsync/fsyncdir, statfs, mmap, ENOSPC/reclaim, saved after eject. (Count programmatically if quoting; report is authority.) All test volumes unmounted and source data safe.

Failure fixtures: ramnest-host-operations-second/population-mismatch.json shows provenance issue; ramnest-host-operations-namedattr/report.json hardlink issue; scratch probe rename-trace.log shows corrupted renamex wire arguments. Parent native compression test artifacts/parent-native-compression.json also PASS: 128MiB repeated content mapped32MiB vs random128MiB mapped128MiB, truncation and deletion reclaim verified via mach RSS.

Integrate the three transport changes, update tests/docs and rebuild stable app. Continue all remaining unit/integration scripts/docs/packaging. Parent will rerun own full mounted random-memory, real-time compression and GUI/quit tests on final package. Do not bypass sandbox or modify global FUSE-T config.
