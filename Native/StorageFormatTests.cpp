#include "MemoryFS.hpp"
#include "StorageModes.hpp"
#include <cassert>
#include <filesystem>
#include <iostream>
using ramnest::MemoryFS;
namespace fs=std::filesystem;
static std::string readBytes(const fs::path& p){int fd=::open(p.c_str(),O_RDONLY|O_NOFOLLOW);assert(fd>=0);char bytes[128]{};auto n=::read(fd,bytes,sizeof bytes);assert(n>=0);::close(fd);return {bytes,size_t(n)};}
int main(){
    auto base=getenv("RAMNEST_TEST_ROOT");assert(base);fs::create_directories(base);
    std::string pattern=std::string(base)+"/storage-XXXXXX";assert(mkdtemp(pattern.data()));fs::path root=pattern;
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
    assert(tree.chmod("/zero-link",0000)==0);
    assert(tree.chmod("/RestrictedData/nested/payload",0000)==0);
    assert(tree.chmod("/RestrictedData/nested",0000)==0);
    assert(tree.chmod("/RestrictedData",0311)==0);
    assert(tree.create("/write-only",S_IFREG|0200)==0);
    assert(tree.write("/write-only","write only data",15,0)==15);
    assert(tree.create("/zero-dir",S_IFDIR|0700)==0);
    assert(tree.create("/zero-dir/payload",S_IFREG|0600)==0);
    assert(tree.write("/zero-dir/payload","zero directory payload",22,0)==22);
    assert(tree.setxattr("/zero-dir","user.zero","nonempty zero directory",0)==0);
    assert(tree.chmod("/zero-dir",0000)==0);
    assert(tree.chmod("/",0000)==0);
    auto stage=root/"stage-first";
    assert(tree.exportTree(stage,false,"",0,true)==0);
    ramnest::StorageModeMap modes;assert(ramnest::readStorageModes(stage.string()+".modes",modes)==0);
    assert(modes.at("").mode==0&&modes.at("RestrictedData").mode==0311&&modes.at("RestrictedData/nested/payload").mode==0&&modes.at("write-only").mode==0200);
    auto revision=root/"revision";fs::create_directory(revision);fs::rename(stage,revision/"data");fs::rename(stage.string()+".modes",revision/"modes.bin");
    struct stat before{},after{};assert(::lstat((revision/"data/RestrictedData/nested/payload").c_str(),&before)==0);
    assert((before.st_mode&07777)==0600&&readBytes(revision/"data/RestrictedData/nested/payload")=="real trash payload");
    auto generation=tree.lastExportStats().generation;
    assert(tree.exportTree(root/"stage-noop",false,revision/"data",generation,true)==0&&tree.lastExportStats().reused);
    assert(!fs::exists(root/"stage-noop")&&!fs::exists(root/"stage-noop.modes"));
    MemoryFS imported(16*1024*1024,false);
    MemoryFS incompatible(16*1024*1024,false);assert(incompatible.populate(revision/"data")==-EPROTONOSUPPORT);
    MemoryFS incompatibleImport(16*1024*1024,false);assert(incompatibleImport.importTree(revision/"data")==-EPROTONOSUPPORT);
    auto digest=ramnest::storageDigest(ramnest::encodeStorageModes(modes));assert(imported.populate(revision/"data",digest)==0);
    for(auto&[path,record]:modes){struct stat st{};assert(imported.stat("/"+path,&st)==0&&(st.st_mode&07777)==record.mode);}
    struct stat a{},b{};assert(imported.stat("/alias",&a)==0&&imported.stat("/RestrictedData/nested/payload",&b)==0&&a.st_ino==b.st_ino);
    std::string attr;assert(imported.getxattr("/RestrictedData","user.trash",attr)==0&&attr=="directory metadata");
    char bytes[18];assert(imported.read("/RestrictedData/nested/payload",bytes,18,0)==18&&std::string(bytes,18)=="real trash payload");
    assert(tree.write("/RestrictedData/nested/payload","dirty",5,0)==5);
    assert(tree.exportTree(root/"stage-dirty",false,revision/"data",generation,true)==0&&!tree.lastExportStats().reused);
    assert(::lstat((revision/"data/RestrictedData/nested/payload").c_str(),&after)==0);
    assert(before.st_ino==after.st_ino&&before.st_mode==after.st_mode&&before.st_uid==after.st_uid&&before.st_gid==after.st_gid&&before.st_ctimespec.tv_sec==after.st_ctimespec.tv_sec&&before.st_ctimespec.tv_nsec==after.st_ctimespec.tv_nsec);
    assert(readBytes(revision/"data/RestrictedData/nested/payload")=="real trash payload");
    MemoryFS bad(16*1024*1024,false);assert(bad.populate(revision/"data",std::string(64,'0'))==-ESTALE);
    MemoryFS policy(16*1024*1024,false);assert(policy.populate(revision/"data",digest)==0);
    auto policyRevision=root/"policy-revision";fs::create_directory(policyRevision);
    assert(policy.exportTree(policyRevision/"data",false,"",0,true)==0);fs::rename((policyRevision/"data").string()+".modes",policyRevision/"modes.bin");
    auto policyGeneration=policy.lastExportStats().generation;
    policy.freeze(false);assert(policy.chmod("/write-only",0222)==0);
    assert(::chmod((policyRevision/"data/write-only").c_str(),0644)==0);
    assert(policy.exportTree(root/"stage-policy-drift",false,policyRevision/"data",policyGeneration,true)==-ESTALE);
    assert(::chmod((revision/"data/RestrictedData").c_str(),0755)==0);MemoryFS drift(16*1024*1024,false);assert(drift.populate(revision/"data",digest)==-ESTALE);
    ramnest::StorageModeMap decoded;auto encoded=ramnest::encodeStorageModes(modes);assert(ramnest::decodeStorageModes(encoded+"x",decoded)==-EINVAL);
    std::cout<<"PASS private storage: restrictive payload/xattrs/hardlinks, logical population, no-op, dirty export, prior inode/ctime immutability, malformed map/hash/policy rejection\n";
}
