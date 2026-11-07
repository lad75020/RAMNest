// Owned no-mount fixture; also compiled against the frozen baseline Helper.cpp
// and MemoryFS library to exercise a genuinely old incremental-v1 producer.
#define main unused_helper_main
#include "Helper.cpp"
#undef main
#include <cassert>
int main(int argc,char**argv){
    assert(argc==3);identifier=argv[1];volume=argv[2];tree=std::make_unique<MemoryFS>(16*1024*1024,false);
    mounted=true;activated=true;populated=true;
    assert(tree->create("/RestrictedData",S_IFDIR|0700)==0);
    assert(tree->create("/RestrictedData/nested",S_IFDIR|0700)==0);
    assert(tree->create("/RestrictedData/nested/payload",S_IFREG|0600)==0);
    assert(tree->write("/RestrictedData/nested/payload","real trash payload",18,0)==18);
    assert(tree->setxattr("/RestrictedData","user.trash","directory metadata",0)==0);
    assert(tree->setxattr("/RestrictedData/nested/payload","user.payload","nonempty metadata",0)==0);
    assert(tree->link("/RestrictedData/nested/payload","/alias")==0);
    assert(tree->symlink("RestrictedData/nested/payload","/target")==0);
    assert(tree->symlink("zero-dir/payload","/zero-link")==0);
    assert(tree->setxattr("/zero-link","com.apple.quarantine","0081;65000000;RAMNestStorage;",0)==0);
    assert(tree->chmod("/zero-link",0000)==0);
    assert(tree->chmod("/RestrictedData/nested/payload",0000)==0);
    assert(tree->chmod("/RestrictedData/nested",0000)==0);
    assert(tree->chmod("/RestrictedData",0311)==0);
    assert(tree->create("/write-only",S_IFREG|0200)==0);
    assert(tree->write("/write-only","write only data",15,0)==15);
    assert(tree->create("/zero-dir",S_IFDIR|0700)==0);
    assert(tree->create("/zero-dir/payload",S_IFREG|0600)==0);
    assert(tree->write("/zero-dir/payload","zero directory payload",22,0)==22);
    assert(tree->setxattr("/zero-dir","user.zero","nonempty zero directory",0)==0);
    assert(tree->chmod("/zero-dir",0000)==0);
    assert(tree->create("/modes.bin",S_IFREG|0644)==0);
    assert(tree->write("/modes.bin","user mode-map name",18,0)==18);
    assert(tree->create("/manifest.json",S_IFREG|0644)==0);
    assert(tree->write("/manifest.json","user manifest name",18,0)==18);
    assert(tree->chmod("/",0000)==0);
    std::string input;
    while(std::getline(std::cin,input)){
        std::string result;
        if(input=="fixture-trash-create"){
            int e=tree->create("/.Trashes",S_IFDIR|0311);if(!e)e=tree->create("/.Trashes/ignored",S_IFREG|0600);result=e?"ERR\t5":"OK";
        }
        else if(input=="fixture-trash-dirty"){int e=tree->write("/.Trashes/ignored","discarded",9,0);result=e==9?"OK":"ERR\t5";}
        else if(input=="fixture-dirty"){int e=tree->write("/RestrictedData/nested/payload","dirty",5,0);result=e==5?"OK":"ERR\t5";}
        else if(input=="fixture-unmounted"){mounted=false;result="OK";}
        else result=command(input);
        std::cout<<result<<std::endl;
    }
}
