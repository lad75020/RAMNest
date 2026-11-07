# RAMNest — all 11 filesystem findings addressed

## Final acceptance

The eleven numbered findings in `ramnest-filesystem-review.md` are implemented and verified against current source in `/Volumes/WDBlack4TB/Code/RAMNest`.

**Independent review: YES — zero identified High/Medium blockers within this requested eleven-finding change.** This is a bounded change verdict, not a claim that the whole application is defect-free. The separate original-copy cleanup writer race remains outside this report's eleven numbered findings and is disclosed below.

Final verification date: **2026-11-07, Europe/Paris**. No Git repository was initialized, no commits/pushes were made, no installed application was replaced, and no existing user volume/helper/default store was operated on. All runtime fixtures were generated and isolated. The packaged GUI was launched twice against an empty owned store and asked to quit normally by its exact process ID.

## Closure by original finding number

| # | Implemented change | Acceptance evidence |
|---|---|---|
| 1 | Reserve handles/metadata and complete fallible admission before O_TRUNC. Failed opens preserve the previous bytes, size and timestamps. | Deterministic red/green handle/metadata saturation and allocation-failure tests; native Debug and optimized admission suites. |
| 2 | Reject ACL-bearing roots/descendants, incompatible ownership, hardlinked symlinks and unsupported types before moving originals; repeat native security admission. Record public-root metadata separately from private 0700 revision containers. Preserve exact root modes/xattrs/quarantine on copy/export/recovery, including read-only staging crash replay. | Root/nested/file ACL rejection with unchanged source identity/content; exact quarantine/mode tests for 0750/0550 roots; actual process-exit and exception/retry; corrupt-stage rejection; independent production CLI repro now succeeds. |
| 3 | Build genuinely optimized native release products; keep test assertions active; generate helper provenance; rebuild the helper from current source in Xcode. Package provenance JSON under Resources, not nested-code Helpers. Resolve CMake in Xcode's restricted PATH and declare actual sandbox inputs/temporary outputs without disabling sandboxing. | Native Release library compile commands, assertion-active tests, five package-provenance tests, host release build, strict signing, packaged helper/source hash verification, fresh MCPO Xcode build. |
| 4 | Replace repeated full-tree logical/content/metadata accounting with transactional counters and amortized lifetime registries. Keep live logical ownership distinct from final physical backing ownership, including export pins. | Seeded 12,000-operation recomputation oracle, 10,000-node churn, hardlink/open-unlinked/pinned lifetime and finite backing admission tests, measured scaling. |
| 5 | Use compatible occupied nonzero 64 KiB page quota across native storage, sparse scans/copy, manifest/preflight and remount preparation. Preserve sparse holes; use decoded fallback for compressed input/unsupported extent queries; retain historical full-SHA compatibility. | 8 GiB apparent sparse Swift copy/preflight; native high-offset/64 GiB hole cases; occupied-page overquota rejection and atomic failed writes; actual historical >1 MiB SHA fixture; compressed candidate validation/corruption checks. |
| 6 | Verify previous candidates by current digest, apply current metadata and use safe fresh-source fallback. Open/cache roots and parent descriptors within bounded, identity-checked lifetimes. | Same size/mtime but changed content; chmod/xattr/flag/quarantine edits; both comparison preferences; exact final/source readback and tamper rejection. |
| 7 | Cache strong page digests and transaction-local, inode-stable hardlink digest results; remove redundant RAM decoding while preserving independent disk readback and source-race checks. Add bytes/time instrumentation. | Seventeen-name hardlink fixture reads 2 MiB rather than 34 MiB, with 16 validated cache hits; independent manifests/readback retained. Baseline/current benchmark artifacts preserved. A pre-change automated unit proof was not captured for this performance-only item; this omission is not represented as a red test. |
| 8 | Capture immutable coherent generations; reuse independently verified prior data by clone/copy, never mutable hardlinks into history; reuse validated no-op revisions. Avoid redundant successful eject export. Bind receipts to durable publication, helper incarnation/generation/frozen state. Invalidate durably before thaw. | Native incremental/no-op/namespace/topology/prior-corruption tests; actual native export2/quiesce2 coordinator integration; lost ACK/adoption/journal failures, concurrent G+1 continuation and stale thaw/refreeze rejection; real production transport regressions. |
| 9 | Reuse bounded per-worker compression/decoded scratch, avoid encoded workspace for raw paths, retain staged atomic page-map replacement and actual last-owner munmap reclamation. | Compression enabled/disabled, injected allocation failure, corruption/full-overwrite, suffix clearing, small-stack and real process footprint tests; request-size measurements. |
| 10 | Move export disk I/O/readback outside the tree lock over immutable captured state; keep O(1) metrics responsive. Add bounded authenticated connection workers and a whole-input deadline. Use per-volume transaction locks, short configuration locks and stable UUID continuations. | Paused-export status/metrics progress, independent-volume save/status progress, real distinct-process rename/delete lock regressions, durable invalidation-before-thaw tests, 61 real Unix-socket scenarios including new verbs. |
| 11 | Pin immutable directory-name snapshots and use stable-offset slices without per-offset whole-vector copies; cache directory counts; index recovery entries; use iterative traversal and bounded reanchored descriptor caches. | 1k/10k/50k listings, stable cookies, closed/root-populate/EMFILE cases, 96-descriptor and small-stack deep/wide tests, ancestor replacement rejection, staged restore replay and cross-boundary hardlink checks. |

Per-entry no-replace moves, directory synchronization and durable restore checkpoints remain intentionally in place. Their safety guarantees were not weakened merely to reduce journal/fsync traffic.

## Final parent-executed gates

