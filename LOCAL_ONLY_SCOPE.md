# Local-only scope

RAMNest uses native macOS tmpfs and local snapshot storage. Ordinary I/O has no
network transport or alternate storage engine. The user pin uses a private local
Unix socket; bounded root controls use one-shot macOS administrator authorization.
No permanent privileged service, network credential handling, SIP/TCC change or
remote storage integration is part of this product.

Candidate verification is isolated to new owned source/store fixtures. Installed
apps, other mounts and existing user stores are not test targets.
