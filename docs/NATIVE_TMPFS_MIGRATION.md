# Native tmpfs migration contract and delivery checklist

This is a project delivery record, not an active Spec Kit feature. At task start
`.specify/feature.json` and `specs/` were absent. No active feature or completed
Spec Kit tasks are invented here. The user request, measured preflight and parent
critical mmap findings are the delivery contract.

## Accepted scope

Replace the production FUSE-T/custom MemoryFS ordinary I/O path with native macOS
tmpfs. Keep original paths via journal-bound links, safe original holdings,
snapshot-store selection, verified metadata/hardlink/sparse copying, default
SHA-256 and safe decode/recovery. No FUSE fallback, permanent privileged service,
SIP/TCC changes, credential handling or unscoped user data operations.

The user accepted close-writers saves/ejects and conservative nonbypassable mapping
rejection; external force-unmount recovery uses only the latest durable checkpoint.
Custom LZ4 is removed. Dynamic size means allocation grows/releases with content;
a fixed mounted maximum is acceptable. Unsupported live maximum changes reject
without persisting a new value.

## Implementation and verification mapping

| Requirement | Source implementation | Required acceptance evidence |
|---|---|---|
| Native-only ordinary I/O/default dependencies | NativeTmpfsHelper, native CMake target, project.yml | Exact helper `otool -L`, production provenance, packaged mount type/fsid |
| Protected internal mount/data layout | NativeTmpfsPaths, LinkedFolderLayout, nativeLink v2 | Owned root/slot modes, source symlink, `.fseventsd` outside logical tree |
| Bounded one-shot root controls | NativeTmpfsProtocol/Helper, NativeTmpfsControl | Authorization/cancel/error probes; malformed/path/type/identity rejection |
| Close-writers coherent snapshot | freeze + root lsof parser + NativeCheckpointTransaction | fd-closed writable mapping refusal, Ignore Busy refusal, verified thaw; successful save after mapping closes |
| Metadata/content safety | existing Snapshot/VerifiedRenameReceipt/SiblingCleanup | xattrs, hardlinks, modes, BSD flags, sparse zeros/tail, original preservation and cleanup |
| Recovery after native loss | NativeRecoveryPolicy/finalizeNative | Live export/save refusal after force-unmount, unchanged committed revision, explicit recovery/loss disclosure |
| Fixed max, content-dependent allocation | statfs accounting and offline resize | Growth after 16 MiB write, release after truncate/unlink, unchanged mounted capacity, rejected live resize leaves config unchanged |
| Legacy preservation | strict native/legacy journal discriminators | Decode fixtures, mixed/null/unknown rejection, no legacy live control |
| Product UI/CLI | native engine labels, no compression control, native JSON metrics | Exact-package CLI and isolated GUI smoke |

Source-present is not runtime-accepted. Parent-observed checklist (2026-11-09):

- [x] Generate/open the worktree Xcode project; Debug and Release BuildProject succeed.
- [x] GetTestList includes native authority and lifecycle tests; RunAllTests reports
  95 passed, 0 failed, 0 skipped (77 declared methods, including parameterized cases).
  The unchanged old-engine baseline was 165 passed, 5 skipped / 170 executions;
  counts are intentionally not the acceptance target for deleted engine tests.
- [x] Build/package the exact candidate without replacing installed applications.
- [x] Verify packaged helper signature, compiled SHA-256 authority, receipt and all
  four Mach-O dependency inventories: zero FUSE dependencies. ZIP extraction keeps
  matching binary hashes and passes deep strict signature verification.
- [x] Run `scripts/native-tmpfs-package-probe.py` on that exact candidate; review
  both independent synchronized/temporary fixtures and remount cycles.
- [x] Run its explicit `--force-loss` option on fresh owned fixture data only.
- [x] Review allocation growth/truncate/delete counters and separate raw physical
  host context; do not infer isolated physical reclaim from statfs.
- [ ] Verify periodic save, GUI relaunch/repin, busy/cancel/error paths and snapshot
  storage selection with isolated candidate stores.
- [ ] Re-index the final worktree with codebase-memory and perform independent
  architecture/security review against fresh symbols and exact helper behavior.

## Test contract changes

The former C++ storage engine/callbacks, page-engine/protocol benchmarks and
optional builds are deleted. Dead Swift helper negotiation/export/activation and
old-engine fixture bypasses are removed. Shared transactions are renamed
`LinkedFolderLayout`/`LinkedFolders`; only raw persisted discriminator values keep
legacy spelling.

Reusable assertions remain as direct disk-data tests: immutable source/private
revision copying, policy transitions and frozen old encoders, corruption and
mode-map tampering, restrictive publication recovery, hardlinks and sparse
extents, quarantine/provenance fidelity, latest-only retention, partial cleanup,
unknown/replaced objects, source mutation through an old fd and whole-root rename
windows. Native checkpoint/freeze/type/fsid/rollback ordering and the conservative
mapping parser have dedicated tests. The old runnable-engine protocol tests and
page profiler tests are intentionally removed, so the old test count is not a
candidate acceptance target. Parent must inventory and execute the current suite.
No production integrity/provenance/copy rule is weakened to obtain a test pass.

## Parent-observed candidate results

