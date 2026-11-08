# Swift test modernization

Baseline: clean `master`, `56bf202`. Scope: the 14 Swift files in
`Tests/RAMNestCoreTests`, their existing standalone entry points, and this
coverage record. Production code, native C++, dependencies, project
configuration and Python test logic are unchanged. The sole script compatibility
edit supplies the installed Testing macro plugin path. No Spec Kit feature was
created.

## Inventory and counts

Counts are source inventories, not a claim that every host gate ran. A case
counts each `@Test(arguments:)` input separately; an ordinary loop remains part
of its containing test. Custom throwing scenario checks remain coverage even
though they are not individual test declarations.

| File (.swift) | Before XCTest methods | After declarations | After cases | Original XCTest sites |
| --- | ---: | ---: | ---: | ---: |
| AttributeAbsenceTests | 4 | 4 | 4 | 0 |
| CoreTests | 16 | 16 | 25 | 116 |
| DebugBenchmarkTests | 16 | 14 | 18 | 85 |
| FollowupTests | 39 | 40 | 51 | 158 |
| HoldingCleanupTests | 1 | 1 | 1 | 0 |
| LatestSnapshotTests | 1 | 1 | 1 | 0 |
| MountedFlagPolicyTests | 4 | 4 | 4 | 0 |
| PopulationReadinessTests | 14 | 13 | 14 | 0 |
| QuarantineSnapshotTests | 21 | 21 | 21 | 156 |
| ReviewAcceptanceTests | 0 | 1 | 1 | 0 |
| SiblingInventoryTests | 7 | 7 | 7 | 22 |
| SnapshotDescriptorTests | 0 | 1 | 1 | 0 |
| StorageFormatTests | 17 | 15 | 17 | 0 |
| TrashExclusionTests | 6 | 6 | 6 | 0 |
| **Debug total** | **146** | **144** | **171** | **537** |
| **Release total (DebugBenchmarkTests excluded)** | **130** | **130** | **153** | **452** |

There were 12 XCTest-importing files and two scenario-only files
(`ReviewAcceptanceTests`, `SnapshotDescriptorTests`). No XCUI tests exist in
this target. All eligible XCTest suites are now structs. There were no XCTest
setup/teardown overrides, implicitly unwrapped stored fixtures, asynchronous
XCTest expectations, or `continueAfterFailure = false` overrides to migrate.
Existing initializer-based scenario fixtures keep their nonoptional state.

All 537 original XCTest sites are retained as 505 `#expect`, 26 `#require`
and six `Issue.record` sites. One added `#require` protects the benchmark rate;
five added `#expect(throws: Never.self)` guards handle throwing reads in two
nonthrowing callbacks and three defer checks. Final source totals are **510
expectations, 27 requirements and six issue records** (543 sites). The admission
UUID now uses a requirement instead of a nonfatal nil assertion followed by a
force unwrap. Failure diagnostics and
error-handler assertions are preserved; a source audit found no missing original
assertion message literals. Raw attribute dictionaries are compared before the
macro so failure diagnostics capture only a Boolean, preserving their original
confidentiality constraint. Floating-point accuracy uses absolute
difference with the same 0.0001 tolerance. The six issue records are forbidden
nonthrowing callbacks or cleanup catches, where continuing preserves the
original failure/cleanup behavior. Throwing scenario guards keep their existing
messages and abort behavior. No underscore APIs or actor isolation were added.

Parameterization preserves both native formats, both helper generations, both
startup orders, all three benchmark host modes, all three worker modes and all
ten relocation cutpoints. Other edge-case loops remain intact. New discovery
adds the review scenario, wide snapshot cleanup, and 12 safe in-process
follow-up cases. Standalone-only process-limit, lock-child and native protocol
follow-ups retain their original runners.

## Shared state and completion

Every suite is nested in `RAMNestTestSuite`, whose single `.serialized`
trait serializes descendants **across files and suites**. This is necessary
because the review hash-reuse oracle sets `RAMNEST_HASH_TRACE`, which every
snapshot manifest can observe. Separate serialized sibling suites would not
protect that environment. The previous value is restored in a scoped defer on
success and failure. Session hooks, cancellation objects, journal-write hooks
and FSKit fixture roots are per fixture; computed static manifests/paths are
not shared mutable storage.

The review's three background operations join a dispatch group on every exit,
and complete before shared results are read. Existing bounded semaphores still
check progress while the first export is blocked. No confirmation is used as a
wait. Host NFS and 1 GB benchmark opt-ins also appear as enabled traits; their
original body validation and cancellation messages remain.

## Original names and assertion mapping

Every original method is listed below. Replacement names are raw sentence-case
identifiers in the corresponding nested struct (existing suite names retained).
“Sites” counts assertions, unwraps and explicit failures in that method's
body; helper sites are included in the per-file total above. A scenario call
retains all of its custom checks and nested calls, including their loops.

### AttributeAbsenceTests.swift

Explicit absence, fatal errno/list races, expected attributes and bounded diagnostics.

