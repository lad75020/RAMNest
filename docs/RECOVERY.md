# Native and legacy checkpoint recovery

Stop writers and inspect `info REF --json`. Never replace a checkpoint from an
empty, stale or uncertain mountpoint. Always use the appropriate selected store;
parent tests must pass a fresh explicit `--store` on every command.

```sh
/absolute/candidate/RAMNest.app/Contents/Helpers/ramnest --store /absolute/owned/store list --all --json
/absolute/candidate/RAMNest.app/Contents/Helpers/ramnest --store /absolute/owned/store info REF --json
```

## Native sessions

Native authority is recorded in `nativeTmpfs` and version-2 `nativeLink`, with the
session uid, actual tmpfs fsid, root/data/underlying reservation identities and
original-path link transaction. A native mount lives at the fixed internal slot;
the public folder is its journal-bound link. `.fseventsd` is outside the logical
user data tree. Unknown types/fsids, changed links/parents/inodes or nested mounts
block save/eject/recovery rather than adopting a substitute.

If the exact native mount still exists, use Save/Eject with writers closed. A
surviving ordinary-user pin can reconnect after GUI relaunch. `reconnect REF`
repins an otherwise verified mounted session without thawing or creating another
mount. An explicit `mount REF` can thaw that verified session after invalidating
stale quiescence authority.
An unverified/guarded population cannot be activated by guessing; use managed
eject/recovery and retain the initial snapshot/original objects on uncertainty.

Save and synchronized eject remount read-only, verify the kernel identity/flag,
and require a complete root mapping/reference scan. The gate rejects regular
file fds and mappings, including `txt` mappings whose fd is already closed. Ignore
Busy cannot bypass it. On failure, no new current-RAM checkpoint is promoted;
old eject authority is invalidated durably before a verified thaw. If state or
journal durability is uncertain, RAM remains guarded. See the
[close-writers contract](NATIVE_TMPFS.md).

**External forced unmount destroys native RAM.** A native helper does not retain
an independently exportable tree after unmount. The pin discourages ordinary
external unmount but does not defeat force-unmount, kernel failure or power loss.
Automatic finalization refuses to fabricate a new export when the managed frozen
checkpoint receipt is absent. Explicit `recover REF` restores the latest verified
committed disk checkpoint and records a persistent `lossDisclosure`; unsaved work
cannot be recovered. Temporary mode instead returns intact original directory
objects. `export --live` fails when the bound native tree is absent; `export`
without `--live` clearly exports only a committed disk revision.

```sh
ramnest --store /absolute/owned/store export REF /absolute/NEW-recovery-directory
ramnest --store /absolute/owned/store export REF /absolute/NEW-live-directory --live
ramnest --store /absolute/owned/store recover REF
```

After managed unmount, disk publication resumes from the already committed
checkpoint or original holding. The selected directory's restored inode/bookmark
is committed before idle, and only the exact empty native runtime reservation is
released. An interrupted verified publication can resume by its recorded
identities. Lost administrator replies, an orphaned mount without committed fsid,
an unrecorded slot, substituted authority, inaccessible final modes or incomplete
materialization can require explicit host inspection/manual recovery. No path is
adopted just because its basename resembles a session. Do not edit journals or
force-unmount a user volume to make a recovery check pass.

`nativeTmpfs.managedUnmount` is committed only after an acknowledged bounded
unmount and verified absence. A prepared eject/checkpoint receipt alone does not
authorize automatic restoration after disappearance. A crash before recording
the unmount acknowledgment can therefore require explicit recovery and a loss
disclosure even if the unmount itself completed.

## Shared snapshot and holding safeguards

The default file policy is SHA-256. Each revision/session records its immutable
[file verification policy](FILE_VERIFICATION.md); size/mtime can miss same-size
edits with restored modification time. A new preference cannot reinterpret old
revision authority.

`volumes/UUID/journal.json` records phase, current/initial/restore revisions,
population authority, original/restore publication receipts, staging identities,
cleanup candidates and errors. Revision containers preserve their established
manifest/mode-map/private-storage formats. Source capture and independent
verification precede original moves. Whole original directories remain inside
`.ramnest-FOLDER-SESSION.original/data` while linked; temporary restoration returns
the original inode instead of copying stale disk contents over it.

Latest-only retention is unchanged: retain the latest verified checkpoint and
transaction/rollback/holding anchors while needed. Only journal-referenced
committed revisions can be retired after durable replacement. Cleanup validates
owned no-follow directory handles, devices, selected/holding content, inode maps
and the recorded provenance/copy policy before descriptor-relative unlinking.
Unknown entries, changed originals, opaque excluded Trash subtrees, damaged
snapshots and unverified stages are retained with a separate warning. There is
no history-wide scan or automatic purge. Failure/uncertainty phases do not prune.

An export destination must be new. If the latest checkpoint is damaged or an
original holding changed, preserve every journal/snapshot/holding before manual
comparison. A revision explicitly retired by latest-only retention is not promised
as history. Backup ACL equality remains outside the acceptance contract, while
ownership, content, mode, metadata, topology and cleanup safety stay enforced.
Recovery never overwrites an unrelated original-path entry or follows an unknown
symlink. Resolve conflicts manually after a verified export.

## Legacy sessions

Old NFS/SMB/FSKit journals, version-1 `fsKitLink`, original rename receipts and
snapshot formats remain decodable under their original validation rules. They
never acquire native authority during recovery. A present malformed/partial/null
layout cannot select legacy fallback.

This native package will not launch/control a legacy FUSE data path. Finish a
live legacy session using the original application/helper. Once its known mount
is gone and helper authority is retired, offline recovery/export can use the
retained committed checkpoint/original objects through the existing safe
transaction. There is no runnable old engine or legacy live-export route in this package.
The retained compatibility code restores durable data only.

No cleanup, reset of Application Support, forced user-volume eject or service
restart is part of candidate verification. Parent acceptance uses fresh owned
fixtures and records actual lifecycle results separately from unit/static checks.
