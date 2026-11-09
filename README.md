# RAMNest — native macOS tmpfs folders

RAMNest keeps an existing folder at its usual path while its working files live
on the native macOS tmpfs filesystem. Ordinary reads and writes go directly to
the kernel. The default app/helper build has no FUSE-T, NFS, SMB, FSKit, custom
MemoryFS, LZ4 page engine or checksum-per-RAM-page dependency.

This migration targets macOS 27 and preserves the verified local snapshot,
original-holding, publication and recovery transactions. Source implementation
and static diagnostics are distinct from release acceptance: the parent owns
Xcode tests, exact-package administrator probes, GUI checks and host measurements.
See [delivery and pending verification](docs/NATIVE_TMPFS_MIGRATION.md).

## Working with folders

Choose an existing owned directory, a maximum capacity and synchronized or
temporary mode. RAMNest captures and verifies an initial checkpoint before moving
any original objects. An administrator-authorized helper creates an internal,
protected native mount slot. A symlink at the original folder path points to the
user data directory inside that mount; original objects remain in their
identity-bound private sibling holding until restoration/verified cleanup.

The physical layout is:

```text
/Users/Shared/RAMNestNative-<uid>/           root-owned 0755
  <session UUID>/                          root-owned 0755
    control.lock                          root-owned 0600
    mount/                                native tmpfs, root-owned 0755
      .fseventsd/                         OS metadata, outside the logical tree
      tree/                               user-owned 0700
        data/                             original logical root metadata

<original path> -> .../<session>/mount/tree/data
<original parent>/.ramnest-<folder>-<session>.original/data
```

Native mounts use `mount_tmpfs -e` to preserve distinct case-sensitive names.
Snapshots may remain on the selected local snapshot store, including an external
volume. Physical tmpfs mount slots use internal storage because measured external
SSD mounting returned `EPERM` even with administrator authorization.

- **Synchronized mode:** Save commits a verified checkpoint; eject makes a new
  checkpoint and restores the latest committed working tree to the original path.
- **Temporary mode:** eject returns the original directory objects and discards
  RAM changes. `export --live` can explicitly checkpoint and export current work.
- **Periodic save:** uses the same close-writers gate as Save, with administrator
  authorization as needed. It can fail while applications keep files mapped/open;
  the journal reports the error and leaves the prior committed checkpoint intact.
- **Relaunch:** reconnects to the ordinary-user pin helper. `reconnect REF` can
  repin a verified surviving native session without thawing. Explicit `mount REF`
  can resume that session; it never mounts over an uncertain session.
- **Snapshot selection:** Settings retains the existing safe snapshot-store move
  transaction. Every folder must be idle before moving storage.

## Close writers before saving

A read-only remount blocks normal writes, but the measured macOS kernel allows
pre-existing writable `MAP_SHARED` mappings to keep writing. RAMNest therefore
remounts read-only, checks exact tmpfs type/path/fsid and the real read-only flag,
and runs a privileged, filesystem-wide `lsof -nP -F pcftn +f -- MOUNT` scan.

The gate rejects every regular vnode reference in the logical user tree,
including numeric fds, read-only readers, `txt` mappings with no remaining fd,
and unknown/incomplete scan results. Warnings, nonzero status, timeout and an
unobserved scanner mount pin fail closed. OS-owned `.fseventsd` files at the
protected mount root are outside the logical tree. **Ignore Busy cannot bypass
this gate.** Failed saves invalidate old eject authority before attempting a
verified thaw; uncertainty retains a guarded mount and the previous checkpoint.

This is an accepted cooperative close-writers contract. Stop writers, close
mapped files and let the gate verify their absence. `lsof` enumeration is not
atomic mapping revocation against an adversarial process that hands references
between processes during inspection. RAMNest neither terminates writers nor
claims that stronger guarantee. Existing strict source-before/source-after,
independent-copy, metadata, hardlink and provenance checks remain in force.

## Memory and capacity

The mounted capacity is a maximum, not preallocated payload RAM. Kernel filesystem
allocation grows with written content and releases blocks after truncation and
deletion when no references retain them. The parent probe verifies those changes.
Changing the maximum on a live native mount is unsupported: a measured `-s` update
returned success without changing capacity. Resize rejects without changing the
persisted capacity; edit capacity while idle and mount again.

UI/JSON native usage and capacity come from actual `statfs`. They include kernel
filesystem metadata and are not physical RAM, process RSS, encoded payload or an
app compression ratio. Deprecated MemoryFS metrics are omitted from native JSON.
macOS controls memory compression and swap; RAMNest does not disable swap or
promise zero disk writes or secure erasure. See [memory accounting](docs/MEMORY.md).

## Administrator and recovery boundaries