| Original method | Replacement test | Preserved body coverage |
| --- | --- | --- |
| `testExplicitAbsence` | `Explicit absence` | `AttributeAbsenceScenarios.absence()` |
| `testErrorsStayFatal` | `Errors stay fatal` | `AttributeAbsenceScenarios.errors()` |
| `testMissingExpectedAttributesFail` | `Missing expected attributes fail` | `AttributeAbsenceScenarios.mismatch()` |
| `testReadinessDiagnostic` | `Readiness diagnostic` | `AttributeAbsenceScenarios.diagnostic()` |

### CoreTests.swift

Location selection/relocation and the full core integration scenario chain (compression metadata, sparse quota, recovery, bookmarks).

| Original method | Replacement test | Preserved body coverage |
| --- | --- | --- |
| `testAbsentAndExplicitLocation` | `Absent and explicit location` | 4 sites |
| `testCommittedSelectionReopensAndRejectsStaleStore` | `Committed selection reopens and rejects stale store` | 7 sites |
| `testMalformedSelectionsFailClosed` | `Malformed selections fail closed` | 6 sites |
| `testMissingReplacedAndSymlinkDestinationsNeverCreateStore` | `Missing replaced and symlink destinations never create store` | 4 sites |
| `testUnsafeAndDuplicateSelectionFilesFailClosed` | `Unsafe and duplicate selection files fail closed` | 6 sites |
| `testOpaqueMovePreservesStoreAndRemovesOldPayload` | `Opaque move preserves store and removes old payload` | 26 sites |
| `testCompletedVerifiedStartupCanMoveButUnretiredGuardCannot` | `Completed verified startup can move but unretired guard cannot` | 3 sites |
| `testRelocationRejectsBusyLifecycleAndVolumeLock` | `Relocation rejects busy lifecycle and volume lock` | 6 sites |
| `testRelocationRejectsOverlapUnknownAndSymlinkTargets` | `Relocation rejects overlap unknown and symlink targets` | 7 sites |
| `testRelocationFaultsResumeAndCleanupIsVisible` | `Relocation faults resume and cleanup is visible [10 stages]` | 7 sites |
| `testRecordedCopyCancellationCanRetryAndMissingStorageFailsClosed` | `Recorded copy cancellation can retry and missing storage fails closed` | 5 sites |
| `testPendingDisconnectAndCorruptReceiptRetainBothStores` | `Pending disconnect and corrupt receipt retain both stores` | 7 sites |
| `testPendingCopyFencesExplicitClientsAndRetryResyncsFences` | `Pending copy fences explicit clients and retry resyncs fences` | 8 sites |
| `testPartialCopyUnlinkLostACKCanRetryFromBothNamesAbsent` | `Partial copy unlink lost ACK can retry from both names absent` | 8 sites |
| `testPartialCleanupRetryAndUnknownDestinationAreConservative` | `Partial cleanup retry and unknown destination are conservative` | 10 sites |
| `testCoreScenarios` | `Core scenarios` | `Scenarios.run()` |

### DebugBenchmarkTests.swift

Payload/offsets, short I/O/EINTR, capacity, ownership, strict profile schema, admission generation, report math, worker modes and gated 1 GB host controls.

| Original method | Replacement test | Preserved body coverage |
| --- | --- | --- |
| `testPayloadAndOffsetVerification` | `Payload and offset verification` | 3 sites |
| `testShortIOEINTRAndCancellation` | `Short I/O, EINTR and cancellation` | 6 sites |
| `testCapacityRoundedAndOverflow` | `Capacity rounded and overflow` | 3 sites |
| `testOwnedCleanupAndReplacement` | `Owned cleanup and replacement` | 6 sites |
| `testStrictProfileReplyAndNA` | `Strict profile reply and N/A` | 14 sites |
| `testSHAOnlyProfilePolicyRejectsLegacyAndUnknown` | `SHA only profile policy rejects legacy and unknown` | 7 sites |
| `testAdmissionGeneration` | `Admission generation` | 5 sites |
| `testReportMathAndOverlappingRows` | `Report math and overlapping rows` | 11 sites |
| `testCancelledOwnedFixtureCleanup` | `Cancelled owned fixture cleanup` | 3 sites |
| `testDirectoryReplacementRetainsOtherEntry` | `Directory replacement retains other entry` | 5 sites |
| `testLegacyCapabilitiesAndPolicyCreateNothing` | `Legacy capabilities and policy create nothing` | 7 sites |
| `testSmallOwnedWorkerAllModesAndCleanup` | `Small owned worker all modes and cleanup [both, write, read]` | 4 sites |
| `testRuntimeStalenessCancellationCapabilityAndPeriodic` | `Runtime staleness cancellation capability and periodic` | 2 sites |
| `testOwnedMountedFullDecimalGB` | `Owned mounted full decimal GB [both]` | `fullGB(.both)` |
| `testOwnedMountedStandaloneRead` | `Owned mounted full decimal GB [read]` | `fullGB(.read)` |
| `testOwnedMountedStandaloneWrite` | `Owned mounted full decimal GB [write]` | `fullGB(.write)` |

### FollowupTests.swift