These counts refer to different kinds of execution and must not be added together as a single unit-test count.

| Gate | Final result |
|---|---|
| Fresh native Debug | **20/20 passed** |
| Fresh native optimized Release, assertions active in tests | **20/20 passed** |
| Isolated Swift build/typecheck/regression driver | **40/40 gate entries passed**; includes core/CLI compilation, all-app typecheck and existing/new standalone suites |
| Real pathname Unix-socket protocol suite | **61/61 scenarios passed**; covers legacy and incremental operations, slow progress, malformed/stale/trickled frames, stalls, disconnects, lost final ACKs, responsive status and unchanged two-second status deadline |
| MCPO Xcode BuildProject | **Passed**, workspace `workspace-BTGUoMQE6h`, scheme RAMNest, My Mac |
| MCPO Xcode RunAllTests | **19/19 passed; 0 failed, 0 skipped, 0 not run** |
| MCPO final build-error log | **0 errors** |
| Host optimized package | **Built successfully** |
| `codesign --verify --deep --strict` | **Passed** |
| Packaged helper provenance/current native source | **Exact hashes matched** |
| Packaged GUI launch → normal Quit → relaunch → normal Quit | **Passed**, empty isolated store, two clean exit codes |
| Package layout/sandbox declaration tests | **5/5 passed** |
| Independent native review | No P1/P2 found; 9/9 reviewer-owned deterministic processes passed |
| Independent coordinator review and correction re-review | Previous P1/P2 closed; actual production transport and root-recovery repros rerun successfully; no remaining identified P1/P2 within requested scope |

Final Xcode result bundle: `Test-RAMNest-2026.11.07_00-04-08-+0100.xcresult`; its summary, console log and build logs are copied into the delivery evidence archive. The full bundle remains at the MCPO ActionArtifacts path recorded in that archive's receipts.

Final graph refresh used the **codebase-memory plugin**, project `Volumes-WDBlack4TB-Code-RAMNest`. Historical artifact copies still contaminate broad queries; exact current source paths and fresh file reads governed review conclusions rather than stale graph offsets.

## Measured performance — bounded claims

- Original optimized scratch creation run: **8,000 files in 216.056 ms**. Updated optimized run: **3.16904 ms**. These are recorded local microbenchmark samples, not mounted throughput or statistical service-level guarantees.
- The 17-name hardlink manifest fixture hashes **2 MiB rather than 34 MiB** in one walk; independent later validation remains.
- At 8,000 one-byte files, a **1% dirty save wrote 80 payload bytes and cloned 7,920 unchanged files**. A no-op save wrote **zero payload bytes** and retained integrity reads.
- Tiny-file cloning was **not universally faster**: the recorded 1% dirty sample took 4219.2 ms versus 3111.39 ms for a fully dirty sample. Clone verification and metadata work can dominate tiny payload savings. No blanket save-speedup claim is made.
- Compression request-size measurements and Debug/optimized scaling JSONL logs are retained with the evidence. No unsupported total-RSS guarantee is inferred from logical quota counters.

## Support contract and residual scope

1. **Unsupported security metadata fails before evacuation.** This implementation does not silently strip ACLs or normalize foreign ownership. ACL preservation itself was not added. Single-name symlinks remain supported; hardlinked symlinks are explicitly rejected rather than silently split.
2. **The original-copy cleanup writer race from the separate comprehensive code-review report remains.** It is outside the eleven numbered findings in `ramnest-filesystem-review.md`. Consequently this scoped result does not overturn the earlier general-purpose data-safety warning or certify the entire application for arbitrary concurrent original-file writers.
3. No existing live volume was mounted/unmounted, and NFS/FSKit/SMB mounted backend behavior was not recertified. The tests exercise real native callbacks, native storage, socket transports, coordinator fixtures and actual local file recovery, not every operating-system bridge path.
4. No actual shutdown/power loss, exhaustive allocator/syscall failure sweep or race-detector run was performed. Selected real process-exit/journal/ACK cutpoints and failure injections are covered.
5. Historical helpers retain their legacy PID/session compatibility limits. New generation-bearing helpers additionally bind incarnation/current frozen state. No systemwide backend default, security entitlement, TCC/FDA setting or sandbox policy was weakened.
6. The release app was **not installed over the user's running app**. It is supplied as a separately built/tested ZIP. Switch an installed app/helper only in a separately controlled lifecycle after protecting/ejecting its active volumes.

## Delivery and recovery

Durable delivery directory: `/Volumes/WDBlack4TB/Code/RAMNest/artifacts/filesystem-remediation-20261107/`.

- `RAMNest-all11-macos27.zip`: tested, ad-hoc-signed macOS 27+ app, CLI/helper and native provenance.
- `verification-evidence.zip`: reports, source fingerprints, red/green and final parent logs, benchmark data, review results and machine-readable acceptance.
- `before-source.tar.gz`: pre-task backup of 104 original project files, excluding user state/generated products.
- `source-changes.tar.gz`: task-changed/new source, tests, build metadata and documentation, excluding live data and generated binaries.

The project was non-Git at entry and remains non-Git. To roll back source changes, compare the delivery manifest with any newer edits, restore only the affected original paths from the backup, and remove only task-added paths where appropriate. Do not blindly overwrite newer work or touch live volume/default-store data. No runtime rollback is needed for the installed app because it was never replaced.

The case-only `RAMNest.xcscheme`/`ramnest.xcscheme` XcodeGen preservation collision was handled by backing up/staging only the CLI scheme during generation and restoring its exact bytes in a finally block; no user scheme was discarded. The project itself was regenerated from `project.yml`, not hand-edited.
