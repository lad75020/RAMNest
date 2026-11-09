# Native helper operations

The [native protocol](NATIVE_TMPFS.md) is the complete runtime interface. Root
controls are bounded one-shot operations on protected owned slots. An ordinary
user pin serves only status/capabilities/period/retire and cannot perform root I/O.
Snapshot copying and private-store integrity verification run directly in Swift
as the ordinary user, without an old engine export/import/activation protocol.

Read-only is verified using actual type/path/fsid and the kernel flag. Snapshot
freeze additionally requires a complete privileged mapping/reference scan.
A current-RAM checkpoint is promoted only after strict source and independent
copy validation. Failed mapping checks invalidate eject receipts before a verified
thaw; missing authority/durability retains a guarded mount. Ignore Busy does not
bypass the scan. No client command can export a tree after native unmount.

Native pin replies are one bounded newline frame: `OK` plus tab fields, or
`ERR` plus a positive errno. Same-uid peer checks, no-SIGPIPE and fixed monotonic
receive/send deadlines remain. Progress frames and former long-running helper
export commands are not part of this protocol. The mapping detector has its own
bounded transcript/deadline and rejects diagnostics or incomplete results.

Administrator execution first authenticates the selected signed package/helper,
then verifies a fresh root-owned staged image before running it. The mutable
packaged helper pathname is never executed as root. See [the native protocol](NATIVE_TMPFS.md)
and [trust/stage cleanup details](../SECURITY.md).

Periodic frames include minutes, schedule-ticket UUID (dash when disabled), and
immutable session verification policy. Internal periodic-save CLI argv additionally
binds folder/session/fsid/pin socket. The coordinator checks the request after the
volume lock and before authorization/promotion. A pin retires only its own child;
old work cannot save a successor or bypass a newly disabled schedule.