Sparse extents/checksums/copy/error matrix, symlink journal decoding, FSKit lifecycle/crash/identity/metadata/cleanup/concurrent reservation checks.

| Original method | Replacement test | Preserved body coverage |
| --- | --- | --- |
| `testUnsupportedExtentsPreserveChecksumAllocationAndExactCopy` | `Unsupported extents preserve checksum allocation and exact copy` | 6 sites |
| `testUnsupportedExtentsAfterSuccessfulSkip` | `Unsupported extents after successful skip` | 4 sites |
| `testENXIOStillEndsExtentWalk` | `ENXIO still ends extent walk` | 3 sites |
| `testExtentHardErrorsRemainFatalBeforeAndAfterSkip` | `Extent hard errors remain fatal before and after skip` | 6 sites |
| `testLegacyAndSmallHashesDoNotQueryExtents` | `Legacy and small hashes do not query extents` | 5 sites |
| `testMalformedSymlinkLayoutCannotFallBackToLegacyRecovery` | `Malformed symlink layout cannot fall back to legacy recovery` | 1 sites |
| `testAbsentSymlinkLayoutPreservesLegacyBackendJournal` | `Absent symlink layout preserves legacy backend journal` | 2 sites |
| `testMountArgumentsMapPhysicalPathAndKeepSourceDistinct` | `Mount arguments map physical path and keep source distinct` | 4 sites |
| `testWholeDirectoryEvacuationPreservesRootAndChildIdentities` | `Whole directory evacuation preserves root and child identities` | 4 sites |
| `testLinkPublicationReadbackPrecedesActivationAndKeepsOriginalUsable` | `Link publication readback precedes activation and keeps original usable` | 5 sites |
| `testExactBasenameCollisionRefusesWithoutTouchingSource` | `Exact basename collision refuses without touching source` | 3 sites |
| `testTemporaryEjectPreservesOriginalRootAndChildObjects` | `Temporary eject preserves original root and child objects` | 5 sites |
| `testNormalEjectRestoresLatestRAMAndRefreshesConfigurationIdentity` | `Normal eject restores latest RAM and refreshes configuration identity` | 6 sites |
| `testCheckpointFailureRetainsRAMLinkAndOriginalHolding` | `Checkpoint failure retains RAM link and original holding` | 5 sites |
| `testLinkReplacementBlocksSaveAndRetainsReplacement` | `Link replacement blocks save and retains replacement` | 3 sites |
| `testHoldingAndMountRootReplacementFailClosed` | `Holding and mount root replacement fail closed` | 2 sites |
| `testDecoderRejectsUnknownFieldsBackendAndIncoherentStages` | `Decoder rejects unknown fields backend and incoherent stages` | 1 sites |
| `testEvacuationRenameCrashRecoversFromBoundHoldingIdentity` | `Evacuation rename crash recovers from bound holding identity` | 3 sites |
| `testPublicationSwapCrashResumesLatestDestinationBeforeConfig` | `Publication swap crash resumes latest destination before config` | 4 sites |
| `testRestoredCheckpointRevalidatesCompletedRenameBeforeConfiguration` | `Restored checkpoint revalidates completed rename before configuration` | 9 sites |
| `testMountpointCleanupRefusesReplacedReservation` | `Mountpoint cleanup refuses replaced reservation` | 2 sites |
| `testSourceParentReplacementRetainsBothTrees` | `Source parent replacement retains both trees` | 3 sites |
| `testExternalDisconnectFinalizationCapturesRetainedLatestRAM` | `External disconnect finalization captures retained latest RAM` | 2 sites |
| `testDiskTrashBackupIsRetainedWithWarningAfterNormalRestore` | `Disk trash backup is retained with warning after normal restore` | 2 sites |
| `testInterruptedRestoreCopyRetainsBackupCheckpointAndHelper` | `Interrupted restore copy retains backup checkpoint and helper` | 6 sites |
| `testConfigWrittenBeforeIdleJournalCanResume` | `Config written before idle journal can resume` | 4 sites |
| `testLinkRenameCrashRestoresOnlyBoundOriginal` | `Link rename crash restores only bound original` | 3 sites |
| `testLinkIntentCrashBeforeRenameCleansOnlyOwnedStagedLink` | `Link intent crash before rename cleans only owned staged link` | 2 sites |
| `testRestoredDestinationReplacementBlocksConfigTransition` | `Restored destination replacement blocks config transition` | 5 sites |
| `testUnjournaledStagedLinkIsRetainedWithoutAdoption` | `Unjournaled staged link is retained without adoption` | 6 sites |
| `testInternalFilesystemPreflightFailureOccursBeforeReservation` | `Internal filesystem preflight failure occurs before reservation` | 2 sites |
| `testFailedPhysicalReadbackNeverPublishesOrActivatesAndCanEjectGuarded` | `Failed physical readback never publishes or activates and can eject guarded` | 8 sites |
| `testUnsafeMountRootModeRefusesBeforeEvacuation` | `Unsafe mount root mode refuses before evacuation` | 3 sites |
| `testCentralDecoderRejectsNonProductionRootWithoutFixtureContext` | `Central decoder rejects non production root without fixture context` | 2 sites |
| `testPublicSourceModeNormalAndTemporaryRestoresPreserveMetadataAndCleanWrapper` | `Public source mode normal and temporary restores preserve metadata and clean wrapper` | 8 sites |
| `testACLAddedAfterReservationBlocksOperationalReopen` | `ACL added after reservation blocks operational reopen` | 3 sites |
| `testWrapperCheckpointFailureRetainsUnknownWrapperAndUntouchedSource` | `Wrapper checkpoint failure retains unknown wrapper and untouched source` | 5 sites |
| `testCaseCollidingReservationNeverSuffixesOrAdoptsExistingDirectory` | `Case colliding reservation never suffixes or adopts existing directory` | 4 sites |
| `testConcurrentExactReservationsHaveOneExclusiveWinner` | `Concurrent exact reservations have one exclusive winner` | 3 sites |

