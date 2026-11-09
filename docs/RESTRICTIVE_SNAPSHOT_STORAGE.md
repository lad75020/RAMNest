# Private snapshot modes and restrictive publication

Private revision payloads use accessible owner-only physical modes, with an
authenticated logical mode map. Existing unversioned snapshots and version-2
manifest/mode-map data remain readable under strict discriminator and digest
checks. There is no legacy helper export/normalization execution path.

Capture/copy verifies source-before/source-after and independent destination
observations, preserving modes, xattrs, hardlinks, sparse bytes and the narrow
provenance policy. Materialization finalizes exact logical modes only after the
accessible private copy is verified. Publication receipts bind destination,
manifest digest, inode observations and phase. Unknown, incomplete, replaced or
unreadable publication evidence fails closed; recovery never guesses by path.

Native snapshot copying needs ordinary-user read access. Working entries changed
to unreadable modes can block Save; root privileges are intentionally limited to
mount controls and do not bypass data permissions. The app does not silently
chmod source entries or skip inaccessible files. Existing authenticated private
snapshots can retain restrictive logical modes for receipt-bound recovery and
publication, including mode-zero evidence where the established transaction can
prove it. Parent exact-package validation remains required for those cases.

An invalid prior revision is not reusable copy authority. A new capture may copy
its current verified source afresh; damaged old data remains retained and cleanup
still verifies every anchor/candidate before deletion. Corruption is never fixed
by rewriting a committed snapshot or weakening provenance checks.
