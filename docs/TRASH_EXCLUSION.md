# Exact Trash directory exclusion

The user-approved policy excludes directories whose final path component is
exactly `.Trashes` from capture, verification, copying, native export/import,
mounted population readback, and restore/reload. Swift's `SnapshotExclusion` and
the native `snapshotExcludedDirectory` apply the same name and directory-kind
predicate. Both inspect no-follow metadata before subtree security, attributes,
quota, content, or enumeration. They never follow a symlink named `.Trashes`.
There is no general permission-error exception or source permission lease.

New native and Swift revisions omit the entries and their mode-map records.
Old committed revisions remain immutable: the complete version discriminator,
manifest namespace, mode map, digest and map/manifest correspondence are checked
before constructing an excluded view. Included namespace, physical policy,
checksums, attributes, quarantine, hardlinks and exact equality still apply.
An old excluded directory can be physically restrictive without being opened.
Malformed excluded metadata still fails complete map/manifest validation.

## Original disk data

Mount preparation records **all** original top-level names before moving any
entry, including excluded directories. Moves use pinned no-follow parents,
no-replace rename, normal journal phases and directory synchronization. This
keeps the mountpoint empty for the guarded FUSE-T mount without deleting disk
Trash. No original inode permissions are changed. A normal original directory
rename can change its ctime; admission/capture and subsequent cleanup do not.

After eject, included content is restored. Preexisting excluded disk Trash stays
at the exact original holding path in `journal.json`'s `siblingCleanup` records.
Those records retain their initial/completed snapshot references. Cleanup stops
at excluded directory metadata, before opening it, building a deletion plan or
unlinking anything. A nonfatal `cleanupWarning` gives the recovery location.
The holding can retain other original content alongside nested Trash; automatic
partial pruning is deliberately avoided. It remains pinned across later mounts.
Rollback before activation moves the recorded original names back normally.

Restore never replaces an existing excluded directory. An old committed revision
containing disk Trash is retained during revision retirement too. Unknown disk
entries never acquire deletion authority from a name or a filtered comparison.
Only an operator who independently owns and verifies the recovery data should
remove retained holdings or revisions; RAMNest does not do so automatically.

## Running old helpers and hardlinks

A running legacy helper may already have exported Trash into a fresh stage.
Helpers without the explicit `trash-directory-exclusion-v1` capability receive
full exports, including older private-storage-v2 helpers. They never receive a
filtered prior they cannot interpret. Exclusion-aware helpers can reuse an old
full mode map through its authenticated included view.
Adoption skips that subtree before normalization, copies only the verified
included view into the new revision, and leaves the opaque stage with an adjacent
`stage-UUID.trash-retained.json` recovery record and warning. New helpers omit
Trash before copying, hashing, decoding, writing, or generating mode records.

An included original hardlink alias whose other name is inside excluded Trash
can be copied safely into an independent new private inode. Runtime native
exports preserve included aliases and retain normal RAM quota accounting.
Fresh legacy normalization and committed private snapshots require every
included physical hardlink inode to be contained in the included namespace.
Cross-boundary links fail closed before any file permission normalization.
No permission widening of an outside inode is authorized. An old reuse anchor
inside excluded Trash fails with `EXDEV` rather than reading the subtree.

An excluded-only native mutation may reuse the verified included checkpoint.
The receipt still advances the session generation; quiesce/thaw checks continue
to cover the current complete RAM session, including disposable mutations.

## Verification and host handoff

The current helper negotiates `pre-mount-population-v1` independently of its
existing storage capability. Its frozen namespace is populated through the
authenticated, progress-aware control channel before the first filesystem
callback. An owner-authorized mount request follows population; strict mounted
verification and durable `populationVerified` still precede activation.
Natural coordinator exit seals an abandoned startup. Recovery requires proven
retirement before restoring originals. Journal decoding rejects null/partial
startup discriminators and unknown versions before any recovery branch while
preserving genuine legacy journals with all startup keys absent. A timed wait
rechecks the protected current deadline and import/mount state after reacquiring
the mutex; it does not impose a fixed startup budget on an accepted import.

See [the final correction report](TRASH_EXCLUSION_DELIVERY.md) for executed
canonical tests, exact-app lifecycle evidence and the retained FSKit limitations.

`scripts/trash-exclusion-tests.py --root OWNED_RUN_ROOT` compiles and runs the
Swift vertical and actual CLI admission test. The native CTest suite includes
`trash-directory-exclusion`. Existing restrictive-data and tamper cases use the
nonexcluded `RestrictedData` directory and retain their original checks.

`scripts/run-owned-trash-lifecycle.py` requires a new physical scratch root,
explicit CLI/readback paths and `--backend fskit`. It runs activation, ordinary
Foundation consumer readback, strict included manifests, saves, eject and two
remount cycles. It asserts the owned UUID, PID, short socket, source identity,
journal pins, metadata, hardlinks, Trash-only no-op and original sentinel
preservation. It never deletes fixtures, kills a process, forces unmount, uses
sudo, or touches a default store. Failure retains fixtures and reports the exact
active owned mount in `result.json`. `--prepare-only` exercises setup without
mounting. Only a successful real host run is lifecycle acceptance evidence.