New parameterized `In process followup acceptance` reuses these existing standalone cases: `equality`, `thaw`, `invalidation-failure`, `restore`, `restore-corrupt`, `restore-replay`, `restore-replay-split`, `uuid`, `legacy-large`, `occupied`, `symlink`, `cursor-replacement`. The reusable dispatcher takes the scenario explicitly; all branch decisions use that value rather than test-runner arguments.

### HoldingCleanupTests.swift

All 12 named cleanup/retention/recovery scenario groups, including repeated cycles, wide/deep trees and the latest-snapshot chain.

| Original method | Replacement test | Preserved body coverage |
| --- | --- | --- |
| `testCompletedSessionCleanup` | `Completed session cleanup` | `HoldingCleanupScenarios.run()` |

### LatestSnapshotTests.swift

Retention, transaction pins, failed-save preservation, conservative cleanup and anchored identity safety.

| Original method | Replacement test | Preserved body coverage |
| --- | --- | --- |
| `testLatestSnapshotRetention` | `Latest snapshot retention` | `LatestSnapshotScenarios.run()` |

### MountedFlagPolicyTests.swift

All 32 flag bits, directional masking, backend/journal/activation guards and exact snapshot flags.

| Original method | Replacement test | Preserved body coverage |
| --- | --- | --- |
| `testStrictDefaults` | `Strict defaults` | `MountedFlagPolicyScenarios.strictDefaults()` |
| `testDirectionalMask` | `Directional mask` | `MountedFlagPolicyScenarios.directionalMask()` |
| `testJournalPolicyAndGuards` | `Journal policy and guards` | `MountedFlagPolicyScenarios.journalPolicy()` |
| `testSnapshotFlagsStayExact` | `Snapshot flags stay exact` | `MountedFlagPolicyScenarios.snapshots()` |

### PopulationReadinessTests.swift

Transient reads, exact manifests/errno/deadlines, activation guards/status, negotiated/legacy startup, ACKs, retirement, native dispatch and wire decoding.

| Original method | Replacement test | Preserved body coverage |
| --- | --- | --- |
| `testTransientReadsRequireExactManifest` | `Transient reads require exact manifest` | `PopulationReadinessScenarios.transientReads()` |
| `testExhaustionAndPermissions` | `Exhaustion and permissions` | `PopulationReadinessScenarios.failures()` |
| `testMonotonicBounds` | `Monotonic bounds` | `PopulationReadinessScenarios.bounds()` |
| `testSnapshotPreservesErrno` | `Snapshot preserves errno` | `PopulationReadinessScenarios.structuredErrno()` |
| `testActivationOrderingAndOriginalGuards` | `Activation ordering and original guards` | `PopulationReadinessScenarios.activation()` |
| `testSessionReadinessAndActions` | `Session readiness and actions` | `PopulationReadinessScenarios.statuses()` |
| `testNegotiatedPopulationPrecedesMount` | `Population order follows negotiated capability [guarded: true]` | `PopulationReadinessScenarios.startupOrder(guarded: true)` |
| `testLegacyPopulationFollowsMount` | `Population order follows negotiated capability [guarded: false]` | `PopulationReadinessScenarios.startupOrder(guarded: false)` |
| `testStartupCapabilityAndACKRejection` | `Startup capability and ACK rejection` | `PopulationReadinessScenarios.startupCapabilities()` |
| `testStartupImportFailureNeverRequestsMount` | `Startup import failure never requests mount` | `PopulationReadinessScenarios.startupImportFailure()` |
| `testAbandonedStartupRequiresSealedRetirement` | `Abandoned startup requires sealed retirement` | `PopulationReadinessScenarios.startupRetirement()` |
| `testGuardedStartupRecoveryRetiresBeforeRollback` | `Guarded startup recovery retires before rollback` | `PopulationReadinessScenarios.startupRecovery()` |
| `testNativeGuardedStartupCommandAndOrder` | `Native guarded startup command and order` | `PopulationReadinessScenarios.nativeStartup()` |
| `testStartupJournalWirePresenceAndRecoveryConsistency` | `Startup journal wire presence and recovery consistency` | `PopulationReadinessScenarios.startupJournalWire()` |

