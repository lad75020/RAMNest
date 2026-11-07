#include "MemoryFS.hpp"
#include <algorithm>
#include <cassert>
#include <cerrno>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>
using namespace ramnest;
namespace fs=std::filesystem;
namespace {
constexpr size_t length=20*pageSize+37;
struct Payload {std::string name,bytes;uint64_t pages;};
std::vector<Payload> payloads(){
    std::string sparse(length,0);sparse[3*pageSize+17]='A';sparse[12*pageSize+3]='B';
    auto tail=sparse;tail.back()='C';
    return {{"dense",std::string(length,'Z'),21},{"sparse",tail,3},{"trailing-zero",sparse,2},{"zero",std::string(length,0),0}};
}
struct Fixture {
    fs::path root;
    explicit Fixture(const fs::path&base){
        fs::create_directories(base);auto pattern=(base/"sparse-XXXXXX").string();
        auto result=::mkdtemp(pattern.data());assert(result);root=result;
        // /private/tmp inherits wheel; native admission requires our own group.
        assert(::chown(root.c_str(),::getuid(),::getgid())==0);
    }
    ~Fixture(){fs::remove_all(root);}
};
// Only SEEK_DATA is injected. In particular import's SEEK_SET must remain real.
// The hook is installed on each MemoryFS instance, like its reader/writer hooks.
thread_local int queryError=0;
thread_local bool skipFirst=false;
thread_local std::vector<off_t> offsets;
void script(int error,bool skip=false){queryError=error;skipFirst=skip;offsets.clear();}
off_t query(int,off_t offset,int whence){
    assert(whence==SEEK_DATA);offsets.push_back(offset);
    if(skipFirst&&offset==0)return 3*pageSize+17;
    if(queryError){errno=queryError;return -1;}
    return offset; // deterministic supported dense extent view
}
off_t sparseQuery(int,off_t offset,int whence){
    assert(whence==SEEK_DATA);offsets.push_back(offset);
    if(offset<=off_t(3*pageSize+17))return 3*pageSize+17;
    if(offset<=off_t(12*pageSize+3))return 12*pageSize+3;
    errno=ENXIO;return -1; // the remainder, including the partial page, is a hole
}
thread_local size_t importBytes=0;
ssize_t countedRead(int fd,void*buffer,size_t size){auto got=::read(fd,buffer,size);if(got>0)importBytes+=size_t(got);return got;}
void source(const fs::path&root,const Payload&p,bool sparse){
    fs::create_directory(root);
    int fd=::open((root/"payload").c_str(),O_RDWR|O_CREAT|O_EXCL|O_CLOEXEC,0600);assert(fd>=0);
    assert(::ftruncate(fd,off_t(p.bytes.size()))==0);
    for(size_t offset=0;offset<p.bytes.size();offset+=pageSize){
        auto count=std::min(size_t(pageSize),p.bytes.size()-offset);
        if(sparse&&std::all_of(p.bytes.begin()+offset,p.bytes.begin()+offset+count,[](char c){return c==0;}))continue;
        assert(::pwrite(fd,p.bytes.data()+offset,count,off_t(offset))==ssize_t(count));
    }
    assert(::close(fd)==0);
}
std::string bytes(const fs::path&p){std::ifstream in(p,std::ios::binary);assert(in);return std::string(std::istreambuf_iterator<char>(in),{});}
uint64_t attributeBytes(MemoryFS&tree){
    uint64_t total=0;
    for(const auto*path:{"/","/payload"}){
        std::string keys;assert(tree.listxattr(path,keys)==0);
        for(size_t offset=0;offset<keys.size();){
            auto end=keys.find(char(0),offset);assert(end!=std::string::npos);
            auto key=keys.substr(offset,end-offset);std::string value;assert(tree.getxattr(path,key,value)==0);
            total+=key.size()+value.size();offset=end+1;
        }
    }
    return total;
}
void memory(MemoryFS&tree,const Payload&p){
    struct stat st{};assert(tree.stat("/payload",&st)==0&&st.st_size==off_t(p.bytes.size()));
    std::string actual(p.bytes.size(),0);assert(tree.read("/payload",actual.data(),actual.size(),0)==int(actual.size()));assert(actual==p.bytes);
    assert(tree.metrics().content==p.bytes.size());
    assert(tree.used()==p.pages*pageSize+attributeBytes(tree));
    assert(tree.metrics().payload==p.pages*pageSize&&tree.metrics().mapped==p.pages*pageSize);
    assert(tree.accountingOracleForTest());
}
void fallback(const fs::path&base,bool skip){
    for(const auto&p:payloads()){
        if(skip&&p.name!="sparse"&&p.name!="trailing-zero")continue;
        for(bool physicalSparse:{false,true})for(int error:{EINVAL,ENOTSUP,ENOTTY}){
            Fixture f(base);source(f.root/"source",p,physicalSparse);
            MemoryFS baseline(4<<20,false);baseline.setExtentSeekerForTest(query);script(0);
            auto result=baseline.importTree((f.root/"source").string());if(result)std::cerr<<"baseline import "<<p.name<<" result="<<result<<" queries="<<offsets.size()<<" root="<<f.root<<"\n";assert(result==0);memory(baseline,p);
            MemoryFS tree(4<<20,false);tree.setExtentSeekerForTest(query);tree.setImportReaderForTest(countedRead);
            script(error,skip);importBytes=0;
            assert(tree.importTree((f.root/"source").string())==0);memory(tree,p);
            assert(tree.metrics().content==baseline.metrics().content&&tree.metrics().logical==baseline.metrics().logical);
            assert(importBytes==length-(skip?3*pageSize:0));
            assert(offsets==(skip?std::vector<off_t>({0,4*pageSize}):std::vector<off_t>({0})));
            assert(offsets.size()==(skip?2:1));
            script(error,skip);
            assert(tree.exportTree((f.root/"export").string())==0);
            assert(bytes(f.root/"export/payload")==p.bytes);
            assert(tree.lastExportStats().written==(p.pages==21?length:p.pages*pageSize-(p.name=="sparse"?pageSize-37:0)));
            assert(offsets.size()==(skip?2:1));
            assert(tree.lastExportStats().readback==length-(skip?3*pageSize:0));
            MemoryFS restored(4<<20,false);restored.setExtentSeekerForTest(query);script(error,skip);
            assert(restored.importTree((f.root/"export").string())==0);memory(restored,p);
        }
    }
}
void endOfData(const fs::path&base){
    for(auto index:{2,3}){
        auto p=payloads()[index];Fixture f(base);source(f.root/"source",p,true);
        MemoryFS tree(4<<20,false);tree.setImportReaderForTest(countedRead);
        tree.setExtentSeekerForTest(index==2?sparseQuery:query);script(ENXIO);importBytes=0;
        assert(tree.importTree((f.root/"source").string())==0);memory(tree,p);
        assert(importBytes==p.pages*pageSize&&offsets.size()==p.pages+1);
        script(ENXIO);
        assert(tree.exportTree((f.root/"export").string())==0);
        assert(bytes(f.root/"export/payload")==p.bytes);
        assert(tree.lastExportStats().readback==p.pages*pageSize&&offsets.size()==p.pages+1);
    }
}
void incremental(const fs::path&base,bool skip,off_t corruption){
    auto p=payloads()[2];Fixture f(base);source(f.root/"source",p,true);
    MemoryFS tree(4<<20,false);tree.setExtentSeekerForTest(query);script(ENOTTY,skip);
    assert(tree.importTree((f.root/"source").string())==0);
    script(ENOTTY,skip);assert(tree.exportTree((f.root/"first").string())==0);auto first=tree.lastExportStats();
    script(ENOTTY,skip);
    assert(tree.exportTree((f.root/"noop").string(),false,(f.root/"first").string(),first.generation)==0);
    assert(tree.lastExportStats().reused&&tree.lastExportStats().written==0&&!fs::exists(f.root/"noop"));
    assert(offsets.size()==(skip?2:1));
    assert(tree.chmod("/payload",0640)==0);script(ENOTTY,skip);
    assert(tree.exportTree((f.root/"incremental").string(),false,(f.root/"first").string(),first.generation)==0);
    auto current=tree.lastExportStats();assert(!current.reused&&current.clonedFiles==1&&current.written==0);
    assert(bytes(f.root/"first/payload")==p.bytes&&bytes(f.root/"incremental/payload")==p.bytes);
    assert(offsets.size()==(skip?4:2)); // validate prior candidate and cloned destination
    struct stat prior{},clone{};
    assert(::stat((f.root/"first/payload").c_str(),&prior)==0&&::stat((f.root/"incremental/payload").c_str(),&clone)==0);
    assert(prior.st_ino!=clone.st_ino&&(prior.st_mode&07777)==0600&&(clone.st_mode&07777)==0640);
    // Same-size, same-mtime corruption in an expected page, a hole following the
    // initial skip, and the trailing partial zero page must all fail readback.
    int fd=::open((f.root/"incremental/payload").c_str(),O_RDWR|O_CLOEXEC);assert(fd>=0);
    const timespec times[2]={clone.st_atimespec,clone.st_mtimespec};
    {
        const auto offset=corruption;
        const char corrupt='!';assert(::pwrite(fd,&corrupt,1,offset)==1&&::futimens(fd,times)==0);
        script(ENOTTY,skip);
        assert(tree.exportTree((f.root/"corrupt-noop").string(),false,(f.root/"incremental").string(),current.generation)==-EIO);
        assert(!fs::exists(f.root/"corrupt-noop"));
        // Force candidate reuse rather than the whole-tree no-op route too.
        assert(tree.chmod("/payload",0600)==0);script(ENOTTY,skip);
        assert(tree.exportTree((f.root/"corrupt-candidate").string(),false,(f.root/"incremental").string(),current.generation)==-EIO);
        // The candidate failure can leave its owned, uncommitted stage.
        fs::remove_all(f.root/"corrupt-candidate");
        assert(tree.chmod("/payload",0640)==0);
        char original=p.bytes[size_t(offset)];assert(::pwrite(fd,&original,1,offset)==1&&::futimens(fd,times)==0);
    }
    assert(::close(fd)==0);memory(tree,p);
}
void hardErrors(const fs::path&base){
    auto p=payloads()[1];
    for(int error:{EIO,EBADF,EPERM})for(bool skip:{false,true}){
        Fixture f(base);source(f.root/"source",p,true);
        MemoryFS rejected(4<<20,false);rejected.setExtentSeekerForTest(query);script(error,skip);
        assert(rejected.importTree((f.root/"source").string())==-error&&offsets.size()==(skip?2:1));
        MemoryFS tree(4<<20,false);tree.setExtentSeekerForTest(query);script(0);
        assert(tree.importTree((f.root/"source").string())==0);
        script(error,skip);assert(tree.exportTree((f.root/"failed-export").string())==-error&&offsets.size()==(skip?2:1));
        script(0);assert(tree.exportTree((f.root/"good").string())==0);auto good=tree.lastExportStats();
        script(error,skip);
        assert(tree.exportTree((f.root/"failed-noop").string(),false,(f.root/"good").string(),good.generation)==-error);
        assert(offsets.size()==(skip?2:1)&&!fs::exists(f.root/"failed-noop"));
        assert(tree.chmod("/payload",0640)==0);script(error,skip);
        assert(tree.exportTree((f.root/"failed-candidate").string(),false,(f.root/"good").string(),good.generation)==-error);
        assert(offsets.size()==(skip?2:1));memory(tree,p);
    }
}
void quota(const fs::path&base){
    for(auto p:payloads()){
        Fixture f(base);source(f.root/"source",p,false);
        MemoryFS baseline(4<<20,false);baseline.setExtentSeekerForTest(query);script(0);
        assert(baseline.importTree((f.root/"source").string())==0);
        const auto capacity=p.pages*pageSize+attributeBytes(baseline);
        MemoryFS tree(capacity,false);tree.setExtentSeekerForTest(query);script(ENOTTY);
        assert(tree.importTree((f.root/"source").string())==0);memory(tree,p);
        assert(tree.used()==capacity);
        if(capacity){
            MemoryFS tooSmall(capacity-1,false);tooSmall.setExtentSeekerForTest(query);script(ENOTTY);
            assert(tooSmall.importTree((f.root/"source").string())==-ENOSPC);
        }
    }
}
}
int main(int argc,char**argv){
    assert(argc==3);fs::path base=argv[2];std::string name=argv[1];
    if(name=="fallback")fallback(base,false);
    else if(name=="skip")fallback(base,true);
    else if(name=="enxio")endOfData(base);
    else if(name=="incremental")for(bool skip:{false,true})
        for(off_t offset:{off_t(3*pageSize+17),off_t(7*pageSize+9),off_t(length-1)})incremental(base,skip,offset);
    else if(name=="errors")hardErrors(base);
    else if(name=="quota")quota(base);
    else assert(false);
    std::cout<<"PASS sparse extents "<<name<<"\n";
}
