# Snapshot scan reuse and cloning

O1/O2 share evidence only inside the current operation. `TreeEvidence` and
`RevisionEvidence` cannot be constructed from a caller-supplied manifest, decoded
from disk, or used at another path/revision/folder. A cold `verified` call and
recovery still authenticate content. Public `copyTree` still scans its source.

The scanner records each node's stat before reading content and attributes, then
validates device/inode, owner/group, full mode, link count, flags, size, mtime and
ctime through a no-follow directory chain. Exact directory namespaces are checked;
excluded directories remain opaque. Reuse repeats those stability checks. Revision
evidence also binds the private container and control-file identities/timestamps,
and rechecks stored metadata, relocation observations and the authenticated mode
map. Mutation invalidates evidence rather than refreshing it without content
authentication. These tokens are neither durable receipts nor recovery authority.

For a successful capture with a usable prior revision, full tree content scans are:

| Tree | Scans | Purpose |
| --- | ---: | --- |
| Current source | 2 | Capture admission and independent source-after |
| Prior revision | 1 | Authenticate before incremental selection |
| New destination | 1 | Independent copy readback before manifest commit |
| Obsolete deletion candidate | 0 extra | Validate the exact candidate's evidence from the prior scan, then bounded removal checks |

Save and periodic save pass both locally verified revisions into retention.
Cleanup adds no content scan for a retained anchor or exact deletion candidate
whose evidence is supplied and still stable. An initial pin different from the
prior revision still needs its own verification. Cold cleanup verifies all
retained anchors and journal-linked deletion candidates. A stale candidate token
retains the candidate with a warning; cleanup never refreshes that token from
stats or silently substitutes another scan. A damaged prior excluded from capture
reuse has no candidate token, so cleanup verifies it independently and retains it
with a warning and its journal reference intact on failure. Sibling cleanup
keeps its existing independent recovery checks and pins. Export also preserves its
source authentication/readback checks. No global evidence cache is used.

`VerifiedRenameReceipt.observe` performs one content scan. Its returned inode
records come from before that scan, and remain stable through namespace and opaque
entry admission. This replaces the second hash, not the independent observations
before and after the actual rename. Receipt/journal formats are unchanged.

O3 uses `fclonefileat` with an opened no-follow prior file descriptor, checked
against the verified node before and after cloning (including its named inode).
Only same-device, uncompressed regular files selected under the existing policy
are eligible. Hardlink aliases link to the new destination anchor, never history.
The cloned target is pinned read-only and checked for regular type, ownership,
single link and stable identity before normalizing its private mode/flags and
reopening it for writing. This also supports ordinary/legacy read-only priors
without modifying their modes. Replaced targets are rejected before normalization.
Inherited ordinary xattrs are cleared before copying current-source metadata. Provenance follows the existing OS copy
policy; quarantine keeps exact preservation and all actual metadata/accounting
still undergoes independent readback.

Unsupported cloning (`ENOTSUP`, `EXDEV`, `ENOSYS`, `EINVAL`), different devices,
or compressed prior representation use the existing sparse copier on the CURRENT
source descriptor. Other failures reject capture. A failed clone that leaves a
target rejects capture and retains the incomplete revision; it never opens or
unlinks that target as a fallback. Destination files are synced before readback.

The eleven new `SnapshotDescriptorTests` regressions cover
exact scan counts, concurrent same-size/restored-mtime writes under both policies,
rename observation races, corrupt prior fallback and cleanup retention, stale
control/tree/candidate evidence, retention pins and namespace safety, real clone
metadata/topology/sparse fidelity, forced unsupported/cross-device fallback,
prior substitution, partial targets, read-only legacy clones, and foreign clone
target replacement without mode/flag normalization.
The sparse fixture uses Darwin `F_PUNCHHOLE` after its initial flush, preserves
the content byte at offset 65536, and checks physical allocation after `fsync`.
The real-clone regression requires a clone-capable fixture filesystem. The tests
are added to the existing Xcode test source, without project/build-setting changes.

## Parent verification

- `BuildProject`: Debug build-for-testing and Release application build passed.
  The ignored generated Xcode project first lacked the existing `AppEntry.swift`;
  regeneration from unchanged `project.yml` and workspace reload repaired membership.
  Existing shared schemes were preserved byte-for-byte.
- `RunAllTests` on `RAMNest`: **134 passed, zero failed/skipped/not run**, covering
  **114 distinct test methods** including parameterized cases. All twelve
  `SnapshotDescriptorTests` methods (one existing plus eleven new) passed.
  The scan-count assertions executed; these are not elapsed-time speedup claims.
- The first focused run exposed fixture xattr setup after restrictive chmod;
  setup was reordered. The first full run exposed inherited read-only clone modes;
  the descriptor normalization fix and two new regressions resolved it.
- The Xcode-built Release app was copied to
  `artifacts/snapshot-o123-verification/candidate/RAMNest.app`, checked with
  `codesign --verify --deep --strict`, and its helper hash matched compiled
  Release authority. Its helper links only system C++ and System libraries.
- Owner-authorized, disposable native tmpfs checks passed two sync-mode and two
  temporary-mode mount/eject cycles using that exact candidate. They checked
  save/live-export, reconnect, mandatory mapping rejection, subsequent writes,
  hardlinks, symlinks, durable sparse allocation, root/file modes and flags,
  generated `.DS_Store` bytes, and all enumerated non-provenance fixture xattrs.
  Both final journals were idle without cleanup warnings or retiring references,
  each store retained one revision, original/staging siblings were gone, and
  all four runtime slots, mounts and associated helper processes were absent.
- Evidence copies are under `artifacts/snapshot-o123-verification/` (ignored).
  No installed app or personal source/store was changed. No multi-GB baseline
  timing benchmark, forced-loss probe, or manual GUI/accessibility QA was run.
- Independent source review found the read-only clone issue described above;
  follow-up review of its final fix reported no blocking findings. Source review
  is separate from the parent-run builds, tests, and packaged lifecycle evidence.