### QuarantineSnapshotTests.swift

Exact quarantine copy/recovery, source-write/rename races, raw metadata/provenance integrity, authentic creator and explicit packaged-host acceptance.

| Original method | Replacement test | Preserved body coverage |
| --- | --- | --- |
| `testExactQuarantineSnapshotCopy` | `Exact quarantine snapshot copy` | `QuarantineSnapshotScenarios.run()` |
| `testEmitFreshCrossCreatorRenameFixture` | `Emit fresh cross creator rename fixture` | 3 sites |
| `testNFSEvacuationOfFreshTreePreservesRawEntriesAndInodes` | `NFS evacuation of fresh tree preserves raw entries and inodes` | 4 sites |
| `testNFSEvacuationRejectsRealWriteAndNewEntryBeforeRename` | `NFS evacuation rejects real write and new entry before rename` | 7 sites |
| `testNFSActivationRejectsOldFDWriteAndNewSourceEntry` | `NFS activation rejects old FD write and new source entry` | 9 sites |
| `testRenameWindowRejectsRealMutationsAndReplacement` | `Rename window rejects real mutations and replacement` | 11 sites |
| `testRenameSyncAndReadbackErrorsPreserveReasonAndIntent` | `Rename sync and readback errors preserve reason and intent` | 6 sites |
| `testCompletedRenameProofRejectsLaterRawChangeAndTampering` | `Completed rename proof rejects later raw change and tampering` | 10 sites |
| `testRenameJournalDecoderRejectsNullUnknownAndPartialAuthority` | `Rename journal decoder rejects null unknown and partial authority` | 9 sites |
| `testNFSRollbackVerifiesOwnReverseRenameAndRetainsConflicts` | `NFS rollback verifies own reverse rename and retains conflicts` | 8 sites |
| `testLegacyPendingJournalCannotAcquireRenameWaiver` | `Legacy pending journal cannot acquire rename waiver` | 4 sites |
| `testPackagedCLINFSFreshCreatorColdLoop` | `Packaged CLI NFS fresh creator cold loop` | 16 sites |
| `testFSKitWholeRootRenameAndTemporaryRollbackKeepInodeAuthority` | `FS kit whole root rename and temporary rollback keep inode authority` | 10 sites |
| `testPackagedCLIExportsGeneratedDSStoreAcrossCreatorLineages` | `Packaged CLI exports generated DS store across creator lineages` | `exportGenerated(names: [".DS_Store", "ordinary.txt"])` |
| `testPackagedCLIExportsOrdinaryFileAcrossCreatorLineages` | `Packaged CLI exports ordinary file across creator lineages` | `exportGenerated(names: ["ordinary.txt"])` |
| `testCopyStillRejectsNonProvenanceSourceMutation` | `Copy still rejects non provenance source mutation` | 7 sites |
| `testPackagedExportPreservesRawSourceAndCommittedIntegrity` | `Packaged export preserves raw source and committed integrity` | `exportGenerated(names: ["ordinary.txt"], checkRawIntegrity: true)` |
| `testCommittedCopyRejectsOtherMetadataAndContentTampering` | `Committed copy rejects other metadata and content tampering` | 5 sites |
| `testRelocationKeepsLegacyRevisionFilesAndExactCopyIntegrity` | `Relocation keeps legacy revision files and exact copy integrity` | 6 sites |
| `testObservedProvenanceAccountingAndLegacyRecords` | `Observed provenance accounting and legacy records` | 14 sites |
| `testCaptureAuthenticOtherCreatorTreeWithoutChangingSource` | `Capture authentic other creator tree without changing source` | 5 sites |

### ReviewAcceptanceTests.swift

ACL rejection, public/private root metadata, legacy manifests, 8 GiB apparent sparse copy, both comparison preferences, hardlink hash reuse, quiesce/thaw and independent-volume concurrency.

`ReviewAcceptanceRunner.main()` → `Review acceptance scenarios` (one new test; the entire original scenario chain is reused).

### SiblingInventoryTests.swift

Hierarchical hardlinks and independent FSKit root/ACL/finalization/configuration-identity/transaction serialization checks.

| Original method | Replacement test | Preserved body coverage |
| --- | --- | --- |
| `testNestedHardlinksMatchSnapshotManifest` | `Nested hardlinks match snapshot manifest` | `InventoryScenarios.run()` |
| `testNonPrivateSourceRootKeepsPrivateBackupAndCleansAfterRestore` | `Non private source root keeps private backup and cleans after restore` | 7 sites |
| `testPrivateModeMountRootWithPermissiveACLIsNotAdopted` | `Private mode mount root with permissive ACL is not adopted` | 3 sites |
| `testConcurrentHelperFinalizationAcceptsOnlyDurableRestoredIdentity` | `Concurrent helper finalization accepts only durable restored identity` | 4 sites |
| `testUnboundConfigurationInodeChangeStillBlocksTransaction` | `Unbound configuration inode change still blocks transaction` | 2 sites |
| `testBackupWrapperACLDoesNotBlockVerifiedRestore` | `Backup wrapper ACL does not block verified restore` | 4 sites |
| `testUnmountSerializesFinalizationWhenHelperAlreadyPublishedIdle` | `Unmount serializes finalization when helper already published idle` | 2 sites |

