#include "MemoryFS.hpp"
#include "StorageModes.hpp"
#include <cassert>
#include <filesystem>
#include <iostream>
using ramnest::MemoryFS;
namespace fs=std::filesystem;
static std::string readBytes(const fs::path& p){int fd=::open(p.c_str(),O_RDONLY|O_NOFOLLOW);assert(fd>=0);char bytes[128]{};auto n=::read(fd,bytes,sizeof bytes);assert(n>=0);::close(fd);return {bytes,size_t(n)};}
static std::map<std::string,std::string> observedAttributes(const fs::path& path){
    auto count=::listxattr(path.c_str(),nullptr,0,XATTR_NOFOLLOW);assert(count>=0);
    std::vector<char> names(count);if(count)assert(::listxattr(path.c_str(),names.data(),names.size(),XATTR_NOFOLLOW)==count);
    std::map<std::string,std::string> attrs;
    for(size_t at=0;at<names.size();){std::string name(names.data()+at);at+=name.size()+1;
        auto size=::getxattr(path.c_str(),name.c_str(),nullptr,0,0,XATTR_NOFOLLOW);assert(size>=0&&size<=1024*1024);
        std::string value(size,0);assert(::getxattr(path.c_str(),name.c_str(),value.data(),value.size(),0,XATTR_NOFOLLOW)==size);attrs.emplace(name,std::move(value));}
    return attrs;
}
static void provenanceCopies(const fs::path& root){
    auto source=root/"provenance-source";fs::create_directory(source);
    auto payload=source/".DS_Store";{int fd=::open(payload.c_str(),O_CREAT|O_EXCL|O_RDWR,0600);assert(fd>=0&&::write(fd,"owned",5)==5);::close(fd);}
    const std::string custom="ordinary exact bytes", quarantine="0081;65000000;RAMNestFixture;";
    assert(::setxattr(payload.c_str(),"user.ramnest-control",custom.data(),custom.size(),0,XATTR_NOFOLLOW)==0);
    assert(::setxattr(payload.c_str(),"com.apple.quarantine",quarantine.data(),quarantine.size(),0,XATTR_NOFOLLOW)==0);
    auto attrs=observedAttributes(payload);struct stat before{};assert(::lstat(payload.c_str(),&before)==0);
    MemoryFS tree(16*1024*1024,false);assert(tree.importTree(source)==0);
    std::string runtime;
    for(auto&[key,value]:attrs)assert(tree.getxattr("/.DS_Store",key,runtime)==0&&runtime==value);
    assert(tree.accountingOracleForTest());
    auto revision=root/"provenance-revision";fs::create_directory(revision);
    assert(tree.exportTree(revision/"data",false,"",0,true)==0);
    fs::rename((revision/"data").string()+".modes",revision/"modes.bin");
    auto file=revision/"data/.DS_Store";auto copied=observedAttributes(file);
    auto expected=attrs;expected.erase("com.apple.provenance");auto ordinary=copied;ordinary.erase("com.apple.provenance");assert(ordinary==expected);
    const auto generation=tree.lastExportStats().generation;
    assert(tree.exportTree(root/"provenance-noop",false,revision/"data",generation,true)==0&&tree.lastExportStats().reused);
    for(auto field:{"extra","quarantine","mode","flags","content"}){
        struct stat st{};assert(::lstat(file.c_str(),&st)==0);
        if(std::string(field)=="extra")assert(::setxattr(file.c_str(),"user.extra","x",1,0,XATTR_NOFOLLOW)==0);
        else if(std::string(field)=="quarantine")assert(::setxattr(file.c_str(),"com.apple.quarantine","x",1,0,XATTR_NOFOLLOW)==0);
        else if(std::string(field)=="mode")assert(::chmod(file.c_str(),0644)==0);
        else if(std::string(field)=="flags")assert(::chflags(file.c_str(),UF_NODUMP)==0);
        else {int fd=::open(file.c_str(),O_RDWR);assert(fd>=0&&::pwrite(fd,"other",5,0)==5);::close(fd);}
        assert(tree.exportTree(root/(std::string("reject-")+field),false,revision/"data",generation,true)<0);
        if(std::string(field)=="extra")assert(::removexattr(file.c_str(),"user.extra",XATTR_NOFOLLOW)==0);
        else if(std::string(field)=="quarantine")assert(::setxattr(file.c_str(),"com.apple.quarantine",quarantine.data(),quarantine.size(),0,XATTR_NOFOLLOW)==0);
        else if(std::string(field)=="mode")assert(::chmod(file.c_str(),0600)==0);
        else if(std::string(field)=="flags")assert(::chflags(file.c_str(),0)==0);
        else {int fd=::open(file.c_str(),O_RDWR);assert(fd>=0&&::pwrite(fd,"owned",5,0)==5);::close(fd);}
        timespec times[2]={st.st_atimespec,st.st_mtimespec};assert(::utimensat(AT_FDCWD,file.c_str(),times,AT_SYMLINK_NOFOLLOW)==0);
        assert(tree.exportTree(root/(std::string("retry-")+field),false,revision/"data",generation,true)==0);
    }
    assert(observedAttributes(payload)==attrs);struct stat after{};assert(::lstat(payload.c_str(),&after)==0);
    assert(before.st_ino==after.st_ino&&before.st_ctimespec.tv_sec==after.st_ctimespec.tv_sec&&before.st_ctimespec.tv_nsec==after.st_ctimespec.tv_nsec);
    assert(tree.accountingOracleForTest());
    uint64_t actual=ramnest::pageSize;
    for(auto path:{revision/"data",file})for(auto&[key,value]:observedAttributes(path))actual+=key.size()+value.size();
    const auto held=tree.metrics().logical;assert(tree.resize(held)==0);
    const auto boundary=tree.exportTree(root/"provenance-capacity",false,revision/"data",generation,true);
    assert(boundary==(actual>held?-ENOSPC:0));assert(tree.resize(16*1024*1024)==0);
    std::cout<<"PASS provenance copy: authentic import/runtime attrs, own export receipt/no-op, strict ordinary/quarantine/content/mode/flag controls, exact source immutability\n";
}
int main(){
    auto base=getenv("RAMNEST_TEST_ROOT");assert(base);fs::create_directories(base);
    std::string pattern=std::string(base)+"/storage-XXXXXX";assert(mkdtemp(pattern.data()));fs::path root=pattern;
    provenanceCopies(root);
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
