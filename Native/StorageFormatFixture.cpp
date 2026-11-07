#include "MemoryFS.hpp"
#include <cassert>
#include <iostream>
using ramnest::MemoryFS;
// No mount, default store, installed helper, or user directory is involved.
int main(int argc,char** argv){
    assert(argc==2||argc==3);
    const bool privateFormat=argc==3;
    MemoryFS tree(16*1024*1024,false);
    assert(tree.create("/RestrictedData",S_IFDIR|0700)==0);
    assert(tree.create("/RestrictedData/nested",S_IFDIR|0700)==0);
    assert(tree.create("/RestrictedData/nested/payload",S_IFREG|0600)==0);
    assert(tree.write("/RestrictedData/nested/payload","real trash payload",18,0)==18);
    assert(tree.setxattr("/RestrictedData","user.trash","directory metadata",0)==0);
    assert(tree.setxattr("/RestrictedData/nested/payload","user.payload","nonempty metadata",0)==0);
    assert(tree.link("/RestrictedData/nested/payload","/alias")==0);
    assert(tree.symlink("RestrictedData/nested/payload","/target")==0);
    assert(tree.symlink("zero-dir/payload","/zero-link")==0);
    assert(tree.setxattr("/zero-link","com.apple.quarantine","0081;65000000;RAMNestStorage;",0)==0);
    assert(tree.chmod("/zero-link",privateFormat?0000:0700)==0);
    assert(tree.chmod("/RestrictedData/nested/payload",privateFormat?0000:0311)==0);
    assert(tree.chmod("/RestrictedData/nested",privateFormat?0000:0311)==0);
    assert(tree.chmod("/RestrictedData",0311)==0);
    assert(tree.create("/write-only",S_IFREG|0200)==0);
    assert(tree.write("/write-only","write only data",15,0)==15);
    assert(tree.create("/zero-dir",S_IFDIR|0700)==0);
    assert(tree.create("/zero-dir/payload",S_IFREG|0600)==0);
    assert(tree.write("/zero-dir/payload","zero directory payload",22,0)==22);
    assert(tree.setxattr("/zero-dir","user.zero","nonempty zero directory",0)==0);
    assert(tree.chmod("/zero-dir",privateFormat?0000:0311)==0);
    assert(tree.create("/modes.bin",S_IFREG|0644)==0);
    assert(tree.write("/modes.bin","user mode-map name",18,0)==18);
    assert(tree.create("/manifest.json",S_IFREG|0644)==0);
    assert(tree.write("/manifest.json","user manifest name",18,0)==18);
    assert(tree.chmod("/",getenv("RAMNEST_FIXTURE_READABLE_ROOT")?0700:privateFormat?0000:0311)==0);
    int result=tree.exportTree(argv[1],false,"",0,argc==3&&std::string(argv[2])=="private");
    std::cout<<"export="<<result<<std::endl;
    if(!result&&argc==3)std::cout<<"modes-digest="<<tree.lastExportStats().modeMapDigest<<std::endl;
    return result?1:0;
}