### SnapshotDescriptorTests.swift

Capture/remove a snapshot containing 160 populated directories; the existing standalone harness retains its 96-descriptor process limit.

`SnapshotDescriptorTests.run()` → reusable `SnapshotDescriptorScenarios.run()` → `Wide snapshot cleanup` (one new test). The standalone main still invokes the same body; no file-descriptor limit is applied to the shared SwiftPM/Xcode process.

### StorageFormatTests.swift

Both native export formats, tampering/immutability, legacy/current helper flows, restrictive receipts, exact names, mode pinning and actual process-exit recovery.

| Original method | Replacement test | Preserved body coverage |
| --- | --- | --- |
| `testRestrictiveNativeExportAdoption` | `Native export adoption [privateFormat: false]` | `StorageFormatScenarios.nativeAdoption()` |
| `testPrivateNativeExportAdoption` | `Native export adoption [privateFormat: true]` | `StorageFormatScenarios.nativeAdoption(privateFormat:true)` |
| `testStorageFormatTamperRejection` | `Storage format tamper rejection` | `StorageFormatScenarios.tampering()` |
| `testOriginalAndCommittedImmutability` | `Original and committed immutability` | `StorageFormatScenarios.immutability()` |
| `testRunningLegacyHelperSaveEject` | `Helper save and dirty eject [legacy: true]` | `StorageFormatScenarios.coordinator(legacy:true)` |
| `testCorrectedHelperSaveNoopDirtyEject` | `Helper save and dirty eject [legacy: false]` | `StorageFormatScenarios.coordinator(legacy:false)` |
| `testProcessExitPublicationRecovery` | `Process exit publication recovery` | `StorageFormatScenarios.crashRecovery()` |
| `testRestrictivePublicExportReceipt` | `Restrictive public export receipt` | `StorageFormatScenarios.publicExport()` |
| `testUnreadableOriginalAdmissionFailsUnchanged` | `Unreadable original admission fails unchanged` | `StorageFormatScenarios.unreadableOriginal()` |
| `testReadableReadOnlyDirectoryPublication` | `Readable read only directory publication` | `StorageFormatScenarios.readOnlyDirectoryRestore()` |
| `testFreshLogicalModeReceiptBinding` | `Fresh logical mode receipt binding` | `StorageFormatScenarios.freshModeReceipt()` |
| `testLegacyHelperDoesNotReadIncompatiblePriorPayload` | `Legacy helper does not read incompatible prior payload` | `StorageFormatScenarios.legacyBadPrior()` |
| `testRootlessLegacyCopyExportRestore` | `Rootless legacy copy export restore` | `StorageFormatScenarios.rootlessLegacy()` |
| `testOrdinarySourceHasNoReservedPathShape` | `Ordinary source has no reserved path shape` | `StorageFormatScenarios.sourceNames()` |
| `testFreshNormalizationPinsBeforeMutation` | `Fresh normalization pins before mutation` | `StorageFormatScenarios.normalizationReplacement()` |
| `testUnpinnableLegacyExportFailsClosed` | `Unpinnable legacy export fails closed` | `StorageFormatScenarios.unpinnableLegacy()` |
| `testOldPrivateHelperGetsNoFilteredPrior` | `Old private helper gets no filtered prior` | `StorageFormatScenarios.policyCapability()` |

### TrashExclusionTests.swift

Exact directory matching, legacy/V2 views, original retention, lifecycle/rollback, legacy exports and cross-boundary hardlinks.

| Original method | Replacement test | Preserved body coverage |
| --- | --- | --- |
| `testExactDirectoryCapture` | `Exact directory capture` | `TrashScenarios.capture()` |
| `testOldRevisionViews` | `Old revision views` | `TrashScenarios.oldRevisions()` |
| `testOriginalHoldingRetention` | `Original holding retention` | `TrashScenarios.holding()` |
| `testOwnedSimulatedLifecycleAndRollback` | `Owned simulated lifecycle and rollback` | `TrashScenarios.lifecycle()` |
| `testLegacyFreshExportExclusion` | `Legacy fresh export exclusion` | `TrashScenarios.legacyExport()` |
| `testCrossBoundaryHardlinks` | `Cross boundary hardlinks` | `TrashScenarios.crossBoundary()` |

## Standalone harness compatibility

All scenario runner call sites remain unchanged. The all-Swift typecheck in
`scripts/review-isolated-tests.py` now finds `TestingMacros` beside the compiler
selected by `xcrun --find swiftc`; without `-plugin-path`, direct `swiftc` cannot
expand Testing macros. Its existing log label is retained. Conditional imports
keep Testing and its macros out of standalone builds. Existing `@main`
declarations remain under their original flags; no duplicate mains are added.