The selected Release package uses `native-tmpfs-v1`; its helper SHA-256 is
`6879ab06a043a584122ac65de17e0009a1f22c60f46500010df483f3db612cad`.
The linked CLI identity, final embedded helper bytes and provenance agree.
The exact-package probe completed all four cycles (two synchronized and two
temporary), with verified restoration and slot release. It also proved
fd-closed writable-mapping refusal, Ignore Busy refusal, successful save after
closing mappings, rejected live resize without configuration drift, and
last-checkpoint-only recovery with disclosure after forced unmount.

Each allocation probe kept a 134217728-byte ceiling while observed kernel usage
changed from 8519680 to 25296896 after a 16 MiB write, then to 12713984 after
truncation, stayed charged while an unlinked descriptor remained open, and
returned to 8519680 after final close. These are filesystem counters, not RSS.

A separate real five-minute periodic-save probe promoted a new checkpoint after
304.589 seconds, verified its new marker payload, retained the same mounted
session, and observed the filesystem writable after thaw. An earlier observer
sampled an in-flight commit and the GUI subsequently exited; that attempt was
inconclusive and was not counted as a periodic-save pass.

The identical owned 1 GiB QD1 benchmark completed six verified trials and 42
timed phases. Incompressible median sequential write/read were 19892.95 /
20640.94 decimal MB/s; 4 KiB random-write median was 797119.78 operations/s.
These are shared-host observations, not sustained storage guarantees or durable
on-disk fsync measurements.

Real execution found and corrected Xcode atomic-temp sandbox permissions and
shell failure propagation, bootstrap sticky-mode formatting and inherited cwd,
and APFS allocation materialization of skipped zero ranges after flush. APFS
copies now deallocate only proven zero/hole ranges using inward-aligned
F_PUNCHHOLE calls. The original sparse fixture is explicitly established and
validated before mounting. Regression assertions were retained; earlier failed
fixtures remain as failure evidence rather than being relabeled successful.

## Limits and failure behavior

One-shot administrator authorization can be needed for reserve, mount, readonly,
freeze, thaw, unmount and release. There is no persistent root component. A lost
control receipt or ambiguous prepared slot can require explicit host inspection;
it is not adopted or removed by guessing. Kernel size-update success is not a
resize. Close regular files and mapped readers as well as writers; the scanner
is intentionally conservative and can reject an otherwise harmless open reader.
Its bounded complete lsof scan is not atomic against adversarial reference
handoff/fork. Mapping detector errors remain fail-closed.

Native unmount destroys the live tree. A pin cannot defeat force-unmount, kernel
loss or power loss. Snapshots on disk are checkpoints, never a substitute labeled
as current RAM. macOS controls compression/swap; no zero-disk-write, secure erase
or app page-compression claims remain. Actual native lifecycle/Xcode results must
be reported by the parent; source/static diagnostics do not establish them.

Native snapshot copying requires ordinary-user read access to the working tree. Unreadable entries/final-mode trees remain fail-closed and are not silently chmod-ed, skipped or read through an expanded root privilege boundary. Retained private snapshot data can still carry logical restrictive modes for safe recovery/publication under its existing receipt rules. Parent must verify those cases on the exact package.

## Bounded repair after first canonical candidate run

Parent reported the first candidate BuildProject passed; RunAllTests inventoried
70 methods / 88 executions with 85 passing, 3 failing, no skips. Two failures
shared an adapted retention fixture ordering bug; the other fixture omitted its
recorded public-root mode. Their exact obsolete-anchor/full-manifest assertions
remain. Those source repairs and new regressions still require a fresh parent run.

Independent review also found native completed-idle journal/next-session reset
invalidation, mutable-path elevated execution, and delayed periodic work crossing
sessions. Repairs add explicit historical completed-idle transitions, exact-byte
native journal decode before atomic replacement, authenticated protected root
staging, and post-lock session/fsid/socket/policy/schedule-ticket fencing. The
package probe uses bounded Darwin ctypes xattrs and checks required APIs before
creating any fixtures. Added Swift/native/Python regressions cover these boundaries.
No live gate is inferred from compiler/static checks; re-index/re-review security
before any packaged administrator probe, then rerun focused/full Xcode and exact
Release-package/GUI acceptance. No project settings, Info.plist, entitlements,
script-sandbox exception or permanent service change is part of this repair.

## Byte-authority followup to cleared journal/periodic repairs

Parent reported 91/91 canonical tests, six focused passes and Debug/Release builds
passed before this followup, while administrator testing remained on security HOLD.
The remaining pre-dialog resource-swap finding is addressed by Core-compiled final
helper SHA-256/engine/configuration authority, generated only after native build/
final signing and required by the real capture path for both pinned bytes and
receipt. Core owns the producer before compilation; both clients link it and the
app embeds the same verified output. Root protected staging is preserved. Three
new Swift authority-decision tests and generation/package static regressions cover
the race, recomputation, configuration separation and refused incoherent inputs.
These source/static results do not clear the independent security hold or count as
fresh canonical build/test/runtime evidence. Parent must regenerate the project,
review generated membership/order, rerun canonical tests/builds, re-review security
and select a NEW exact candidate before any administrator probe. Previous candidate
copies are retained. Journal/periodic code and their assertions are unchanged.
