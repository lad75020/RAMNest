# Snapshot file verification

SHA-256 is the default. The optional `sizeAndModTime` policy compares regular-file
size and modification time instead of hashing file contents during snapshot
capture/readback. It can miss a same-size edit whose mtime is restored. It does not
promise content-corruption detection. Xattrs, symlink targets, bounds, structural
metadata, manifest/mode-map digests, hardlink topology, path/inode authority and
narrow provenance rules retain their checks in either policy.

The preference applies to new sessions. Each session/revision records its own
policy; changing Settings cannot reinterpret a retained revision or an active
session. Missing legacy fields decode as SHA-256. Explicit null, unknown policies
and conflicting journal/manifest authority reject rather than downgrading checks.

```sh
ramnest --store /absolute/owned/store file-verification
ramnest --store /absolute/owned/store file-verification sha256
ramnest --store /absolute/owned/store file-verification sizeAndModTime
```

Snapshot comparison (`checksum` or `sizeAndModTime` incremental file selection)
remains independent of immutable file verification. Native capture uses the
existing copy/integrity/provenance transaction and private storage format.

Native macOS tmpfs handles ordinary kernel file I/O. This setting does not add or
remove RAM-page checksums, compression, encode/decode passes or filesystem
callbacks. There is no production LZ4 page engine. Only persisted data-format readers/fixtures retain legacy compatibility; old
helper execution and page-engine tests have been removed.

Native snapshot capture also requires read-only remount, exact type/fsid/flag
verification and a complete privileged regular-vnode/mapping scan. Size/mtime
selection never bypasses that close-writers guard or changes the external-unmount
loss contract. See [native backend](NATIVE_TMPFS.md) and [recovery](RECOVERY.md).