| Harness / runner | Preserved entry point and conditions |
| --- | --- |
| `scripts/test.sh` → `review-isolated-tests.py` | Isolated project copy; core/app/CLI, all-Swift typecheck, script/native/protocol gates. Platform frameworks provide Testing; the compiler's Testing plugin path provides its macros. |
| `CoreTestRunner.swift` | `Scenarios.run()`; `RAMNEST_STANDALONE`. |
| `latest-snapshot-tests.sh` | `LatestSnapshotScenarios.run()`; `RAMNEST_LATEST_SNAPSHOT_STANDALONE`. Descriptor binary uses `RAMNEST_SNAPSHOT_DESCRIPTOR_STANDALONE`, process-only `ulimit -n 96`. |
| `holding-cleanup-tests.sh` / `HoldingCleanupTestRunner.swift` | `HoldingCleanupScenarios.run()`; latest + holding flags suppress the extra latest main; 96 FDs and 1 MiB stack stay process-local. |
| `population-readiness-tests.sh` / `PopulationReadinessTestRunner.swift` | Same six readiness calls; latest + holding + population flags; separate app-model runner. |
| `mounted-flag-policy-tests.sh` / `MountedFlagPolicyTestRunner.swift` | Same four policy and two readiness calls; adds mounted-policy flag to the above flags. |
| `attribute-absence-tests.sh` / `AttributeAbsenceTestRunner.swift` | Same four Swift scenarios under `RAMNEST_ATTRIBUTE_ABSENCE_STANDALONE`; native C++ path untouched. |
| `quarantine-snapshot-tests.sh` / `QuarantineSnapshotTestRunner.swift` | `QuarantineSnapshotScenarios.run()`, including `--interrupt-root-restore` child; `RAMNEST_QUARANTINE_SNAPSHOT_STANDALONE` and existing `RAMNEST_QUARANTINE_THROW_INTERRUPTION` alternative preserved. |
| `review-isolated-tests.py` review/followup/inventory binaries | Original review main flag; followup + latest + holding flags and all 18 parent cases/lock-child path; `RAMNEST_INVENTORY_STANDALONE` inventory main. |
| `storage-format-tests.py` and isolated storage gate | `RAMNEST_STORAGE_STANDALONE`; all original main dispatches, cold verification and crash children, native/old-native protocol fixtures and CLI paths. |
| `trash-exclusion-tests.py` | `RAMNEST_TRASH_STANDALONE`; all six original scenario calls and explicit owned root. |
| `backend-selector-tests.sh` | `BackendSelectorTestRunner.swift`, `BackendSettingsModelTestRunner.swift` and native no-mount gates unchanged. |
| Other script Swift helpers | `AppModelTestRunner.swift`, `PopulationReadinessModelTestRunner.swift`, `ControlTestClient.swift`, `OwnedTrashReadback.swift` retain their standalone roles. |

Python CLI/control/trash/owned-harness/package-provenance checks and native C++
tests are not migrated. None is counted as a Swift Testing declaration.

## Verification

Toolchain inspected: Apple Swift 6.4 (`swiftlang-6.4.0.34.1`), macOS 27.2
arm64. Installed Testing interfaces provide `#expect`, `#require`,
`Test.cancel`, enabled/serialized traits and the full public `SourceLocation`
initializer used by the sparse helper.

SwiftPM verification used `artifacts/test-modernization` for temporary
fixtures and `.build/test-modernization` for scratch/cache/config/security
directories, with the manifest sandbox enabled and host mount opt-ins removed.
An unrestricted full run still needs the original explicit native fixture and
packaged CLI bindings (notably `RAMNEST_STORAGE_*`,
`RAMNEST_STARTUP_CONTROL_FIXTURE`, `RAMNEST_TRASH_TEST_ROOT`,
`RAMNEST_PROVENANCE_CLI` and authentic creator fixtures). Missing required
fixtures must remain failures, not silently waived checks.

The requested SwiftPM invocation was:

```sh
env -u RAMNEST_RUN_OWNED_1GB -u RAMNEST_RACE_ALLOW_NFS_TEST \
  -u RAMNEST_RACE_CLI -u RAMNEST_HASH_TRACE \
  -u RAMNEST_SNAPSHOT_CROSS_DISK_PARENT \
  TMPDIR="$PWD/artifacts/test-modernization/tmp" \
  CLANG_MODULE_CACHE_PATH="$PWD/.build/test-modernization/clang" \
  SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/test-modernization/clang" \
  RAMNEST_TRASH_TEST_ROOT="$PWD/artifacts/test-modernization/trash-fixtures" \
  RAMNEST_STORAGE_TEST_ROOT="$PWD/artifacts/test-modernization/storage-fixtures" \
  swift test --scratch-path .build/test-modernization/swiftpm \
    --cache-path .build/test-modernization/cache \
    --config-path .build/test-modernization/config \
    --security-path .build/test-modernization/security
```

**SwiftPM exited 1 before test compilation or discovery:**
`sandbox-exec: sandbox_apply: Operation not permitted` while loading the manifest.
**Zero runtime tests executed.** The sandbox was not disabled. Evidence:
`artifacts/test-modernization/swiftpm-test.log`.

