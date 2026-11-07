# RAMNest: restrictive-directory snapshot fix

## Result and exact scope

The reported `Cannot list extended attributes (errno 13)` failure was traced, using metadata-only checks, to `.Trashes` with permissions **0311** in fresh exported stages. On Darwin, both pathname `listxattr` and `flistxattr` through an earlier descriptor deny that read. The last committed revision was not changed.

Storage v2 preserves included restrictive data without fabricating absent xattrs, weakening metadata checks, or changing permissions on live/original/committed data. The later user-approved [exact `.Trashes` directory exclusion](TRASH_EXCLUSION.md) supersedes the earlier requirement to preserve Trash in snapshots. New private snapshot data uses owner-accessible physical modes (0700 directories/symlinks, 0600 files) inside private containers. An explicit format discriminator and SHA-256-bound mode map record the original logical modes. Restored/exported public data receives those original modes after private data verification through pinned identities. Native v3 acknowledgements bind the captured mode-map digest; native population and incremental verification understand the logical representation.

Legacy readable snapshots, including genuine rootless/full-SHA revisions, remain usable unchanged. Ordinary user paths such as `revisions/<UUID>/data` have no special meaning: managed reads require explicit context, not names or sibling files.

Fresh legacy exports are normalized only after their inode has been pinned and checked; no pathname chmod fallback exists. Darwin `O_SEARCH` permits safe descriptor pinning of the observed 0311 directory. Deterministic before/after-pin directory and outside-hardlink replacement tests verify that outside objects are not chmodded.

**The reported 0311 save/eject case passes with an unchanged old helper in isolated fixtures.** This is not a blanket claim that every historical helper/export can be repaired; see the limits below.

## Parent-executed verification on corrected source

- Native Debug: **21/21 passed**, zero skipped.
- Native optimized RelWithDebInfo: **21/21 passed**, zero skipped; test assertions remain active.
- Isolated Swift driver: **43/43 entries passed**, including core/CLI builds, app and XCTest typechecking, prior regression suites and the new storage suite.
- Real pathname Unix-socket suite: **92/92 scenarios passed**, retaining the prior 61 and including v3 progress, final acknowledgement/digest, malformed frames, disconnects, stalls, responsive status and the two-second stalled-status deadline.
- MCPO Xcode build: **passed**; final error log contains zero errors.
- MCPO canonical XCTest: **35/35 passed, 0 failed, 0 skipped, 0 not run**, scheme `RAMNestStorageVerification`, workspace `workspace-20Jc9GabnY`, My Mac.
- Host optimized package: built, strict deep signature verification passed, packaged helper and native source provenance hashes matched.
- Packaged GUI: two launches and normal Quit requests against an empty isolated store, with two clean exits, addressed only by exact owned PID/bundle identity.
- Independent native/protocol review: no P1/P2 findings; unchanged native implementation proof carried forward with hash checks.
- Independent Swift re-review: all three earlier P2s closed, no remaining High/Medium finding in the scoped changes. Own review probes reran rootless legacy, ordinary/forged path siblings, four outside replacements, unpinnable legacy refusal and native logical-0000 preservation.
- Corrected reviewed freeze: **108 source hashes matched**. Additional documentation and generated verification artifacts are separate from executable source.

The storage suite includes 16 scenarios, 26 tamper cases and three actual process-exit cutpoints. Developer FD96 execution also passed; this is separate from the parent's full Xcode/standalone executions, not another unit-test count.

Final Xcode result: `Test-RAMNestStorageVerification-2026.11.07_16-11-10-+0100.xcresult`. Summary, console and build logs, reviewed hashes and reports are included in the evidence ZIP. Verification-only scheme fixture configuration is retained in `artifacts/restrictive-storage-20261107/verification-project.yml`; it is not an application startup configuration.

## Important compatibility and recovery limits

