# Trash-exclusion correction — verified delivery

## Result and scope

The corrected app is `artifacts/trash-exclusion-20261107/release/RAMNest.app`, built as Release using `BuildProject` and tested using `RunSomeTests`, `RunAllTests` and `RunCodeSnippet`. The app copy is byte-for-byte equal to that tested Xcode product. Binary/source fingerprints and copied evidence are next to it in `verification.json` and `evidence/`.

**Zero open High/Medium implementation findings: YES**, within the reviewed exclusion, retention, guarded-startup and two-correction scope. This is not a claim that every FUSE-T backend topology is supported.

No installed app, real RPI5 folder, default store, system-wide FUSE configuration, security setting or source-file permission was changed by this correction. No commit, push, installation or deployment was performed. Disposable original holdings remain retained rather than being chmod-ed or recursively purged.

## Behavior

- A no-follow directory named exactly `.Trashes`, at any depth, is omitted from new snapshots, native import/export and reload. The subtree is not opened to read its security metadata or content.
- A regular file or symlink named `.Trashes`, and near-matching names, remain subject to the ordinary strict contract.
- Trash created in RAM is disposable at eject. It is not checkpointed or restored.
- Preexisting disk Trash is not deleted. Its original holding and required snapshot pins are retained, with a warning naming the recovery path. Nested Trash can retain the whole holding, including other originals. This can consume disk space.
- New helpers populate a guarded tree before mounting. Authenticated owner/control identity, strict post-mount verification and durable activation ordering remain required. Older helpers retain their guarded legacy ordering.
- Inconsistent/null/unknown startup-journal discriminators fail before recovery work. Timed waits re-evaluate the current protected state/deadline rather than abandoning an already accepted import.

## Executed verification

| Gate | Observed result |
|---|---|
| Focused correction RED | 3 selected, 3 failed on uncorrected production after a successful build |
| Focused correction GREEN | 3 selected, 3 passed after applying the correction |
| Canonical Release `RunAllTests` | 50 distinct tests; 50 passed, 0 failed, 0 skipped, 0 not run |
| Native CTest, Debug | 22/22 passed |
| Native CTest, RelWithDebInfo | 22/22 passed |
| Exact delivery app, real FSKit | 3 consecutive create/mount/save/eject/remount cycles passed on a `0700` source |
| Natural startup-owner exit | Before import and after import: sealed, retained, unmounted, normally retired |
| Exact delivery GUI | 2 isolated empty-store launches finished; both normal Quit requests accepted and processes exited normally |
| Bundle verification | Deep strict ad-hoc signature verified |
| Independent review | Prior two P2 findings closed; no open P1/P2 in the final bounded review |

Canonical evidence is the `Test-RAMNestTrashReleaseVerification-2026.11.07_18-50-18-+0100.xcresult` run. The final real lifecycle is the owned `rtx-final-20261107-08` fixture; root and nested original Trash modes were `0311` and `0000`, with preserved original sentinels. Ordinary bytes, xattrs, exact included manifests, snapshot omission, Trash-only no-op saves, restoration and remount were checked. The `no_log` marker was itself ordinary included, verified and persisted fixture data—not another exclusion.

The final tests ran after genuine failing evidence. The journal regression covers 33 wire/recovery shapes; native timeout regression covers seven actual timeout/mutex-reacquisition states. Earlier duplicated scheme executions were not counted as distinct methods; the final scheme ran 50 methods once.

## Boundaries and retained negatives

1. **FSKit hardlinks remain unsupported by the observed bridge.** Their strict mismatch remains a guarded rejection; metadata/topology checks were not relaxed. The successful real lifecycle used independent files. Native and snapshot hardlink tests remain enabled.
2. macOS FSEvents can write `.fseventsd` data after activation. An unisolated probe correctly observed additional ordinary entries and stale live-view file metadata; it was retained as a negative diagnostic. No `.fseventsd` exclusion or timestamp tolerance was added. With explicit user approval, only new disposable final test volumes used Apple's documented `.fseventsd/no_log` marker to eliminate that external writer. No real folder or global logging configuration was changed. This is not evidence of exact live-view coherence during arbitrary concurrent OS writes.
3. External-SSD scratch mounting failed for both earlier and corrected helpers before population. Final owned runtime verification used the approved internal APFS cache fixture location. This does not claim to resolve general external-volume permission/runtime failures.
4. A direct shell-built/dynamic-Core package acquired extra OS provenance in a legacy copy test. That package was not accepted or delivered; the Xcode-built static-Core Release product passed the strict test. No provenance or quarantine attribute was ignored or stripped.
5. The app is locally ad-hoc signed, not Developer ID notarized. It requires the existing independently installed FUSE-T runtime and the documented macOS/Apple Silicon platform. Manual installation and any real-data operation remain separate user actions.

## Using this delivery

Use the app from the supplied correction archive, not an earlier `corrected` or `corrected-startup` intermediate artifact. The displayed app version remains unchanged; the date-stamped archive and `verification.json` fingerprints identify this build.

Before replacing a running installed app, normally eject its volumes and quit it. Do not kill a retained helper or delete a warned-about holding. Inspect the named recovery location and preserve data before any manual cleanup. Start with a disposable real folder on the intended filesystem; successful fixture tests do not authorize automatic use of your real folder.
