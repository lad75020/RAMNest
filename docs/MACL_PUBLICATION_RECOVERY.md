# MACL publication and RESET recovery

## Captured kernel evidence

The parent captured a user-issued `com.apple.macl` grant on a newly created,
disposable directory using one AppKit picker. On internal APFS,
`renameatx_np(..., RENAME_SWAP)` exchanged that directory with an owned sibling
symlink. Both inodes exchanged paths; the exact 72-byte MACL digest stayed at
the source pathname on the displaced symlink. The published directory had no
MACL because the destination pathname previously had none. Payload readback
passed. No security attribute was manufactured, copied, reapplied, or removed
for this probe.

The durable captured report (digests and metadata, no grant bytes) is
[`Tests/Fixtures/MACLSwapReport.json`](../Tests/Fixtures/MACLSwapReport.json).
The parent's original proof artifacts, including `probe.py`, remain unchanged.
The captured MACL digest is
`7fcac7fe1fe5f6d77213793b8a5f5a0a6c1ad3fc438e3ec5c85bc08fbe727687`.
This establishes this pathname relationship for the captured swap. It does
not authorize a MACL exception for ordinary renames or copies.

## Version 2 publication-swap receipt

`VerifiedRenameReceipt` keeps version 1 for existing ordinary rename receipts.
Only whole-root publication/rollback against the journal's exact managed
symlink can create version 2. Before mutation it durably records:

- The original raw directory manifest, inode nodes, and measured MACL digest
  and byte cost, without changing the original observation.
- The exact source and destination paths and source/destination parent
  identities, bound to the folder, session, restoration mode, restored inode,
  initial completed evacuation, and journal restore manifest.
- A no-follow raw observation of the exact managed symlink, including its
  inode, owner/group, mode, flags, link count, times, target, all visible xattrs,
  measured xattr accounting, and MACL presence/digest/length.

Immediately before the syscall, both raw sides must still match. Completion
independently observes both sides again. The directory must be the recorded
source inode and the displaced link must be the recorded managed-link inode.
The published directory's MACL must equal the destination link's pre-swap
MACL; the displaced link's MACL must equal the source directory's pre-swap
MACL. Absence is an explicit observation, not an unknown value. Unknown
versions/fields, explicit-null capabilities/completions, corrupt digests,
impossible accounting, changed identities, and unrelated metadata changes
fail closed. Existing narrowly scoped moved-inode provenance handling remains.

Root MACL accounting is adjusted only inside this validated receipt comparison.
The raw before and raw after remain intact. `Manifest.matchesCopy` has no MACL
waiver. Final revision binding uses the receipt's raw before to verify the copy
against the committed revision, and its proven raw after for independent final
readback. Content hashes, modes, ACL admission, quarantine, other attributes,
descendant identities/ctimes and post-completion raw observations stay strict.

A persisted version 2 intent can resume before the swap only if both original
raw sides still match. After a crash following the swap, it can complete only
by proving the recorded two-sided relationship. After completion, raw link
mutation is checked before configuration publication and before unlink; the
published directory remains raw-verified. The restored stage is durable before
owned-link retirement. Retirement can be retried after the owned link or
wrapper is absent. Source path authority is kept until idle, including across
a later reservation-release failure.

## Existing incomplete pnpm publication

The supplied live-state evidence describes a version 1 publication receipt
with `after == nil`: the restored directory and old managed symlink already
occupy opposite paths, the restored directory lacks MACL, and the displaced
symlink has MACL. The directory and symlink identities support the swap
explanation. Version 1 did not record the managed symlink's pre-swap MACL or
other raw metadata, so it cannot independently prove both pre/post relations.

This patch never manufactures a version 2 capability from those names or
identities, and never fills the version 1 receipt's `after`. Ordinary Recover
stays strict. A separate **Review Legacy Recovery…** action now implements an
explicit acknowledgement of the missing historical record. It is not a proof
of the old destination's metadata. **No live pnpm review or recovery was run.**

### Read-only review and explicit confirmation

The review is restricted to an already-published native checkpoint: a managed
unmount with no live mount, `nativeLink` at `publishing/checkpoint`, an incomplete
whole-root v1 publication receipt, its exact restored directory inode at the
original path, and its exact managed old symlink at `restoreStage + ".data"`.
The original holding must still be present and match the completed original
evacuation receipt. The empty restore wrapper, parent, source, symlink identity
and target, initial and latest committed SHA-256 snapshots, journal and folder
configuration are all checked. Existing helper sockets, unexpected staged
links, other entries or mount uncertainty stop the review without contacting
helpers. Metadata-only sessions are not eligible.