1. **Already-running old helpers:** supported pinnable exports, including 0311 directories, use full export with no incompatible v2 prior. Old helpers never receive new private physical data as if it had public modes. Some old helpers already lose symlink mode bits through umask; only their exported evidence is available. Missing historical bits are not invented. New helpers preserve the logical bits explicitly.
2. **Old-helper exported 0000 objects:** Darwin may offer no permission-compatible descriptor with which to pin them. These saves/ejects fail closed, retain RAM/stages/prior snapshots, and do not reach unmount. There is no unsafe pathname-chmod escape. New v2 producers support logical 0000 directories, files, symlinks and roots without this physical-access problem.
3. **Included ordinary originals still require read access.** A public disk folder containing an unreadable nonexcluded 0311/0000 subtree is refused on a fresh capture/mount. Exact `.Trashes` directories are skipped before any subtree access; their disk originals are retained through the normal evacuation journal. A snapshot format does not grant permission to read arbitrary originals. RAMNest does not chmod originals or silently substitute a prior snapshot for included inaccessible data.
4. Unreadable included data in old committed snapshots remains unchanged and may fail cold verification with a path/syscall/errno diagnostic. Excluded Trash views skip subtree access after full metadata validation. Neither case migrates committed revisions in place. Rootless readable legacy data is materialized using its observed physical root only for the new copy; no claim is made about unrecorded historical public-root metadata.
5. After interrupted publication of restrictive public content, recovery fails closed if independent verification is impossible, retaining stage/revision/publication evidence. It does not bless or chmod inaccessible public content automatically.
6. No live mount was used for end-to-end recertification. Actual native producer/transport, Swift coordinator, disk storage, copy/recovery and process-exit fixtures were exercised. No forced eject, process killing, installed-app replacement, default-store migration, TCC/FDA or sandbox changes occurred.
7. The separate pre-existing original-copy cleanup writer race disclosed in the previous all11 report remains outside this bug fix. Zero scoped review findings does not certify the whole application against arbitrary hostile same-UID activity.

Because of the intrinsic legacy limitations, the worker's `fullySatisfiesRequestedContract=false` is retained as an honest rejection of a blanket all-old-helper/all-mode claim. It does not mean the reproduced `.Trashes` 0311 bug remains unfixed. Parent acceptance records distinguish the targeted fix, new storage implementation and residual limits.

## Delivery

Durable directory: `/Volumes/WDBlack4TB/Code/RAMNest/artifacts/restrictive-storage-20261107/`.

- `RAMNest-private-storage-v2.zip`: corrected, tested, ad-hoc-signed app.
- `corrected/RAMNest.app`: the same unpacked app; **not installed over the running app**.
- `cli/ramnest`, its sibling dylib and helper: corrected standalone tools. Their version text remains 1.0.0; use the delivery hashes/provenance, not that unchanged version string, to identify this build.
- `storage-v2-evidence.zip`: result reports, final parent verification logs, red/green evidence, reviewed fingerprints and machine-readable targeted acceptance.
- `before-storage-format-source.tar.gz`: source backup before this fix.
- `storage-v2-source-changes.tar.gz`: changed/new source and tests, not user data.

The code root remains non-Git. No commits or pushes were made. No stage/revision from the live default store was removed or modified by this work.

## Safe handoff for the existing mount

The existing GUI/helper processes have not been replaced. Retrying Save in the old GUI still uses the old code.

The next controlled step is to run **only `save` first** using the corrected standalone CLI and the existing store/volume identifier. If it succeeds, a verified v2 checkpoint exists before considering a normal `eject`. Do not use `--ignore-busy`, force eject, kill a helper, or restart the Mac to work around a failed save. If any command fails, preserve the mounted RAM, stages and revisions and inspect the exact diagnostic.

Illustrative commands — documented here, **not executed on the live drive**:

```sh
FIXED='/Volumes/WDBlack4TB/Code/RAMNest/artifacts/restrictive-storage-20261107/cli/ramnest'
"$FIXED" --store "$HOME/Library/Application Support/RAMNest" save 1BF77ACD-50C1-4F3F-AA1A-A80D44998CE4
# Only after successful save and normal busy-process checks:
"$FIXED" --store "$HOME/Library/Application Support/RAMNest" eject 1BF77ACD-50C1-4F3F-AA1A-A80D44998CE4
```

Installation/relaunch and any operation against the real drive require a separate explicit go-ahead. Do not infer live save/eject success from the isolated tests above.
