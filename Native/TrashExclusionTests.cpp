#include "MemoryFS.hpp"
#include "StorageModes.hpp"
#include <cassert>
#include <filesystem>
#include <iostream>
namespace fs=std::filesystem;
using ramnest::MemoryFS;
int main(){
    auto base=getenv("RAMNEST_TEST_ROOT");assert(base);fs::create_directories(base);
    auto pattern=std::string(base)+"/trash-XXXXXX";assert(mkdtemp(pattern.data()));fs::path root=pattern;
    for(bool privateFormat:{false,true}){
        MemoryFS tree(16<<20,false);
        for(auto name:{"/.Trashes","/normal","/normal/.Trashes","/file","/link"})assert(tree.create(name,S_IFDIR|0700)==0);
        for(auto name:{"/.Trashes/sentinel","/normal/.Trashes/sentinel","/normal/payload","/file/.Trashes","/.trashes","/.Trash","/.TrashesBackup"}){
            assert(tree.create(name,S_IFREG|0600)==0);assert(tree.write(name,"owned",5,0)==5);
        }
        assert(tree.link("/normal/payload","/alias")==0);
        assert(tree.setxattr("/normal/payload","user.included","metadata",0)==0);
        // A runtime hardlink across the exclusion boundary preserves its included alias.
        assert(tree.link("/.Trashes/sentinel","/included-alias")==0);
        assert(tree.symlink("../../outside","/link/.Trashes")==0);
        assert(tree.chmod("/link/.Trashes",0755)==0);
        assert(tree.chmod("/.Trashes",0311)==0&&tree.chmod("/normal/.Trashes",0)==0);
        auto revision=root/(privateFormat?"private":"legacy");fs::create_directory(revision);auto data=revision/"data";
        assert(tree.exportTree(data,false,"",0,privateFormat)==0);
        assert(!fs::exists(data/".Trashes")&&!fs::exists(data/"normal/.Trashes"));
        for(auto name:{"normal/payload","alias","included-alias","file/.Trashes",".trashes",".Trash",".TrashesBackup","link/.Trashes"})assert(fs::symlink_status(data/name).type()!=fs::file_type::not_found);
        std::string digest;
        if(privateFormat){
            fs::rename(data.string()+".modes",revision/"modes.bin");ramnest::StorageModeMap modes;
            assert(ramnest::readStorageModes(revision/"modes.bin",modes)==0&&!modes.contains(".Trashes")&&!modes.contains("normal/.Trashes"));
            digest=ramnest::storageDigest(ramnest::encodeStorageModes(modes));
        }
        MemoryFS imported(16<<20,false);assert(imported.importTree(data,digest)==0);struct stat st{};
        assert(imported.stat("/.Trashes",&st)==-ENOENT&&imported.stat("/normal/.Trashes",&st)==-ENOENT);
        assert(imported.stat("/file/.Trashes",&st)==0&&S_ISREG(st.st_mode));
        char bytes[5];assert(imported.read("/normal/payload",bytes,5,0)==5&&std::string(bytes,5)=="owned");
        assert(imported.read("/included-alias",bytes,5,0)==5&&std::string(bytes,5)=="owned");
        std::string attr;assert(imported.getxattr("/normal/payload","user.included",attr)==0&&attr=="metadata");
        auto gen=tree.lastExportStats().generation;
        assert(tree.write("/normal/.Trashes/sentinel","dirty",5,0)==5);
        auto result=tree.exportTree(root/(privateFormat?"noop-private":"noop-legacy"),false,data,gen,privateFormat);
        if(result)std::cerr<<"no-op private="<<privateFormat<<" error="<<result<<"\n";
        assert(result==0);
        assert(tree.lastExportStats().reused);
        assert(tree.lastExportStats().generation>gen);
        // Runtime quota remains charged even though the checkpoint omits Trash.
        assert(tree.metrics().logical>imported.metrics().logical);
        if(privateFormat){
            assert(::link((data/"alias").c_str(),(root/"outside-prior-alias").c_str())==0);
            struct stat before{},after{};assert(::lstat((data/"alias").c_str(),&before)==0);
            auto token=tree.lastExportStats().generation;
            assert(tree.exportTree(root/"outside-prior-rejected",false,data,token,true)==-EXDEV);
            assert(::lstat((data/"alias").c_str(),&after)==0&&before.st_ino==after.st_ino&&before.st_mode==after.st_mode&&before.st_ctimespec.tv_sec==after.st_ctimespec.tv_sec&&before.st_ctimespec.tv_nsec==after.st_ctimespec.tv_nsec);
        }
    }
    // Legacy opaque import is skipped before security/xattrs/enumeration.
    auto old=root/"old";fs::create_directories(old/".Trashes/nested");fs::create_directories(old/"normal/.Trashes");
    assert(::chmod((old/".Trashes").c_str(),0311)==0&&::chmod((old/"normal/.Trashes").c_str(),0)==0);
    MemoryFS legacy(16<<20,false);assert(legacy.importTree(old)==0);struct stat st{};assert(legacy.stat("/.Trashes",&st)==-ENOENT);
    auto revision=root/"old-private";fs::create_directories(revision/"data/.Trashes/nested");
    assert(::chmod((revision/"data").c_str(),0700)==0);
    int fd=::open((revision/"data/payload").c_str(),O_WRONLY|O_CREAT|O_EXCL,0600);assert(fd>=0);assert(::write(fd,"owned",5)==5);::close(fd);
    ramnest::StorageModeMap oldModes{{"",{1,0755}},{".Trashes",{1,0311}},{".Trashes/nested",{1,0}},{"payload",{2,0600}}};
    assert(ramnest::writeStorageModes(revision/"modes.bin",oldModes)==0);
    auto digest=ramnest::storageDigest(ramnest::encodeStorageModes(oldModes));
    assert(::chmod((revision/"data/.Trashes").c_str(),0)==0);
    MemoryFS oldPrivate(16<<20,false);assert(oldPrivate.populate(revision/"data",digest)==0);
    assert(oldPrivate.stat("/.Trashes",&st)==-ENOENT&&oldPrivate.stat("/payload",&st)==0);
    assert(::chmod((revision/"data/payload").c_str(),0644)==0);
    MemoryFS badPolicy(16<<20,false);assert(badPolicy.populate(revision/"data",digest)==-ESTALE);
    assert(::chmod((revision/"data/payload").c_str(),0600)==0);
    assert(::link((revision/"data/payload").c_str(),(root/"outside-link").c_str())==0);
    MemoryFS cross(16<<20,false);assert(cross.populate(revision/"data",digest)==-ESTALE);
    ramnest::StorageModeMap invalid=oldModes;invalid.emplace(".Trashes/nested/invalid",ramnest::StorageMode{4,0});
    ramnest::StorageModeMap parsed;assert(ramnest::decodeStorageModes(ramnest::encodeStorageModes(invalid),parsed)==-EINVAL);
    std::cout<<"PASS exact Trash export/import/private map/no-op; runtime cross-boundary alias and opaque legacy import\n";
}
