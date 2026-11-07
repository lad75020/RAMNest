#include "MemoryFS.hpp"
#include <cassert>
#include <cerrno>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sys/xattr.h>
using namespace ramnest;
static int calls=0;
static ssize_t shortWriter(int fd,const void*data,size_t n,off_t offset){calls++;if(calls==1){errno=EINTR;return -1;}errno=0;return pwrite(fd,data,std::max(size_t(1),n/2),offset);}
static ssize_t zeroWriter(int,const void*,size_t,off_t){errno=0;return 0;}
static void logicalMetadata(const std::string&root){
    namespace fs=std::filesystem;
    auto source=fs::path(root)/"source&accent-é", exported=fs::path(root)/"export&accent-é";
    fs::create_directory(source);
    const std::string payload="owned fixture bytes!";
    const uint32_t magic=0x636d7066,type=1;const uint64_t length=payload.size();
    std::string header(reinterpret_cast<const char*>(&magic),sizeof magic);
    header.append(reinterpret_cast<const char*>(&type),sizeof type);
    header.append(reinterpret_cast<const char*>(&length),sizeof length);header+=payload;
    assert(header.size()==36); // macOS/arm64 is little endian; valid raw-inline header.
    std::string finder(32,'\0');finder.replace(0,4,"TEXT");
    const std::map<std::string,std::string>attrs={{"user.ramnest","ordinary metadata"},{"com.apple.FinderInfo",finder},{"com.apple.quarantine","0081;65000000;RAMNest;"}};
    const std::string resource="legitimate resource fork";
    auto get=[](const fs::path&file,const std::string&key){auto size=::getxattr(file.c_str(),key.c_str(),nullptr,0,0,XATTR_NOFOLLOW|XATTR_SHOWCOMPRESSION);assert(size>=0);std::string value(size,'\0');assert(::getxattr(file.c_str(),key.c_str(),value.data(),value.size(),0,XATTR_NOFOLLOW|XATTR_SHOWCOMPRESSION)==size);return value;};
    auto bytes=[](const fs::path&file){std::ifstream input(file,std::ios::binary);return std::string(std::istreambuf_iterator<char>(input),{});};
    std::map<std::string,struct stat>before;
    for(const std::string name:{"plain.bin","compressed-é.bin"}){
        auto file=source/name;{std::ofstream output(file,std::ios::binary);output<<payload;}
        for(const auto&[key,value]:attrs)assert(::setxattr(file.c_str(),key.c_str(),value.data(),value.size(),0,XATTR_NOFOLLOW)==0);
        assert(::setxattr(file.c_str(),"com.apple.decmpfs",header.data(),header.size(),0,XATTR_NOFOLLOW)==0);
        bool compressed=name!="plain.bin";uint32_t flags=UF_HIDDEN|UF_NODUMP|(compressed?UF_COMPRESSED:0);
        assert(::lchflags(file.c_str(),flags)==0);auto&st=before[name];assert(::lstat(file.c_str(),&st)==0&&st.st_flags==flags&&st.st_size==int64_t(payload.size()));
        assert(bytes(file)==payload);
        if(!compressed)assert(::setxattr(file.c_str(),"com.apple.ResourceFork",resource.data(),resource.size(),0,XATTR_NOFOLLOW)==0);
        assert(::lstat(file.c_str(),&st)==0);
    }
    MemoryFS memory(16*1024*1024);assert(memory.importTree(source.string())==0);
    for(const auto&[name,old]:before){
        auto path="/"+name;struct stat st{};assert(memory.stat(path,&st)==0&&st.st_flags==(UF_HIDDEN|UF_NODUMP)&&st.st_size==int64_t(payload.size()));
        std::string value;assert(memory.getxattr(path,"com.apple.decmpfs",value)==-ENOATTR);assert(memory.listxattr(path,value)==0&&value.find("com.apple.decmpfs")==std::string::npos);
        for(const auto&[key,expected]:attrs)assert(memory.getxattr(path,key,value)==0&&value==expected);
        std::string readback(payload.size(),'\0');assert(memory.read(path,readback.data(),readback.size(),0)==int(readback.size())&&readback==payload);
        // RAMNest's LZ4 pages are not macOS decmpfs storage.
        assert(memory.setxattr(path,"com.apple.decmpfs",header,0)==-ENOTSUP);
        assert(memory.flags(path,UF_COMPRESSED)==-ENOTSUP);
    }
    std::string value;assert(memory.getxattr("/plain.bin","com.apple.ResourceFork",value)==0&&value==resource);
    assert(memory.exportTree(exported.string())==0);
    MemoryFS restored(16*1024*1024);assert(restored.importTree(exported.string())==0);
    for(const auto&[name,old]:before){
        auto file=exported/name;assert(bytes(file)==payload);struct stat st{};assert(::lstat(file.c_str(),&st)==0&&st.st_flags==(UF_HIDDEN|UF_NODUMP));
        assert(::getxattr(file.c_str(),"com.apple.decmpfs",nullptr,0,0,XATTR_NOFOLLOW|XATTR_SHOWCOMPRESSION)==-1&&errno==ENOATTR);
        for(const auto&[key,expected]:attrs)assert(get(file,key)==expected);
        auto original=source/name;assert(bytes(original)==payload&&get(original,"com.apple.decmpfs")==header);
        assert(::lstat(original.c_str(),&st)==0&&st.st_ino==old.st_ino&&st.st_mode==old.st_mode&&st.st_size==old.st_size&&st.st_flags==old.st_flags&&st.st_mtimespec.tv_sec==old.st_mtimespec.tv_sec&&st.st_mtimespec.tv_nsec==old.st_mtimespec.tv_nsec&&st.st_ctimespec.tv_sec==old.st_ctimespec.tv_sec&&st.st_ctimespec.tv_nsec==old.st_ctimespec.tv_nsec);
        for(const auto&[key,expected]:attrs)assert(get(original,key)==expected);
    }
    assert(get(source/"plain.bin","com.apple.ResourceFork")==resource&&get(exported/"plain.bin","com.apple.ResourceFork")==resource);
    std::cout<<"PASS native logical metadata: reserved attribute and genuine UF_COMPRESSED import, plain export, strict user attrs/resource fork, source unchanged, no APFS compression claim\n";
}
int main(){
    MemoryFS fs(32*1024*1024);assert(fs.create("/data",S_IFREG|0600)==0);std::array<char,pageSize>plain{},readback{};plain.fill('A');assert(fs.write("/data",plain.data(),plain.size(),0)==int(plain.size()));auto m=fs.metrics();assert(m.logical==pageSize&&m.payload<vmPageSize&&m.mapped==vmPageSize);
    assert(fs.write("/data","patch",5,123)==5);plain[123]='p';plain[124]='a';plain[125]='t';plain[126]='c';plain[127]='h';assert(fs.read("/data",readback.data(),readback.size(),0)==int(readback.size())&&readback==plain);
    for(int i=0;i<30;i++){arc4random_buf(plain.data(),plain.size());assert(fs.write("/data",plain.data(),plain.size(),0)==int(plain.size()));assert(fs.read("/data",readback.data(),readback.size(),0)==int(readback.size())&&readback==plain);assert(fs.metrics().mapped==pageSize);}
    assert(fs.truncate("/data",100)==0);assert(fs.truncate("/data",pageSize)==0);assert(fs.read("/data",readback.data(),readback.size(),0)==int(readback.size()));for(size_t i=100;i<readback.size();i++)assert(readback[i]==0);
    assert(fs.corruptBlockForTest("/data",0)==0);assert(fs.read("/data",readback.data(),16,0)==-EIO);assert(fs.write("/data","x",1,0)==-EIO);assert(fs.truncate("/data",5)==-EIO);assert(fs.corruptBlockForTest("/data",0)==0);assert(fs.read("/data",readback.data(),100,0)==100&&!memcmp(readback.data(),plain.data(),100));
    assert(fs.flags("/data",UF_HIDDEN|UF_NODUMP)==0);
    std::string base=getenv("RAMNEST_TEST_ROOT")?getenv("RAMNEST_TEST_ROOT"):"/private/tmp";std::filesystem::create_directories(base);std::string pattern=base+"/ramnest-compression-XXXXXX";auto tmp=mkdtemp(pattern.data());assert(tmp);auto root=std::string(tmp);
    fs.setExportWriterForTest(shortWriter);assert(fs.exportTree(root+"/short")==0&&calls>3);MemoryFS restored(32*1024*1024);assert(restored.importTree(root+"/short")==0);struct stat st{};assert(restored.stat("/data",&st)==0&&st.st_flags==(UF_HIDDEN|UF_NODUMP));assert(restored.read("/data",readback.data(),100,0)==100&&!memcmp(readback.data(),plain.data(),100));
    fs.setExportWriterForTest(zeroWriter);assert(fs.exportTree(root+"/zero")==-EIO);assert(fs.read("/data",readback.data(),100,0)==100&&!memcmp(readback.data(),plain.data(),100));assert(fs.metrics().logical==pageSize);
    logicalMetadata(root);
    assert(fs.truncate("/data",0)==0);assert(fs.metrics().mapped==0);std::filesystem::remove_all(root);
    std::cout<<"PASS compression: LZ4+raw roundtrip, page savings, random content, partial writes, truncate/regrow zeros, corrupt-block EIO retains valid bytes, short+EINTR export retry, zero-write failure, flags roundtrip, munmap counters\n";
}
