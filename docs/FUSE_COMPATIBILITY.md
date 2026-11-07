# FUSE-T callback compatibility

Minimum platform: macOS 27.0, Apple Silicon. Inspected installed FUSE2 `struct fuse_operations` from `/Library/Application Support/fuse-t/include/fuse/fuse.h` (FUSE-T 1.2.9). All 57 callback fields, including Apple extensions and reserved slots, are listed below. The SDK also has bitfield capability flags; `flag_nullpath_ok` and `flag_utime_omit_ok` are enabled, reserved bits remain zero.

Native tests exercise the real memory engine and the installed libfuse stacking dispatcher, without claiming a kernel mount. Historical parent host report `ramnest-host-operations-legacyrename/report.json` separately records 19 passing NFS mounted checks on a frozen helper plus the three bridge corrections integrated here. Those results predate explicit FSKit selection and are not FSKit validation. The selectable-backend helper requires a host build and isolated validation of each backend; FSKit also requires extension activation. See [backend settings and FSKit validation](FSKIT_BACKEND.md). No sandbox mount proof is implied.

Production options include exactly one recorded `backend=nfs`, `backend=fskit`, or `backend=smb`, followed by the retained `noattrcache,namedattr,use_ino`, plus optional `nobrowse`. SMB additionally forces `listen_addr=127.0.0.1:0,nobonjour`. App Settings apply to new sessions only; legacy configuration and direct helper calls with no backend use NFS, and malformed backend values reject. The original folder's escaped `volname` and full mountpoint remain unchanged. Backend choice is explicit per mount with no retry with another backend and no change to global FUSE settings. Named attributes and inode identity were required by the earlier NFS validation and remain enabled; their FSKit transport behavior needs host verification.

Production still omits `renamex` conservatively because of the previously observed NFS wire-decoder argument shift. This change provides no new evidence about FSKit's extended-rename decoder and does not enable that callback. The historical `operations(bool productionNFSBridge)` parameter only controls this omission; it is not a backend selector. Native extended-rename implementation and tests remain. The table describes callback registration, not demonstrated FSKit host reachability; NFS-specific observations below are historical.

`backendOperations` separately adapts FSKit's `listxattr`: only a genuine zero-byte result from the existing callback becomes `-ENOATTR`. NFS and SMB retain standard zero-byte success. This is an explicit-absence compatibility workaround for the parent's owned FUSE-T FSKit fault-injection result: zero-byte success surfaced as persistent Darwin EIO, while `-ENOATTR` preserved errno 93. It does not repair the upstream successful-empty-list contract or claim Darwin returns zero. No NUL sentinel or invented attribute is added. Snapshot accepts ENOATTR only on the first size query (alongside ENOTSUP); all other errors, second-list errors/races and exact manifest/hash checks remain fatal or mismatched as before. Fixture RED/GREEN evidence is under `artifacts/eio-fix/compatibility`; actual mount validation remains with the parent.

