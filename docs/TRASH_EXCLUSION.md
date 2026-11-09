# Exact directory exclusion and original retention

The existing snapshot policy excludes only directories named exactly `.Trashes`,
including nested ones. It does not follow their symlinks, inspect opaque contents,
normalize permissions or infer that an excluded tree is empty. Near-case names,
regular files and symlinks retain normal strict handling.

Native OS `.fseventsd` is at the protected mount root, outside the logical user
`tree/data`. It is not a new source exclusion. A user source subtree is never
ignored merely because it has a similar OS-managed name.

Original whole-root holdings retain all objects, including excluded opaque Trash.
Temporary restoration returns those original objects. Synchronized restoration
publishes the verified included tree, and cleanup retains holdings with opaque
excluded data and records a warning/location. Latest-only retention preserves the
required original anchor until cleanup can be proved safe. No excluded user data
is recursively purged or chmod-ed to make cleanup succeed.

Snapshot capture/copy and immutable old-revision views retain the same policy.
There is no old helper export/adoption or protocol-negotiation route. Included
hardlink classes must still match; an excluded alias cannot authorize modifying
an outside inode or relaxing committed private-storage integrity.
