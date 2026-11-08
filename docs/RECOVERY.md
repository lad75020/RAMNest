# Local recovery

Content-checksum references in this recovery guide describe the default SHA-256 mode. Verification and retirement use each revision's recorded [file verification policy](FILE_VERIFICATION.md). Size/mtime mode permits a same-size edit with restored modification time to go undetected; changing Settings cannot upgrade an existing revision or reinterpret recovery authority.

First stop writers and inspect status. Do not replace a snapshot from an empty or stale mountpoint.

Long helper operations report completed work while population/export/quiesce
advances. A timeout means no advancing progress arrived within the inactivity
deadline; a disconnected or truncated reply means the connection ended before a
complete final result. Both retain recovery data. The helper can still be working
after its client times out or leaves, so inspect the session before repeating a
mutating operation. No timeout automatically cancels a job, retries a command,
deletes a stage, or starts recovery. See [helper operation details](HELPER_OPERATIONS.md).

```sh
artifacts/ramnest list --all --json
artifacts/ramnest info 'Folder Name' --json
```

For test repositories, put `--store /absolute/disposable/support` immediately after `ramnest` on every command. The default repository is `~/Library/Application Support/RAMNest`.

`volumes/UUID/journal.json` records phase, verified population state, current/initial/restore revision, pending retirement references, exact evacuation entries, restore staging identity, completed-session sibling cleanup provenance and any error. Immutable snapshots are `volumes/UUID/revisions/REVISION/data` with a sibling manifest. Current revision is authoritative after a save. Normal retention is latest-only: mounted sessions retain the initial rollback anchor and any required restore revision. Successful idle restore/rollback transfers exact sibling identities into a durable cleanup queue before clearing transaction references. Snapshots needed to validate a queued original remain pinned until its cleanup completes. `priorRevision` is accepted from older journals but does not permanently pin history. A sibling `.ramnest-UUID-SESSION.original` holds original objects while mounted; a `.ramnest-UUID-restore-UUID/data` stage holds a verified restore during recovery. These are private 0700 containers, not guessed fallback paths.

Retirement happens only after checksum verification of retained snapshots and durable journal replacement, while holding the repository lock. Only journal-linked deletion candidates are verified and inspected; there is no history-wide scan. Cleanup uses owned, no-follow directory handles and descriptor-relative unlinking, rejects symlink roots/ancestors/candidates, and refuses device or filesystem boundaries. A symlink leaf is unlinked without following its target. Completed-session siblings require durable idle, a valid committed snapshot and verified selected-directory identity/content. Normal-sync originals must still match the initial snapshot, including content and metadata; changed originals or unknown entries are retained. Temporary rollback moves the original inodes back without RAM export, then removes only the empty holding. A recorded restore stage is removed only with empty `data` and matching identities. The durable queue records a validated manifest and per-entry identities before deletion, so partial unlink failures can retry with bounded descriptors and stack. Unknown entries, corrupt revisions and incomplete captures/stages remain available for manual recovery. Failed/uncertain/recovery phases do not prune. A cleanup failure leaves the completed operation successful, reports a warning on stderr and records `cleanupWarning` when the journal is writable; the next safe operation can retry. A recovery error remains separate.

If the helper is alive and the actual mount still exists, use Save/Eject. Relaunching the GUI reconnects; it does not create a second filesystem. A guarded, verified mount interrupted before write activation can be resumed by `mount REF`; an unverified population should be ejected/recovered rather than activated. If the helper is absent but a stale/orphaned mount remains, unmount only that known managed volume on the host first. Do not force-eject an active helper unless accepting loss of pending kernel writes.

```sh
# Export the latest committed revision into a NEW directory.
artifacts/ramnest export 'Folder Name' /absolute/new-recovery-directory
# Export a transaction anchor or manually retained revision, only if it still exists.
artifacts/ramnest export 'Folder Name' /absolute/new-retained-directory --revision REVISION_UUID
# Explicitly rescue a still-running RAM tree, including temporary-mode work.
artifacts/ramnest export 'Folder Name' /absolute/new-live-directory --live
# Restore the authoritative local revision after an unclean session.
artifacts/ramnest recover 'Folder Name'
```

`--revision` does not promise history. A revision removed by latest-only retention reports that it is **not retained on disk**. If the latest snapshot is damaged, preserve all remaining recovery data and original holding directories before investigating. Do not expect an older saved version to remain available.

Recovery never overwrites unknown entries. If files were placed at the unmounted selected path, move them to a separate safe directory yourself, export the committed snapshot, compare the copies, then retry recovery. A partially completed restore is resumed only when present entries exactly match the committed manifest and the remaining stage identity still matches. A staging identity change or missing stage blocks recovery with the snapshot retained. Preserve the journal for investigation; export is always safer than editing transaction metadata.

A failed initial conversion rolls back known entries with no-replace moves when the helper could not start. Uncertain mounts remain gated. Concurrent changes to retained originals can block rollback: both those original objects and the verified snapshot remain available for a manual choice. Temporary mode restores initial original objects, preserving their inodes when they are intact, and deliberately discards RAM modifications on eject. Do not use temporary mode for durable work.

On helper crash/power loss, only already committed revisions are recoverable; unsaved memory is gone. A normal external unmount is different: the surviving helper retains its tree, commits and restores it after FUSE teardown, and retries failures while keeping RAM alive. Normal GUI Quit waits for save/eject and offers Stay on failure. No actual shutdown test is performed.

Deleted configurations leave remaining recovery storage intact. To recover it, inspect/copy the retained `data` directory directly and verify it against `manifest.json`, or temporarily restore the original configuration from a backup for CLI export. Cleanup never removes the latest verified committed snapshot. A legacy evacuation with a good recorded device/inode and valid initial snapshot can be attributed and cleaned at the next safe transaction. Missing/pruned initial snapshots or replaced paths cause retention and a warning. Legacy directories with no journal reference cannot be distinguished from uncommitted captures and are left for manual inspection after a verified export/backup. Opening the app or reading status does not scan/purge them.