Each privileged operation is a one-shot macOS administrator authorization. No
permanent root daemon, LaunchDaemon, service installation, SIP/TCC change or
credential handling is introduced. Root operations accept numeric identity
values, uid and canonical session UUIDs; their paths are derived under the fixed
runtime parent. They cannot execute arbitrary commands or access a snapshot
store. The session pin/control socket runs as the ordinary user.

External forced unmount destroys native RAM. A pin discourages ordinary external
unmount; it cannot defeat a force-unmount or power loss. RAMNest never exports a
vanished native tree or silently saves a stale disk checkpoint as current RAM.
Explicit recovery restores only the latest committed checkpoint (or intact
original objects in temporary mode) and retains a clear loss disclosure.
See [recovery](docs/RECOVERY.md) and [security](SECURITY.md).

Old configurations, journals and snapshot formats remain decodable. Legacy
backend/compression fields are preserved as history, never relabeled as native.
Native RAMNest will not control a live legacy FUSE session; finish it using its
original version or recover a committed checkpoint after that known mount is
gone. Unknown, malformed, mixed or partial authority fails closed.

## CLI

Use the CLI embedded in the exact candidate app:

```sh
"/absolute/candidate/RAMNest.app/Contents/Helpers/ramnest" --help
"/absolute/candidate/RAMNest.app/Contents/Helpers/ramnest" --store /absolute/new-owned/store create /absolute/owned/source --size 128MB --no-mount
"/absolute/candidate/RAMNest.app/Contents/Helpers/ramnest" --store /absolute/new-owned/store mount NAME
"/absolute/candidate/RAMNest.app/Contents/Helpers/ramnest" --store /absolute/new-owned/store save NAME
"/absolute/candidate/RAMNest.app/Contents/Helpers/ramnest" --store /absolute/new-owned/store unmount NAME
```

`--store` is optional in ordinary use; omitting it uses the configured snapshot
location. Always supply a new explicit store during candidate tests. `list --all
--json`, `info`, `options`, `recover`, verified checkpoint `export`, `export --live`,
offline `resize`, rename, keep/delete and launcher installation remain available.
No compression/backend selector is offered for new mounts. Deletion still needs
its explicit destructive confirmation; tests use disposable fixtures only.

## Build and verify

The established `project.yml` workflow is the source of Xcode source membership:

```sh
xcodegen generate --spec project.yml
# Parent: open THIS worktree project, then BuildProject/GetTestList/RunAllTests.
```

Core's prebuild first compiles/signs `Native/NativeTmpfsHelper.cpp`, then generates
its final SHA-256/engine/configuration as Swift source compiled into RAMNestCore.
The GUI and embedded CLI link that Core before the app embeds the exact same
helper/provenance. No mutable manifest supplies the expected runtime hash. Missing
authority fails compilation; use this XcodeGen workflow or `scripts/build.sh`.
Raw SwiftPM/standalone compiler invocations must include the generated identity
source from the same finalized helper; there is no missing-authority fallback.
CMake's default
has no FUSE dependency. The former engine, callbacks, protocol fixtures and benchmarks are removed.
Only persisted data compatibility readers and data fixtures remain.

Parent-only no-mount and exact-package gates:

```sh
python3 -B scripts/native-production-static-tests.py
python3 -B scripts/package-provenance-tests.py /absolute/owned/scratch
bash scripts/test.sh /absolute/new-owned/native-test-output
python3 -B scripts/native-tmpfs-package-probe.py \
  --app /absolute/NEW-Xcode-candidate/RAMNest.app \
  --scratch-parent /absolute/owned/scratch --ack-admin-prompts
# Optional explicit loss test on an additional fresh fixture created by the probe:
# add --force-loss
```

The exact-package probe creates two independent source/store fixtures, runs two
mount/write/save-or-live-export/eject cycles per mode (including remount), tests
the fd-closed mapping guard with Ignore Busy, rejects live resize without changing
configuration, verifies metadata/sparse data/original inodes/cleanup, and measures
allocation growth/truncation/deletion at fixed capacity. It records raw `vm_stat`
context separately, without claiming isolated physical RAM attribution.
On failure it retains evidence and the exact owned slot; it performs no automatic
force-unmount or broad cleanup. A successful source/static check is not a claim
that these unrun runtime gates passed.

Further details: [native backend/protocol](docs/NATIVE_TMPFS.md),
[file verification](docs/FILE_VERIFICATION.md),
[snapshot storage](docs/SNAPSHOT_STORAGE.md),
[provenance copy policy](docs/PROVENANCE_COPY_POLICY.md).
Obsolete engine requirements and reports have been removed. Legacy on-disk
discriminators remain readable without an executable old storage backend.
