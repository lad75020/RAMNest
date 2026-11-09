# Content-dependent native allocation

A fixed mounted maximum is accepted. Kernel filesystem allocation must grow with
written content and release on truncation/deletion after final reference close.
See [current accounting](docs/MEMORY.md) and the owned exact-package probe in
[README](README.md). Host-wide physical RAM readings are separate evidence and do
not establish isolated attribution or absence of swap.