| Callback | Native registration | Production registration | Status / tests | Behavior / limits |
|---|---|---|---|---|
| `getattr` | yes | yes | Implemented; native tested | Modes, identity, hardlink nlink, uncompressed size, logical blocks, timestamps and supported flags. |
| `readlink` | yes | yes | Implemented; native tested | Stored targets are returned without traversing them. Symlinks may point outside the volume; snapshots never follow them. |
| `getdir` | no | no | Deprecated | Deprecated SDK interface; readdir/opendir provide the supported path. |
| `mknod` | yes | yes | Implemented; native tested | Regular files only; devices, sockets and FIFOs return ENOTSUP. |
| `mkdir` | yes | yes | Implemented; native tested | Owned directories, node/namespace quota, frozen-write guard. |
| `unlink` | yes | yes | Implemented; native tested | Reclaims backing when final link and open handle disappear. |
| `rmdir` | yes | yes | Implemented; native tested | Rejects nonempty directories and root; directory lifetime follows handles. |
| `symlink` | yes | yes | Implemented; native tested | Target length capped at 4096 bytes, capacity charged; no traversal during snapshot operations. |
| `rename` | yes | yes | Implemented; native tested | Atomic pathname move/replacement; prevents directory cycles. Production retains this ordinary callback while renamex remains omitted. |
| `link` | yes | yes | Implemented; native tested | Hardlinks share one inode and data; link count and allocation lifetime are retained. |
| `chmod` | yes | yes | Implemented; native tested | Permission bits updated; frozen mutation rejected. FUSE-T mount has nosuid semantics. |
| `chown` | yes | yes | Implemented; native tested | Current uid/gid or unchanged only; EPERM for unsupported ownership changes. |
| `truncate` | yes | yes | Implemented; native tested | Sparse growth; partial-block suffix cleared before shrink commit; munmap reclaims full blocks. |
| `utime` | no | no | Deprecated | Deprecated SDK interface; utimens supplies nanosecond timestamps. |
| `open` | yes | yes | Implemented; native tested | Read/write permissions, O_TRUNC, O_APPEND handle state, lazy backing; direct I/O requested. |
| `read` | yes | yes | Implemented; native tested | Decodes only requested 64 KiB blocks; sparse holes zero-fill; corrupt backing returns EIO. |
| `write` | yes | yes | Implemented; native tested | Offset/append-safe, staged LZ4 block rewrite, raw fallback, uncompressed ENOSPC and overflow guards. Individual request limit 4 MiB. |
| `statfs` | yes | yes | Implemented; native tested | Capacity and free space use uncompressed allocated 64 KiB block slots plus attribute/target bytes, not compressed length. |
| `flush` | yes | yes | Implemented; native tested | Validates open handle. RAM content is coherent; this is not a durable disk save. |
| `release` | yes | yes | Implemented; native tested | Closes and releases handle ownership; final unlinked inode backing unmapped. |
| `fsync` | yes | yes | Implemented; native tested | Validates handle and synchronizes in-memory operation ordering. Explicit save is required for durable local storage. |
| `setxattr` | yes | yes | Implemented; native tested | CRUD flags CREATE/REPLACE, 1 MiB bound, capacity/metadata quotas; ResourceFork position writes supported. |
| `getxattr` | yes | yes | Implemented; native tested | Size query and ERANGE; ResourceFork positional reads, invalid other offsets rejected. |
| `listxattr` | yes | yes | Implemented; native tested | NUL-separated names, size query and ERANGE. |
| `removexattr` | yes | yes | Implemented; native tested | ENOATTR for missing values, frozen-write guard. |
| `opendir` | yes | yes | Implemented; native tested | Bounded stable per-handle name snapshot for readdir offsets. |
| `readdir` | yes | yes | Implemented; native tested | Directory handle offsets respected; filler gets restart cookies; null handle path supported. |
| `releasedir` | yes | yes | Implemented; native tested | Validates directory handle and releases name snapshot. |
| `fsyncdir` | yes | yes | Implemented; native tested | Validates directory handle; no claim of durable snapshot creation. |
| `init` | yes | yes | Implemented; native tested | Signals mount readiness; source content remains absent and writes guarded until controlled population/verification. |
| `destroy` | yes | yes | Implemented; native tested | Signals unmount without destroying the RAM tree; detached helper saves/restores before retiring. |
| `access` | yes | yes | Implemented; native tested | Owner permission bits and frozen-write guard. Historically the NFS bridge normally handled access without dispatching this callback; FSKit reachability unverified. |
| `create` | yes | yes | Implemented; native tested | Atomic create/open with bounded handles, direct I/O and no payload preallocation. |
| `ftruncate` | yes | yes | Implemented; native tested | Same semantics through retained file handle after unlink; extended-setattr dispatcher tested. |
| `fgetattr` | yes | yes | Implemented; native tested | Handle identity survives rename/unlink; invalid handles return EBADF; null path accepted. |
| `lock` | yes | yes | Unsupported; error tested | ENOTSUP; historically FUSE-T NFS performed native macOS advisory locking outside callbacks. FSKit lock behavior unverified. |
| `utimens` | yes | yes | Implemented; native tested | Nanosecond validation, UTIME_NOW and UTIME_OMIT; backend can coalesce atime/mtime. |
| `bmap` | yes | yes | Unsupported; error tested | ENOTSUP; anonymous memory has no backing block device. |
| `ioctl` | yes | yes | Unsupported; error tested | ENOTSUP; the earlier NFS bridge did not transport ioctls. No FSKit ioctl support is claimed. |
| `poll` | yes | yes | Unsupported; error tested | ENOTSUP; poll handle is destroyed, no readiness notification protocol claimed. |
| `write_buf` | no | no | Fallback tested | Unregistered intentionally: real libfuse falls back to write. No ENOTSUP buffer stub suppresses normal I/O. |
| `read_buf` | no | no | Fallback tested | Unregistered intentionally: real libfuse falls back to read. Native dispatcher regression proves this path. |
| `flock` | yes | yes | Unsupported; error tested | ENOTSUP; earlier NFS bridge owned local flock semantics. FSKit lock behavior unverified. |
| `fallocate` | yes | yes | Unsupported; error tested | ENOTSUP; eager allocation conflicts with lazy content backing. No FSKit allocation support is claimed. |
| `reserved00` | no | no | Reserved | Reserved ABI slot. Must remain null. |
| `reserved01` | no | no | Reserved | Reserved ABI slot. Must remain null. |
| `renamex` | yes | no | Implemented; native tested | Native ordinary/exclusive/swap implemented and tested. Production omission retained from the NFS wire-decoder workaround pending separate FSKit evidence. This does not select a backend. |
| `statfs_x` | yes | yes | Implemented; native tested | Apple extended capacity/statistics and RAMNest filesystem name. |
| `setvolname` | yes | yes | Unsupported; error tested | ENOTSUP; changing a local string cannot rename the live volume. App configuration name is editable. |
| `exchange` | yes | yes | Unsupported; error tested | ENOTSUP; Apple data exchange is distinct from pathname swap. Never misreported as supported. |
| `getxtimes` | yes | yes | Implemented; native tested | In-RAM birth/backup times. Backup/change-time persistence is not promised by snapshot format. |
| `setbkuptime` | yes | yes | Implemented; native tested | Validates/stores backup time in RAM; no persistent backup-time guarantee. |
| `setchgtime` | yes | yes | Implemented; native tested | Validates/stores change time in RAM; normal later writes update it. |
| `setcrtime` | yes | yes | Implemented; native tested | Validates/stores birth time in RAM; snapshot verification does not promise exact creation dates. |
| `chflags` | yes | yes | Implemented; native tested | UF_HIDDEN and UF_NODUMP only, preserved through native export/import and manifest verification. UF_IMMUTABLE/UF_APPEND and system flags return ENOTSUP. |
| `setattr_x` | yes | yes | Implemented; native tested | Atomic validated compound mode/ownership/size/timestamps/flags; errors leave last valid blocks intact. |
| `fsetattr_x` | yes | yes | Implemented; native tested | Same operation through retained handle, including null-path size change after unlink. |

