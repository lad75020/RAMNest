# Helper traversal and control replies

Import and export use iterative depth-first walks. Directory metadata is applied
after its children, preserving timestamps and flags. Walk frames and page-sized
scratch are on the heap: import reuses one 64 KiB buffer, export reuses two, and
read/write/truncate/encode use bounded heap block scratch. Directory depth does
not multiply automatic page buffers or recursive traversal calls. Hardlink maps,
sparse zero handling, logical decmpfs normalization, per-block checksums, export
fsync/readback verification, and capacity-scaled metadata accounting still apply.
Scope guards restore population/export freeze state on both returned errors and
exceptions. A successful quiesce leaves the tree frozen.

This fixes a reproduced helper stack overflow: sanitized installed-app reports
showed `Thread stack size exceeded`, SIGBUS, and repeated import frames beneath
`MemoryFS::write` and `MappedPage::encode`. A generated 24-level tree with one
64 KiB leaf reproduced SIGBUS on a 512 KiB pthread. Progress reporting addresses
a separate control timeout problem; it cannot repair a crashed helper.

The private Unix stream protocol accepts one newline-terminated command per
connection. Ordinary replies retain `OK` (optionally tab-separated fields) and
`ERR\terrno`, each terminated by a newline. Population, export, and quiesce may
first send `PROGRESS\tsequence\n` frames. The sequence is a positive, monotonically
increasing count of completed work units relative to that request, not a percent
or heartbeat. Completed import chunks, exported writes/verified blocks, entries,
and metadata work advance a lock-free atomic counter. The observer reads that
counter without acquiring the tree mutex. It emits a frame only when work has
advanced, sampling at 100 ms while the job runs.

The client treats the existing 180-second timeout as rolling inactivity for
these three operations. Only complete, advancing progress frames renew it;
partial bytes, repeated counters, and interrupted system calls do not. Each
frame is limited to 8192 bytes excluding its newline, including final replies.
Malformed, oversized, regressing, and unterminated frames fail explicitly. A
quiet peer times out; EOF/disconnection and truncated frames have distinct
operation-specific errors. Short status/metrics probes keep their fixed
two-second caller deadline and accept no progress extensions. Final `OK`/`ERR`
is required even after progress. Connect/peer UID checks and no-SIGPIPE writes
remain in place.

Mutating requests remain serialized. The serving loop joins a long job before
accepting another request, even if sending progress/final results fails. The
worker owns no socket writes and is never cancelled because a client left. A
stalled worker emits no fabricated keepalive. A timeout/disconnection performs
no automatic retry, deletion, recovery, or rollback; the helper may still be
finishing its data-preserving job.

## Focused regression

The normal native memory test target includes a 512 KiB pthread test with a
64-level generated tree, compressed/raw block readback, hardlinks, symlinks,
metadata, sparse zeros, patch/truncate/regrowth, capacity failure, and injected
exception freeze restoration. `ramnest-control-tests` still runs its existing
mount-argument and freeze-only tests. Its optional socket-fixture mode runs the
production `control` / `serveControl` / `command` implementation, without FUSE
mounts, on generated 640 KiB data with injected read/write delays and EINTR.

Compile `scripts/ControlTestClient.swift` against a test-enabled RAMNestCore.
Then run the socket suite using the built native and Swift binaries:

```sh
python3 -B scripts/control-tests.py \
  --client artifacts/helper-timeout-fix/control-test-client \
  --native artifacts/helper-timeout-fix/native-build/ramnest-control-tests
```

It covers successful real work past a one-second inactivity timeout, stalls,
client abandonment with completed retained data, a killed peer, helper errors,
incomplete requests, fragmented/invalid/oversized/truncated reply frames,
unchanged progress counters, fixed short probes, and signal interruptions. The
pathname suite additionally checks a status request queued behind a long export.
For sandboxes that deny pathname `bind`, add `--socketpair`: that uses permitted
anonymous AF_UNIX pairs through the shared production connected-socket exchange
and helper serving boundary. It does not verify pathname connect/accept or the
queued-probe path; run the default suite on the host for those checks. Both modes
leave generated fixtures, result JSON, and logs under `artifacts/helper-timeout-fix`.
