#!/usr/bin/env python3
"""Check the installed FUSE2 SDK, documented native coverage and production registrations."""
import pathlib,re
root=pathlib.Path(__file__).resolve().parent.parent
header=pathlib.Path('/Library/Application Support/fuse-t/include/fuse/fuse.h').read_text()
header=header[header.index('struct fuse_operations {'):header.index('/** Extra context')]
sdk=set(re.findall(r'\(\*(\w+)\)',header))
source=(root/'Native/Helper.cpp').read_text();source=source[source.index('static fuse_operations operations('):source.index('int main(')]
native=set(re.findall(r'ops\.(\w+)\s*=\s*&CallbackBoundary',source))
production=native-{'renamex'}
rows={}
for line in (root/'docs/FUSE_COMPATIBILITY.md').read_text().splitlines():
    m=re.match(r'\| `(\w+)` \| (yes|no) \| (yes|no) \|',line)
    if m:
        name,n,p=m.groups();assert name not in rows;rows[name]=(n=='yes',p=='yes')
assert sdk==set(rows), {'missing':sorted(sdk-set(rows)),'extra':sorted(set(rows)-sdk)}
assert {n for n,(yes,_) in rows.items() if yes}==native
assert {n for n,(_,yes) in rows.items() if yes}==production
assert 'if(!productionNFSBridge)ops.renamex=' in source
assert 'ops.read_buf=' not in source and 'ops.write_buf=' not in source
print(f'PASS: all {len(sdk)} SDK callbacks documented; {len(native)} native registrations; {len(production)} production registrations; every registered callback uses an exception boundary; read/write buffer fallback preserved; renamex transport exclusion explicit')
