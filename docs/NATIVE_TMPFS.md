# Native tmpfs backend and bounded helper protocol

New mounts always use `Configuration.Backend.tmpfs`. The package contains the
system-only C++ helper and Swift app/CLI/core. The former engine, callbacks, protocol fixtures, optional build switches and
benchmarks have been deleted; there is no alternate executable backend.

`Journal.nativeLink` uses the shared `LinkedFolderLayout` transaction's version 2;
`Journal.nativeTmpfs` is a separate strict version-1 native record. Legacy
`fsKitLink` is still version 1 and cannot contain native authority. Mixed fields,
explicit null, unknown native fields/versions, mismatched uid/session/backend and
incomplete mounted authority reject. A fresh preparation before reservation is
readable but cannot claim a native mount. Snapshot formats and file verification
policies retain their old discriminator rules.

The shared transaction primitives are named `LinkedFolderLayout` and
`LinkedFolders`. The old wire key `fsKitLink` is decoded into `legacyLink` only;
it is not a runtime backend. Native authority remains separate. Parent,
original, holding wrapper, link, restored data and underlying reservation inode
identities retain their original fail-closed checks. Native flags receive no
FUSE mounted-view relaxation. The OS `.fseventsd` root is outside `tree/data`, not
a new snapshot exclusion.

## Administrator operations

The app authenticates/captures its co-located signed helper and sealed package
provenance before the dialog, then invokes a fixed system-utility bootstrap via
`osascript` Standard Additions `do shell script … with administrator privileges`.
The bootstrap creates a fresh root-owned 0700 stage under `/Users/Shared`, copies
only the captured bounded image length, checks its full SHA-256/signature, and
executes that root-owned protected copy. It never executes the mutable source
pathname. Exact exit cleanup is identity-bound and non-recursive. See
[security/trust details](../SECURITY.md); development ad-hoc integrity is not
publisher/notarization trust. No arbitrary image/digest arrives through IPC.
There is no password argument, credential capture or root IPC server. Exact argv:

```text
ramnest-helper --capabilities
  -> native-tmpfs-v1
ramnest-helper --native-v1 reserve UID SESSION_UUID
  -> OK ROOT_DEVICE ROOT_INODE UNDERLYING_MOUNT_DEVICE UNDERLYING_MOUNT_INODE
ramnest-helper --native-v1 mount UID SESSION_UUID RD RI MD MI CAPACITY_BYTES true|false
  -> OK FSID_WORD_0 FSID_WORD_1 ACTUAL_STATFS_CAPACITY
ramnest-helper --native-v1 readonly UID SESSION_UUID RD RI MD MI FSID0 FSID1 CAPACITY_BYTES
  -> OK
ramnest-helper --native-v1 freeze UID SESSION_UUID RD RI MD MI FSID0 FSID1 CAPACITY_BYTES
  -> OK no-regular-vnode-references-v1 FSID0 FSID1
ramnest-helper --native-v1 thaw|unmount UID SESSION_UUID RD RI MD MI FSID0 FSID1 CAPACITY_BYTES
  -> OK
ramnest-helper --native-v1 release UID SESSION_UUID RD RI MD MI
  -> OK
```

Replies are tab separated and newline terminated. Decimal values are unsigned;
fsid words retain their UInt32 bit patterns. Canonical UUIDs use uppercase.
The helper derives `/Users/Shared/RAMNestNative-UID/SESSION_UUID/mount`; root mode
accepts no caller path, store, command, script or executable argument. It bounds
capacity to 16 MiB–75% physical memory, rejects resize, validates a local uid and
checks root-owned modes, no ACL, no symlink traversal, internal filesystem and
recorded root/underlying mountpoint identities. Controls serialize on the protected
slot lock. Its root-only bounded receipt binds uid/session, underlying inode,
fsid and immutable capacity; caller values must match before destructive control. Existing directories are never repaired/chowned. Only the new tmpfs
workspace is handed to the ordinary uid using its freshly opened descriptor.