The native `CallbackTests.cpp`, `MemoryTests.cpp`, `CompressionTests.cpp`, and `FootprintTests.cpp` cover behavior, real dispatcher fallback, errno boundaries, quotas, frozen writes, flags and compression/reclamation. `ControlTests.cpp` checks exact options through the installed libfuse parser, including each backend, the NFS default, strict invalid-value rejection, SMB loopback/no-Bonjour options, and no injected backend/listen/Bonjour options from punctuation in volume names. `check-callbacks.py` compares this entire table against the installed header and both registration sets. Earlier NFS transport limitations do not establish FSKit behavior. SDK presence and native dispatcher tests are not host transport promises. See [FUSE-T developer wiki](https://github.com/macos-fuse-t/fuse-t/wiki).

Payload is compressed with Apple's system Compression API (`compression.h`, linked through system `libcompression`). Files use 64 KiB logical blocks backed by anonymous mappings rounded to 16 KiB pages; encoding is selected only when it saves actual pages. Corruption is detected during decode and reported as EIO. `fsync` orders RAM writes; it cannot make volatile storage survive power loss. Only explicit/periodic save and successful eject commit a verified on-disk revision.

### Mounted BSD flag hints

Post-populate readiness permits only missing `UF_HIDDEN` (32768) and
`UF_NODUMP` (1) in the FUSE-T FSKit/NFS mounted view. Native callbacks report
these flags, but the demonstrated kernel views omit them. The prepared session
journal selects this policy; changing the current backend preference does not.
SMB and direct readiness callers remain strict. Added flags, every other missing
flag, and all remaining manifest fields still fail verification and keep RAM
writes guarded. Hidden files may therefore appear in the mounted view, and the
mounted view may omit the no-dump hint.

Snapshots and restoration retain raw flags where supported; source, holding and
snapshot comparisons do not apply the mounted-view exception. This policy has
fixture-only coverage in `bash scripts/mounted-flag-policy-tests.sh green`.
Fresh owner-authorized mounted lifecycle checks remain required before claiming
that an actual folder is fixed.