The current full manifest must match the committed materialization and the
legacy before observation. Only the explained **root** MACL pathname difference
and the existing narrowly bound rename provenance rule are admitted. The current
directory must lack MACL; the displaced symlink's measured MACL must match the
legacy root digest and accounting. Descendants, content hashes, hardlinks,
inodes, modes, flags, other xattrs and unrenamed ctimes stay strict. The original
receipt and both raw current observations are kept unchanged. No security
attribute is written, recreated, removed or copied.

The in-memory result has an immutable binding and a single-use token. The dialog
shows the missing history, folder path, checkpoint IDs and retained-copy paths.
**Cancel is the default**, including Return. Only clicking **Accept Missing
Record and Complete Recovery** supplies the acceptance boolean and matching
token. There is no CLI acceptance command or automatic path.

After that click, the coordinator reacquires the existing volume and repository
locks and repeats the full verification. The exact raw journal/configuration,
directory and symlink observations, retained original, wrapper identities, and
snapshot contents/metadata/inodes must still match. Busy, cancelled, consumed,
foreign-engine and stale tokens are rejected before metadata mutation. The UI
admits the operation synchronously and clears busy state on cancel/error/success.
No acknowledgement is persisted merely by opening or cancelling a review.

### Durable acknowledgement and retention

`journal.json` stores a separate `reviewedRecovery` acknowledgement with its own
version, explicit accepted token/date, the **byte-for-byte original journal**,
raw current directory/symlink/holding observations, original holding authority,
and initial/latest snapshot references with their verified logical/materialized
and raw observations. The original incomplete v1 receipt stays incomplete.
The bounded audit record is checked before a token is issued; an oversized
record stops read-only review rather than dropping evidence.

The acknowledgement, evidence, revision and acceptance objects reject unknown
fields (including null-valued fields), missing required fields and explicit null
required values. This strictness does not change historical journal/manifest
decoders. Each retained revision validates its raw namespace/inode structure,
binds the raw `data/` payload and metadata through the existing physical-mode
projection to the materialized and logical manifests, and binds its ID and
materialized manifest to the original transaction. Two references to the same
revision ID must contain identical evidence. No MACL comparison policy changes.
Wrapper identities and control-file hashes (`manifest.json` and `modes.bin`)
remain diagnostic raw readback for stale-review comparison. They do not
authenticate original control-file bytes, which are not embedded in the record;
durable payload authority uses the validated data/logical/materialized bindings.

Large immutable evidence is held in an immutable, checked-`Sendable` reference
inside the acknowledgement value. Acceptance arrays retain Swift value/COW
semantics; completion and version remain independent scalar values. Custom
encoding preserves the exact original acknowledgement keys and omission of a
pending completion. No reference wrapper appears on the wire.

The acknowledgement is durable before configuration changes. The coordinator
then binds the configured folder to the restored inode, retires only the empty
mount reservation using the normal bounded release operation, and records idle
completion. It never mounts, unmounts, exports, rematerializes a checkpoint,
retires the displaced symlink or removes the original holding. Native reservation
release can require the app's ordinary administrator authorization after the
explicit confirmation. Actual absence is checked; the app does not claim a live
mount or retain a busy flag after an error.

A crash before the final idle write keeps a pending acknowledgement. Reopening
does not execute it. Ordinary Recover and RESET both block; a **fresh read-only
review and explicit confirmation** are required. Retries keep the initial audit
evidence and append acceptance records. Changes to previously accepted evidence
block the retry. A crash after the idle write leaves completed recovery complete;
the consumed token cannot run it again.

Successful reviewed completion keeps **all snapshots**, the original holding,
restore wrapper, displaced symlink and journal evidence. Automatic snapshot and
sibling cleanup, remount, resize and record removal are paused for this record.
The UI displays the retained locations and snapshot-store path. The original
holding and displaced link remain external siblings of the selected folder;
they are not inserted into any deletion queue.

A later, separately confirmed **RESET** may delete managed snapshots, records
and acknowledgements. It preserves the selected folder and every external
recovery folder/link. Save the displayed paths and copy the audit evidence
before choosing RESET. An unfinished acknowledgement still blocks RESET;
only its validated completed idle state admits retained external recovery paths.
RESET inventories/deletes only its managed repository. Unknown data, changed
identities or remaining mounts still stop it. Retained external recovery folders
are intentionally left for later manual review, outside automatic cleanup.

### Safe user steps after parent verification

1. Have the parent run the new Xcode tests and Release build. This extension
   reuses existing Swift files and needs no source-membership regeneration.
2. When explicitly authorized to proceed on the real folder, select it in the
   app and choose **Review Legacy Recovery…**. Check the folder, revisions,
   warning and retained paths. Opening this dialog performs verification only.
3. Choose **Cancel** to leave recovery untouched. Choose the explicit acceptance
   button only after reviewing the missing-record warning. A stale or failed
   review leaves copies/evidence available and requires a new review.
4. After success, the app reports files on disk and lists retained backups.
   Save those locations and the journal acknowledgement before any later RESET.