Mount executes exactly `/sbin/mount_tmpfs -e -o nobrowse,nosuid,nodev -s BYTES MOUNT`
(or omits `nobrowse` for the folder's visibility preference). Controls use
`mount_tmpfs -e -o update,rdonly,nosuid,nodev -s ORIGINAL_BYTES MOUNT` or
`mount_tmpfs -e -o update,rw,nosuid,nodev -s ORIGINAL_BYTES MOUNT`,
retaining the observed `nobrowse` flag. No size update is
represented as resize. Unmount executes ordinary `/sbin/umount MOUNT`, never `-f`.
Release removes only the identity-bound empty underlying mount directory, its
control lock and the empty session directory; it is not recursive cleanup.
The fixed parent can remain for other sessions.

`readonly` is solely a kernel state change used for unpublished population or
explicit temporary discard. It is not a current-RAM checkpoint receipt.
`freeze` also verifies tmpfs type/path/fsid and read-only flag, then runs the fixed
root `lsof -nP -F pcftn +f -- MOUNT` detector with bounded capture/deadline. Every
logical regular vnode reference is rejected, including `txt` with no fd. The
only regular-reference exemption is protected OS-root `.fseventsd/`, outside the
logical user tree. Unknown vnode types/fields, unresolved paths, warnings, partial
records, nonzero exit, timeout and failure to see the scanner's own mount-root
DIR fd reject. The helper returns no caller-controlled process/file data.

The scan is conservative and requires cooperative writer quiescence. It is not
atomic kernel mapping revocation against malicious descriptor transfer/fork.
Root checks and Swift independent source/copy/readback validation remain required
in addition to the scan. Ignore Busy only affects the advisory user busy list.

## Ordinary-user pin

```text
ramnest-helper --daemonize --pin-v1 UID SESSION_UUID FSID0 FSID1 SOCKET FOLDER_UUID CLI STORE
```

This mode refuses uid 0/elevated execution. It pins only the bound mount root,
checks a fresh private user socket parent and never unlinks a predecessor socket.
It accepts same-uid newline-framed `status`, `capabilities`,
`period<TAB>MINUTES<TAB>AUTHORIZATION_UUID_OR_DASH<TAB>FILE_VERIFICATION`
and `retire` only. It has no mount, root command, copy or export IPC operation.
`status` retains the six-field common reply, with actual statfs allocation/capacity
and kernel read-only state. `retire` closes the pin before acknowledgment and
removes only its own socket inode. Periodic saves spawn the CLI as the ordinary
user using:

```text
ramnest --store STORE internal-periodic-save FOLDER_UUID SESSION_UUID FSID0 FSID1 FILE_VERIFICATION MINUTES AUTHORIZATION_UUID SOCKET
```

The journal commits a fresh schedule ticket before each schedule change (zero
minutes uses a dash and clears the ticket). A delayed worker validates
session/fsid/socket/ticket/policy and current synchronized/periodic/interval settings
after taking the volume lock, before any prompt and before checkpoint promotion.
The pin retires/reaps only its own pending child on schedule changes/retire. The
post-lock fence remains mandatory across crashes/remounts; no stale work may save
a successor session, even if its folder UUID is unchanged.

Managed eject freezes, verifies and durably commits the checkpoint/eject receipt,
retires the pin, verifies the same frozen fsid, and requests normal unmount.
Only an acknowledged unmount followed by verified absence commits
`nativeTmpfs.managedUnmount = true`. A pre-unmount checkpoint receipt alone
cannot distinguish a completed managed eject from externally forced loss.
An unmount failure invalidates old eject authority before a verified repin/thaw.
An externally forced disappearance cannot export RAM; explicit recovery selects
only a committed disk revision and discloses unsaved loss.

`reconnect REF` repins an exact surviving, verified mounted session and restores
its periodic-save schedule without thawing it. An explicit `mount REF` may thaw
that verified session after invalidating any stale quiescence receipt; it never
creates a replacement mount over uncertain state.

## Compiled byte authority and build order

Path-based bundle validation cannot authenticate independently captured helper/
provenance bytes across a resource-swap race. `NativeHelperImage.capture` therefore
requires the descriptor's digest AND receipt engine/hash/configuration to equal
`NativeHelperCompiledAuthority.current`, whose values come only from generated
Swift constants in the actual running Core image. This mandatory decision precedes
any image return/osascript call. Signature/inode checks remain defense in depth;
the protected root staging described above still binds execution after the dialog.

`RAMNestCore` owns the single producer prebuild. It compiles and ad-hoc signs the
helper before writing native provenance, then generates:

- `$(DERIVED_FILE_DIR)/RAMNestNativeAuthority/NativeHelperBuildIdentity.swift`, an
  explicit `type: file`, Compile Sources member of Core. Generation-time optional
  path validation permits a clean checkout; it does not make compilation optional.
- `$(BUILT_PRODUCTS_DIR)/RAMNestNativeAuthority-$(CONFIGURATION)/`, holding the
  exact finalized helper, native receipt, matching generated-source copy and
  completion/hash marker. Debug/Release are separate.

Core compilation consumes the derived source; CLI and GUI depend/link Core. The
app has no independent helper rebuild. Its embed phase verifies/copies the shared
producer output. All native/source/script inputs and generated/source/helper/output
directories are declared while `ENABLE_USER_SCRIPT_SANDBOXING` remains YES. The
direct build script uses the same producer before Core compilation, explicitly
includes the generated source and never re-signs the helper after its receipt.
The native authority generator has no default/missing/placeholder identity.

`native-build-identity --json` is a read-only embedded-CLI diagnostic before store
opening. The exact-package probe compares its linked constants to final helper
bytes and provenance before creating fixtures. A changed helper requires fresh
native signing/provenance, regenerated source, Core/client recompilation and a new
package. Updating only mutable manifests cannot authorize the new bytes.
