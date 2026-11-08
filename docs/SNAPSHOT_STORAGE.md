# Snapshot retention and storage location

RAMNest keeps durable local checkpoints as well as the temporary `.original`
holding directory. A completed idle folder normally retains only its latest
verified checkpoint. While mounted, the initial checkpoint and latest saved
checkpoint are retained; interrupted work and cleanup plans can pin additional
recovery data. This is not an unlimited snapshot history. Unrecognized or
unverified artifacts are never blindly purged.

## Choose a storage folder

In **Settings → Snapshot storage**, use **Choose / Move Snapshot Storage…**.
Choose an existing parent directory. RAMNest creates a new private child named
**RAMNest Snapshots** and displays its actual path. The parent's existing contents
and permissions are not changed.

Snapshots, manifests, journals and folder settings move together. A small stable
location/transaction record stays in the default Application Support directory
so future normal GUI and CLI launches find the selected store. An explicit
`--store PATH` session remains isolated and cannot change the global selection.

Before moving, eject every RAM folder, finish recovery/cleanup, and apply or
discard option edits. The application rechecks these conditions under storage
locks. Choosing the current location is a no-op. Existing unrelated destination
children, overlapping managed folders and unsafe/symlink paths are rejected.

## Copy, verification and cleanup

The mover handles the store as opaque physical data, not as a source-folder
snapshot/export. It copies and verifies bytes and metadata, including content
that source snapshot traversal would normally exclude, and preserves stored
representation/mode maps. It does not chmod originals or drop metadata to force
a successful move. Unsupported physical entries, hardlinks, compression/flags
or denied exact metadata preservation cause a controlled failure while retaining
the old data.

The selected location is published only after independent readback. The old
store is fenced against new writes before publication. Successful retirement
removes obsolete payloads; small location, lock and retirement records may remain
at the old location. The feature does not leave a second payload copy as normal
completed state.

A failed or paused operation retains its recorded recovery state. **Retry Storage
Move / Cleanup** resumes only proven ownership and transaction stages. After
commit, cancellation no longer interrupts retirement. If an allocation occurred
before its inode receipt reached disk, or a location/record was substituted,
manual review can be required; RAMNest does not adopt an object by its name.

An unavailable or replaced selected directory reports an error rather than
silently creating an empty default store. Recorded device/inode identity is
strict: a volume identity change needs explicit recovery review, not automatic
adoption of a same-path directory. Keep the bootstrap and transaction records
until recovery completes.

## Verification boundary

The location and migration APIs have fixture-only regression coverage for default
and explicit resolution, strict records, successful repeated moves and old-payload
removal, busy/pending rejection, unsafe destinations, cancellation, copy/commit/
cleanup faults, disconnects and retry. Settings model verification injects its
manager and picker, preserves option drafts and rejects superseded refreshes.

Development does not relocate the real user store or rewrite real preferences.
The live retention audit observed automatic removal of an obsolete checkpoint
when a restore finished, leaving the latest revision only. Exact build/test and
packaged-app results are recorded separately in the delivery artifacts.
