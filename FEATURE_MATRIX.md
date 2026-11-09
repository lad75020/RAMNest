# Native storage feature matrix

Source implementation and static diagnostics are not exact-package acceptance.
The parent owns current Xcode/GUI/admin/lifecycle validation.

| Feature | Native implementation contract |
|---|---|
| Ordinary file I/O | macOS tmpfs kernel; no alternate engine or FUSE dependency |
| Original folder path | Journal-bound symlink to internal user data child |
| Original preservation | Verified whole-directory holding transaction |
| Synchronized Save/Eject | Close writers; read-only + mandatory root mapping/reference scan, then verified checkpoint |
| Temporary eject | Restore original objects; discard RAM; no current-RAM snapshot unless explicitly exported |
| Periodic save | Same nonbypassable snapshot guard and bounded administrator controls |
| Relaunch | Reconnect/repin exact surviving native mount; never mount over uncertainty |
| Recovery | Verified committed checkpoint; external loss clearly disclosed |
| Metadata | Existing xattr, quarantine, provenance, modes, flags, topology and hardlink checks |
| Sparse data | Logical zeros/tails preserved; native physical accounting is OS-defined |
| Capacity | Fixed mounted max, offline edit; no silently successful live resize |
| Dynamic allocation | Kernel allocation grows with content and releases after truncate/delete/final close; exact-package probe required |
| Memory metrics | Actual native statfs allocation/capacity, separate from physical RAM/RSS |
| Compression | OS-managed compression/swap; no application compressor or page checksums |
| Snapshot location | Existing safe local snapshot-store selection/relocation |
| Legacy compatibility | Data readers/discriminators and safe offline recovery; no executable old backend |
| Privilege | One-shot validated-slot operations; no permanent root service or credential handling |

Unsupported/unreadable entries and uncertain identities fail closed. No integrity
waiver, forced user-volume cleanup or fallback engine is used.
