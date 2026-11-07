# FSKit original-path symlink layout

## Scope

New FSKit sessions keep the user-facing `Folder.path` but mount physically at:

```text
/Users/Shared/RAMNest-Mounts-<uid>/<original folder basename>
```

This is the user-selected, writable internal alternative to `/Volumes`. No
administrator prompt, privileged helper, global permission change or backend
fallback is introduced. The FUSE-T extension must still be enabled manually.
NFS, SMB and existing FSKit journals without `fsKitLink` keep their direct-mount
behavior. Changing the next-backend preference does not migrate a running session.

The internal root is owned by the current user with mode `0700`; other-user
traversal is therefore more restrictive than a public original directory. Its
ACL/access policy is checked independently of backup ACLs. Two managed folders
with the same physical basename cannot mount concurrently under this root:
RAMNest refuses the collision before moving the source rather than appending a
suffix or adopting an existing directory. The display alias does not change the
physical basename.

## Mount transaction

1. Validate and exclusively reserve the internal mountpoint before source changes.
2. Capture and independently verify the original snapshot.
3. Create a private `.ramnest-<folder UUID>-<session UUID>.original` wrapper beside
   the original path. Move the complete original directory into its `data` child,
   preserving original objects and metadata without chmod-ing the original.
4. Populate a guarded helper before mounting and mount at the recorded internal
   target. Verify the physical mount, its contents and the retained originals.
5. Create a staged symlink, record its identity/target, and publish it without
   replacing an unrelated entry at the original path. Journal readiness before
   activating RAM writes.

The public path is the logical access path; it is not used to authorize physical
unmounts or to copy restoration data through a symlink. Generic symlink rejection
remains enabled. Only the exact journal-owned runtime link is accepted.

## Eject and recovery

Synchronized eject freezes RAM and obtains a verified durable checkpoint. It
unmounts the physical target while the native helper retains the RAM tree. The
coordinator materializes verified data on the original filesystem, records the
new directory identity before publication, and atomically replaces its owned
link. It verifies the result and commits the folder inode/bookmark before idle.
Ordinary verified backups are then removed through the existing durable cleanup
plan. The caller crosses the finalization lock before returning, including when
the helper completed restoration concurrently. RAM is not released before the
native finalizer has completed the restore path.

Temporary mode instead returns the original directory object and discards RAM
changes. It does not export RAM-only changes unless explicitly requested with
`export --live`. Original disk `.Trashes` directories retain the existing policy:
the opaque backup is preserved with a cleanup warning, never recursively purged.

Backup ACL equality is not an acceptance requirement. An otherwise accessible
backup wrapper is not rejected merely because its ACL differs. Identity,
contents, private-wrapper mode and safe cleanup checks still apply. Live mount
root ACL checks remain strict; underlying access-denied errors are not bypassed.

`Journal.fsKitLink` has a strict version-1 layout with recorded parent, wrapper,
source, mount reservation, link and restored-directory identities. Only a wholly
absent record selects legacy behavior. Null, partial, unknown or incoherent
records fail closed. A concurrent old-to-restored configuration inode transition
is accepted only with the matching durable session receipt and observed anchors;
unrelated configuration replacements remain blocked.

Ambiguous objects created before an identity checkpoint, interrupted unverified
materializations, unsupported metadata/topology, inaccessible final-mode trees,
and identity substitutions retain recovery data instead of being guessed away.
Some such states require exporting the latest verified revision and manual
recovery. This is not a claim of automatic recovery for every host failure or
of preservation of uncommitted writes after helper death/power loss.

## Local verification

The implementation was exercised through `BuildProject`, enabled XCTest cases
using `GetTestList`/`RunSomeTests`/`RunAllTests`, and the exact copied Release
app's CLI/helper. The host matrix covered repeated internal-source normal,
external-source normal and external-source temporary lifecycles, physical mount
and symlink checks, mounted read/write versus helper exports, metadata checks,
backup removal, and refreshed folder authority. Separate real-host tests covered
foreign reservations and a replaced public symlink without losing RAM or the
replacement directory. GUI smoke used an isolated store and normal termination.

The full-suite result is recorded in the delivery artifacts. The known
`StorageFormatTests/testRootlessLegacyCopyExportRestore()` failure on
`com.apple.provenance` also occurs with the pre-existing CLI and remains outside
this change; it is not suppressed or counted as a pass. Historical NFS reports
are not FSKit runtime evidence. No app installation, Git commit or push is part
of this local implementation.
