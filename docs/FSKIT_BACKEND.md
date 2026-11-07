# Backend settings and FSKit validation

In RAMNest Settings, **Backend for next mount** selects the backend for the next
new mount of any folder. Selection is app-wide and is stored under the repository
lock in `configuration.json`:

| UI label | Configuration and helper id | Per-mount options |
|---|---|---|
| NFS | `nfs` | `backend=nfs` |
| FSKit | `fskit` | `backend=fskit` |
| SMB3 | `smb` | `backend=smb,listen_addr=127.0.0.1:0,nobonjour` |

The user's “fsdisk” choice maps to the UI label **FSKit**, with validated FUSE-T
id `fskit`. `fsdisk` and `smb3` are not valid persisted/helper ids.

NFS remains the default. Existing JSON without `backend` loads as NFS and retains
all existing app/folder fields. Explicit null, unknown strings, incorrect case,
and malformed types fail decoding; there is no fallback or silent migration.
Direct helper invocations without `--backend` also default to NFS; invalid,
missing-value and duplicate backend arguments return 64 before daemonization.

The owning AppModel loads and refreshes the preference, saves through Engine and
the repository lock, and updates the picker from persisted readback. A save
failure is shown in Settings, with a readback attempt to retain the confirmed
value. Changes neither unmount/migrate existing folders nor send live helper
commands. New sessions record an optional `Journal.backend` at preparation and
launch using that record. Mounted captions describe the recorded session,
regardless of the next preference. Old live journals lacking the field remain
explicitly “backend not recorded.”

SMB's listener and Bonjour options are fixed per mount to loopback with an
OS-assigned port and no advertising. No global `fuse-t.ini`, LAN advertising,
permissions, extension registration, installation, or macFUSE configuration is
changed. RAMNest never retries a failed mount using another backend.

## FSKit prerequisite and unresolved behavior

The [FUSE-T 1.1.0 release](https://github.com/macos-fuse-t/fuse-t/releases/tag/1.1.0)
documents `-o backend=fskit`, FSKit support on macOS 26+, and manual extension
activation through `/Applications/fuse-t.app`. RAMNest targets macOS 27+ and
continues using the private FUSE-T 1.2.9 headers and dylib.

Before an authorized FSKit mount check, open `/Applications/fuse-t.app` and follow
its instructions to enable the extension. Registration alone does not establish
activation. The existing external-volume `EPERM` remains unresolved; providing a
selector does not fix it. Settings and FSKit failure messages retain this
warning. Parser/SDK checks do not demonstrate a successful FSKit mount.

## Preserved mount behavior

The original full mountpoint, escaped original folder `volname`, session/volume
identifiers, `noattrcache,namedattr,use_ino`, and optional `nobrowse` remain.
Production still omits `renamex` for the existing wire-decoder workaround,
independently of backend selection. Ordinary rename, native extended rename,
stack handling, progress, metadata/decmpfs normalization, freeze, and root read
handles are retained. No new transport behavior is claimed for these callbacks.

## Focused no-mount verification

Run from the project root:

```sh
mkdir -p artifacts/backend-selector/logs
scripts/backend-selector-tests.sh > artifacts/backend-selector/logs/focused.log 2>&1
```

This builds the core and headless Settings model, typechecks the SwiftUI app,
and exercises native helper option construction through the installed
`fuse_opt_parse`, without calling `fuse_main`. Tests cover legacy configuration,
backend roundtrips/invalid values, repository persistence/readback, immutable
session journals, mount-preparation capture, recorded versus next arguments,
save failure/retry, captions, helper argument rejection, SMB exact options, and
filename injection attempts. A calibrated project-local Unix-socket recorder also checks zero live helper
commands during three real setter subprocesses on hosts that permit binding.
In the coding sandbox this check explicitly skips on bind EPERM/EACCES; journal
byte preservation is still checked by the Swift runner. All generated data
stays under `artifacts/backend-selector`. The mount-preparation test fails at oversized
snapshot capture before evacuation, socket creation, or helper launch. Expected
sandbox bookmark diagnostics are not mounted-filesystem results.

## Parent host handoff

The parent runs the host suite, package build, GUI checks and its own ephemeral
backend probes using isolated generated data and stores under project artifacts.
Verify selection persists after reopening Settings, a live mount keeps its
recorded caption/helper after a preference change, a subsequent mount uses the
new preference, and a legacy live journal remains unknown. For SMB verify the
actual listener is loopback only and no Bonjour service is advertised. For
FSKit verify extension activation independently and report the actual result or
external-volume EPERM. Check fixture population, read/write, ordinary rename,
hardlinks/xattrs, and eject/restore with the selected backend.

The [historical host report](VERIFICATION_RESULTS.md) and prior NFS artifacts
remain historical; their results must not be relabeled as FSKit or SMB3
validation. No actual mount, activation command or app packaging is part of this
sandbox implementation.
