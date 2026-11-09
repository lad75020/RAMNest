# Native memory and filesystem accounting

Production RAMNest uses macOS native tmpfs. The kernel allocates/reclaims backing
for ordinary files; RAMNest no longer maps/encodes/checksums 64 KiB RAM pages or
runs a custom LZ4 compressor. Capacity is a fixed maximum for that mounted session,
not a reservation of payload bytes. Filesystem allocation must grow with writes
and fall with truncation/unlink after references are released.

Native `used` is `(f_blocks - f_bfree) * f_bsize`; native capacity is
`f_blocks * f_bsize` from the actual bound tmpfs `statfs`. Both include filesystem
metadata, including OS root bookkeeping. They are neither a sum of file lengths
nor process RSS, physical RAM attribution, app compression savings or swap usage.
Native JSON omits deprecated `contentBytes`, `payloadBytes`, `mappedBytes` and
`backingSavingsFraction`; old status JSON still decodes. UI displays actual native
capacity separately from the folder's configured maximum.

The parent exact-package probe writes 16 MiB of random owned content, truncates
to 4 MiB, then unlinks it with all fds closed. It asserts substantial kernel
allocation growth/release and unchanged capacity, allowing metadata overhead.
It records raw host `vm_stat` alongside those readings. A shared-host memory
reading is context, not an isolated physical RAM reclaim measurement. Open or
mapped/unlinked files can retain resources until their last reference is gone.

macOS can compress/swap memory. RAMNest neither disables swap nor guarantees zero
SSD writes or secure erasure. Source conversion, snapshots, live exports and
restoration intentionally write durable disk data. File-verification preferences
apply to snapshots, not ordinary kernel page I/O.

The measured native size-update command returned exit 0 while capacity remained
unchanged. Live resize therefore rejects before configuration changes. Offline
capacity edits are checked against admitted folder contents and apply at the next
mount. The legacy snapshot admission estimate remains conservative and preserves
its overflow/metadata/hardlink/sparse safety rules; it is not a native live-memory
counter. The former compressor, memory-page engine and their benchmarks/tests are
removed. Sparse file hashing remains a snapshot data-format concern only.