Compiler compatibility checks then used a fresh Debug RAMNestCore module emitted
from the unchanged current sources, the same Swift 6/macOS 27 target, local
module caches, the platform framework path and the installed Testing plugin:

| Check | Result | Evidence under artifacts/test-modernization |
| --- | --- | --- |
| Fresh core Debug module emission | Exit 0 | `core-module.log` |
| All 14 files, Debug test branch, macro expansion/typecheck | Exit 0, no diagnostics | `swift-testing-typecheck.log` |
| All 14 files, non-Debug test branch, macro expansion/typecheck | Exit 0, no diagnostics | `non-debug-typecheck.log` |
| 13 original standalone flag/runner configurations | All exit 0 | `standalone-typecheck-results.json`, `standalone-*.log` |
| Adjusted Python harness syntax | PASS (`ast.parse`) | `verification-summary.json` |
| Whitespace/scope/message inventory | PASS | `git diff --check`, `inventory.json` |

The 13 configurations cover core, latest, descriptor, holding, readiness,
mounted-policy, attribute-absence, quarantine process/throw branches, inventory,
review, followup and storage. Their exact compiler commands are in the JSON
record. These are compiler checks, not runtime scenario or link verification.
At that initial delegated checkpoint, runtime verification was still pending.
The parent-host results below supersede that limitation. No production/native
source, dependency or security configuration changed; no mount, real AppSupport
store, global setting, commit, push or reset was used.

## Parent-host runtime verification

The parent host can run SwiftPM with its manifest sandbox intact. The first
unconfigured SwiftPM/Xcode runs exposed missing required native/root bindings
and an obsolete default packaged CLI. These were test-environment failures;
no expectations, production behavior, or fixture requirements were weakened.

- `BuildProject(buildForTesting: true)` succeeded for the `RAMNest` scheme.
- Fresh Debug native products were built with `scripts/build-native.sh` under
  `artifacts/test-modernization/native`; **73/73 CTest tests passed**.
- A fresh standalone storage runner and core library were compiled from the
  migrated tests and unchanged current core under
  `artifacts/test-modernization/standalone`.
- Configured `swift test --scratch-path .build/modernization-parent
  --cache-path .build/modernization-cache` exited **0**: **144 test declarations
  in 22 suites passed**, with the live-mount opt-ins left disabled. This wording
  follows Swift Testing's declaration-level summary, not Xcode's case count.
- Configured `RunAllTests` on My Mac reported **169 results: 164 passed,
  0 failed, 5 skipped**. The complete results were read and counted independently
  (not inferred from the tool's first 100 rows).

The runtime environment explicitly bound:

| Variable | Product / owned fixture |
| --- | --- |
| `RAMNEST_TRASH_TEST_ROOT` | Owned `parent-fixtures/trash` or `xcode-fixtures/trash` below `artifacts/test-modernization` |
| `RAMNEST_STORAGE_TEST_ROOT` | Corresponding owned `storage` directory |
| `RAMNEST_STORAGE_FIXTURE` | Fresh `native/ramnest-storage-fixture` |
| `RAMNEST_STORAGE_PROTOCOL_FIXTURE` | Fresh `native/ramnest-storage-protocol-fixture` |
| `RAMNEST_STARTUP_CONTROL_FIXTURE` | Fresh `native/ramnest-control-tests` |
| `RAMNEST_STORAGE_OLD_PROTOCOL_FIXTURE` | Existing frozen legacy producer `artifacts/trash-exclusion-20261107/verification-fixtures/old-storage-protocol-fixture`; not replaced by a simulated current helper |
| `RAMNEST_STORAGE_COLD_RUNNER` | Fresh `standalone/storage-tests` |
| `RAMNEST_STORAGE_CLI`, `RAMNEST_PROVENANCE_CLI` | Current Xcode-built Debug app's `Contents/Helpers/ramnest`, not the stale default delivery artifact |

Xcode used a temporary verification scheme with these explicit environment
bindings and no excluded tests. Its configuration was archived as
`artifacts/test-modernization/verification-scheme.xcscheme`, then removed from
the project; the active scheme was restored to `RAMNest`.

The five Xcode skips are the parameterized owned 1 GB mounted benchmark
(reported as one skipped declaration), the packaged NFS live-mount loop, and
three authentic-provenance-dependent checks whose OS/creator observations or
explicit external-creator fixture were unavailable. The three benchmark inputs
explain **171 potential source cases versus 169 reported results** when that
whole declaration is disabled. SwiftPM and Xcode can observe different authentic
provenance depending on their creator lineage; neither path fabricated it.
No live-mount or Release runtime proof is claimed.

Evidence under `artifacts/test-modernization`:
`parent-configured-swift-test.log`, `parent-native-build.log`,
`parent-native-tests.log`, `parent-xcode-results.txt`, and the archived scheme.
The initial failing runs remain in `parent-swift-test.log` and the original
Xcode result bundle; they are not represented as passing runs.

Independent read-only review of the migration against HEAD found no blocking
findings. It checked original-method accounting, assertion/error/skip behavior,
parameterization, cross-suite serialization, standalone compatibility, and
test-data confidentiality. Production sources remained unchanged.
