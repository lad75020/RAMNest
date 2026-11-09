# Temporary mode and durability

Temporary eject uses a verified read-only native mount control, retires the pin,
normal-unmounts and restores the original folder objects. It does not capture
current RAM contents. Explicit live export is the opt-in rescue path and uses the
same mandatory mapping guard as synchronized snapshots. Periodic save is disabled
when synchronization is off.

The initial source checkpoint, original holdings and any explicit export remain
on disk according to the existing retention policy. macOS can compress/swap
memory; temporary mode is not secure erasure or a zero-disk-write guarantee.
Forced native unmount loses unsaved work. Test only fresh disposable fixtures;
never erase snapshots/stages to make a privacy assertion appear to pass.
