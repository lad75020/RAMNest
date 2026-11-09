# Security and data boundaries

RAMNest is a local macOS application. Its production I/O path is native tmpfs,
with no FUSE transport, app page compressor or RAM-page checksum engine. It does
not change SIP/TCC/swap/security settings, install a privileged service, contact
network services, read credential files or handle administrator credentials.

Mount controls use bounded one-shot macOS administrator authorization. The
packaged C++ helper accepts only allowlisted operations, uid, canonical UUIDs,
numeric capacity and recorded inode/fsid authority; it derives every root path
inside a fixed internal runtime namespace. No store/source/executable/shell
argument is accepted in privileged mode, and no root IPC process remains.
Before the authorization dialog, the running app/embedded CLI requires its
co-located signed app/helper, validates running-code and static signatures plus
the bundle's sealed resources/native provenance, and hashes a pinned regular
helper descriptor with stable inode/content checks. Path-based signature/seal
success does NOT bind a later mutable receipt to the bytes observed during that
validation. The mandatory byte decision therefore requires BOTH the pinned
helper SHA-256 and receipt engine/hash/configuration to match immutable authority
compiled into the Core code actually running in the GUI/embedded CLI. A matching
self-signed replacement and forged receipt cannot replace that expected value.
No manifest, environment, IPC, default hash or runtime path supplies it.
Ad-hoc development signatures are not a claim of
Apple/notarized publisher trust; the user authorizes this selected package.

Core's prebuild builds and finalizes/signs the native helper FIRST, then generates
the expected engine/SHA-256/configuration Swift source and provenance from those
final bytes. That explicit generated source is compiled into Core before either
client can link. The app only embeds the same configuration-scoped artifact; it
does not rebuild or re-sign a different helper after Core compilation. Missing
generated authority fails compilation, and incoherent generation/embedding fails
the build. `native-build-identity --json` reports linked constants without opening
a store. See the native protocol document for source/output paths and verification.

The elevated command invokes only fixed system utilities before any helper code:
it validates the root/sticky-protected Shared parent, creates a fresh root-owned
0700 `.RAMNestNativeExec.*` directory, copies at most the captured image length
into a new root-owned file, verifies its exact SHA-256 (including signature bytes)
and all-architecture code signature, then executes that protected 0500 copy.
The user-writable source pathname is never executed as root. Source replacement
or tampering fails staged verification before custom code runs. The protected
directory prevents replacement between verification and execution. Arguments are
shell-quoted before AppleScript escaping, with a sanitized environment. No image,
digest or executable selection is accepted through helper IPC/environment.

An exit/signal trap verifies the stage's recorded device/inode/owner/mode, removes
only its exact helper file and then the empty directory. No recursive cleanup or
pre-existing-directory ownership/mode repair is performed. Cleanup uncertainty
returns failure and retains evidence; a killed bootstrap or power loss may leave
a private root-owned stage requiring explicit inspection. Parent security review,
signing/injection/cancellation/cleanup and exact-package probes remain required.

The fixed mount parent and slots are root-owned, with non-writable directory
modes and no extended ACL. Ancestors are opened without symlink traversal; root
controls check internal filesystem, exact type/path/fsid, inode ownership/modes,
capacity bounds and the read-only flag. The protected slot lock serializes
controls and holds a root-only identity/fsid/capacity receipt checked before
destructive operations. Pre-existing directories are never repaired/chowned. Only the newly
created mounted workspace is handed to the user by descriptor. Ordinary unmount
has no force flag. Release removes only exact bound empty runtime objects.

The independent pin/socket/periodic coordinator runs as the ordinary uid. It
refuses elevated execution, uses a fresh private socket name, checks peer uid,
holds the verified mount and removes only its own socket inode. Its IPC cannot
mount, copy as root or execute a privileged command. Periodic child CLIs remain
unprivileged and use the same volume/repository locks and administrator control
boundary as user operations. Each queued worker carries session/fsid, pin socket,
verification policy, interval and a replaceable schedule ticket. It checks all
authority/configuration after taking the volume lock, before authorization and
before checkpoint promotion. Disabled/replaced/retired work cannot save a successor
session. Scheduling changes and retirement reap only the pin's own unreaped save
child; no user writer or IPC-supplied PID is signalled.

A read-only remount alone cannot freeze existing writable shared mappings on the
measured platform. Before snapshot copying, the root helper therefore runs a
bounded filesystem-wide mapping/reference scan. All regular references in the
logical tree, including fd-closed `txt` mappings and read-only file fds, reject.
Warnings, errors, timeouts, malformed/partial records, unknown types/paths and a
missing self-observed mount pin fail closed. The only regular-reference exemption
is OS-owned `.fseventsd` outside the logical tree. Ignore Busy cannot bypass the
gate. This accepted close-writers policy assumes cooperative clients; it is not
atomic mapping revocation against adversarial cross-process reference handoff.
Writers are never killed. Strict source-before/after and independent snapshot
copy verification remain mandatory.

Every repository, revision and holding wrapper retains its private ownership and
identity policy. Verified durable capture precedes original moves. Atomic journal
replacement, no-follow anchored directory handles, no-replace rename/swap,
immutable revision validation, sparse/hardlink/xattr/mode checks and narrow
provenance normalization remain unchanged. Unknown entries, unsupported metadata,
source changes, incomplete captures and damaged snapshots retain recovery data.
Cleanup is limited to journal-authorized verified siblings/revisions; there is no
broad purge or automatic fallback to another backend.

Native journals and linked layouts have separate discriminators from legacy
FUSE sessions. Legacy configuration values are preserved on decode. Malformed,
null, mixed, unknown or partial authority cannot fall back to a less strict
recovery branch. Native RAMNest does not mutate a live legacy helper/mount.

A managed session pins its mount to discourage normal external eject. A forced
unmount, kernel loss or power loss can destroy unsaved native data. No helper-held
export survives that destruction. Explicit recovery restores only a verified
committed disk checkpoint or the intact temporary-mode originals, with durable
loss disclosure. RAMNest does not silently relabel disk snapshots as current RAM.
Busy/unknown/replaced mounts remain fail-closed.

macOS manages compression and swap, so volatile memory does not imply zero disk
activity or secure erasure. Native statfs accounting is not physical RAM/RSS.
Optional size/mtime snapshot verification can miss same-size edits with restored
mtime; SHA-256 remains the default. Metadata/control-record integrity and path,
inode, topology and provenance checks remain enforced in either policy.

Parent acceptance must verify the exact packaged helper, signatures/dependencies,
administrator/cancellation behavior, mapping guard, lifecycle/recovery and GUI.
No runtime or notarization acceptance is inferred from source/static checks.