These are future user steps, not a report that pnpm was recovered. No installed
application was replaced, built or launched for this extension.

## Finder metadata during RESET

Root `.DS_Store` is preserved, excluded from every deletion inventory, and
admitted consistently at preflight, preparation, finish, and retry. Admission
requires an owned single-link regular file, no group/other write bits, size
between zero and 16 MiB, no-follow/nonblocking open, matching pre/open/post
identities, and the repository device and filesystem ID. Symlinks, hardlinks,
FIFOs, directories, foreign owners/devices and oversized entries are rejected.
Finder can update a safely admitted file between attempts; its bytes are never
read or rewritten by RESET. Unknown names are safely escaped in diagnostics.
This removes the false Finder-metadata blocker without allowing RESET to erase
an unfinished recovery, original holding, stage, or needed checkpoint.

## Verification and remaining parent gates

Run `bash scripts/metadata-recovery-tests.sh`. It compiles the real Core Swift
sources and the disk-only regression scenarios without building or launching
the application. Its generated helper authority uses clearly labelled,
non-executable fixture bytes. This is **not production helper authorization,
native mount, packaged app, or end-to-end UI validation**.

The harness exercises Finder preservation and unsafe admission across RESET
boundaries; full publication/rollback with no-MACL fixtures; crash/reopen before
swap, after swap, after completion and during owned cleanup; strict inode,
xattr and payload mutation rejection; legacy incomplete-publication blocking;
and raw receipt encode/decode. Nonempty MACL cases are pure receipt models
using the genuine captured digest and length, including both presence sides.
They never write MACL to a filesystem object and are distinct from the parent
kernel probe. No further picker was opened.

The extension adds reviewed completion and cancellation without durable writes;
explicit token/acceptance and duplicate/busy admission checks; raw acknowledgement
round-trip and corrupt-record rejection; four accepted/configured/released/complete
crash boundaries with fresh confirmation on reopen; sixteen stale identity, xattr,
payload, holding, journal, configuration, revision and stage changes rejected
before metadata writes, including identical-byte control-file replacement;
backup/snapshot retention and external-copy preservation
through a separately authorized fixture RESET and RESET retry. The nonempty-MACL
review and native pending/completed journal cases are **pure data models**. Shared
transaction operations run only on owned no-MACL legacy-layout fixture directories;
they do not exercise the native reservation helper or installed application.

Latest standalone result after the bounded reviewer repairs: **all eleven
scenario groups passed**, with no compiler
warnings/errors. macOS emitted sandbox-extension diagnostics for the existing
fixture bookmark operations; assertions still passed. AppModel/ContentView Swift
source parsing passed before this repair; parsing is not app typechecking or a
build. The three new groups cover copy independence/canonical wire equivalence
and inline size budgets, 65 canonical-field mutations, and 40 independent
initial/latest logical/materialized/raw binding mutations using distinct revision
IDs and contents. Both direct acknowledgement and completed-journal decoding must
reject the corrupt records before completed RESET eligibility can be reached.
The original implementation failed the new size, canonical and binding checks.
Measured inline strides changed from acknowledgement 2400 / Journal 6056 bytes to
40 / 3696 bytes; the sibling candidate remains 2800 bytes. Budgets are 64 bytes for
the acknowledgement and 4096 bytes for Journal.

The parent reported 115/115 Xcode tests and a Release build before this extension.
Its later actual Xcode run reported 120 tests, 110 passes and 10 crashes. The
`xctest-2026-11-09-194955.ips` report shows an 80-frame stack-guard SIGBUS during
journal encoding on a 544 KiB cooperative stack, without deep recursion. The
inline reduction addresses that regression, but the standalone result does not
prove the Xcode crashes resolved. A fresh parent MCPO Xcode full suite and Release
build remain required. Stack limits, existing crash scenarios and macro sandbox
policy were not changed, and no Xcode/app build was run in this bounded pass.

`MetadataRecoveryTests.swift` is new and the current generated local Xcode
project already lists it in the test Sources phase. If the parent needs to
refresh generation, use XcodeGen while preserving schemes, then run RunAllTests
and the Release build. This patch does not hand-edit the Xcode project or run
app builds. Optional `--typecheck-swift-testing` typechecks the normal Swift
Testing declarations with only a shared test-namespace fixture. In the agent
sandbox this extra check was blocked by `sandbox-exec: sandbox_apply: Operation
not permitted` when starting Apple's macro plugin server; it is not a passing
Swift Testing or RunAllTests result. No sandbox bypass was attempted.
The reviewed UI path itself admits synchronously, makes Cancel the default,
and clears busy/progress and refreshes status after cancellation, errors and
completion. No GUI execution is claimed. Parent MCPO Xcode RunAllTests, Release
build and any separately authorized UI checks remain parent gates. Do not run
the reviewed flow on the real pnpm folder as part of this implementation task.
