#pragma once
#include <algorithm>
#include <filesystem>
#include <map>
#include <set>
#include <string>
#include <vector>
#include <CommonCrypto/CommonDigest.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

namespace ramnest {
struct StorageMode { unsigned char kind;mode_t mode;bool operator==(const StorageMode&)const=default; };
using StorageModeMap=std::map<std::string,StorageMode>;
// Same exact directory-kind policy as SnapshotExclusion in Swift. This is a
// checkpoint/population view, never a callback or runtime quota exception.
inline bool snapshotExcludedDirectory(const std::string& name,mode_t mode){return name==".Trashes"&&S_ISDIR(mode);}
inline StorageModeMap includedStorageModes(const StorageModeMap& full){
    StorageModeMap result;std::set<std::string> excluded;
    for(auto&[path,record]:full){
        auto at=path.rfind('/');auto name=at==path.npos?path:path.substr(at+1);auto parent=at==path.npos?"":path.substr(0,at);
        if(excluded.contains(parent)||snapshotExcludedDirectory(name,record.kind==1?S_IFDIR:0)){excluded.insert(path);continue;}
        result.emplace(path,record);
    }return result;
}
inline mode_t storagePhysical(StorageMode r){return r.kind==2?0600:0700;}
inline unsigned char storageKind(mode_t m){return S_ISDIR(m)?1:S_ISREG(m)?2:S_ISLNK(m)?3:0;}
inline std::string storageDigest(const std::string& bytes){
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];CC_SHA256(bytes.data(),CC_LONG(bytes.size()),hash);
    static const char hex[]="0123456789abcdef";std::string result;for(auto c:hash){result+=hex[c>>4];result+=hex[c&15];}return result;
}
inline bool storagePath(const std::string& p){
    if(p.empty())return true;if(p.front()=='/'||p.back()=='/'||p.find('\0')!=p.npos)return false;
    size_t at=0;while(at<p.size()){auto end=p.find('/',at);if(end==p.npos)end=p.size();auto part=p.substr(at,end-at);if(part.empty()||part=="."||part==".."||part.size()>255)return false;at=end+1;}return true;
}
inline int validateStorageModes(const StorageModeMap& modes){
    if(modes.empty()||modes.size()>1000000||modes.begin()->first!=""||modes.begin()->second.kind!=1)return -EINVAL;
    size_t bytes=12;
    for(auto&[path,r]:modes){
        if(!storagePath(path)||r.kind<1||r.kind>3||r.mode>07777)return -EINVAL;
        if(path.size()>1024*1024||path.size()+7>64*1024*1024-bytes)return -E2BIG;bytes+=path.size()+7;
        if(!path.empty()){auto at=path.rfind('/');auto parent=at==path.npos?"":path.substr(0,at);auto i=modes.find(parent);if(i==modes.end()||i->second.kind!=1)return -EINVAL;}
    }return 0;
}
inline std::string encodeStorageModes(const StorageModeMap& modes){
    std::string bytes="RNMODE2\n";
    auto number=[&](uint32_t n){for(int s=24;s>=0;s-=8)bytes+=char((n>>s)&255);};number(uint32_t(modes.size()));
    for(auto&[path,r]:modes){number(uint32_t(path.size()));bytes+=path;bytes+=char(r.kind);bytes+=char(r.mode>>8);bytes+=char(r.mode&255);}return bytes;
}
inline int decodeStorageModes(const std::string& bytes,StorageModeMap& modes){
    if(bytes.size()>64*1024*1024||!bytes.starts_with("RNMODE2\n"))return -EINVAL;
    size_t at=8;auto number=[&](uint32_t& n){if(at+4>bytes.size())return false;n=0;for(int i=0;i<4;i++)n=n<<8|static_cast<unsigned char>(bytes[at++]);return true;};
    uint32_t count=0;if(!number(count)||!count||count>1000000||count>(bytes.size()-at)/7)return -EINVAL;
    std::string prior;
    for(uint32_t i=0;i<count;i++){
        uint32_t size;if(!number(size)||size>1024*1024||size+3>bytes.size()-at)return -EINVAL;
        auto path=bytes.substr(at,size);at+=size;StorageMode r{static_cast<unsigned char>(bytes[at]),mode_t(unsigned(static_cast<unsigned char>(bytes[at+1]))<<8|static_cast<unsigned char>(bytes[at+2]))};at+=3;
        if((i&&path<=prior)||!modes.emplace(path,r).second)return -EINVAL;prior=path;
    }
    if(at!=bytes.size())return -EINVAL;return validateStorageModes(modes);
}
inline int readStorageModes(const std::string& path,StorageModeMap& modes,const std::string& digest=""){
    int fd=::open(path.c_str(),O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);if(fd<0)return -errno;
    struct Close{int fd;~Close(){::close(fd);}}close{fd};struct stat before{},after{};
    if(::fstat(fd,&before))return -errno;
    if(!S_ISREG(before.st_mode)||(before.st_mode&07777)!=0600||before.st_uid!=getuid()||before.st_gid!=getgid()||before.st_nlink!=1||before.st_size<0||before.st_size>64*1024*1024)return -EINVAL;
    std::string bytes(size_t(before.st_size),0);size_t done=0;
    while(done<bytes.size()){auto n=::read(fd,bytes.data()+done,bytes.size()-done);if(n<0&&errno==EINTR)continue;if(n<=0)return n<0?-errno:-EIO;done+=size_t(n);}
    if(::fstat(fd,&after))return -errno;
    if(before.st_size!=after.st_size||before.st_ctimespec.tv_sec!=after.st_ctimespec.tv_sec||before.st_ctimespec.tv_nsec!=after.st_ctimespec.tv_nsec)return -ESTALE;
    if(!digest.empty()&&(digest.size()!=64||storageDigest(bytes)!=digest))return -ESTALE;
    return decodeStorageModes(bytes,modes);
}
inline int writeStorageModes(const std::string& path,const StorageModeMap& modes){
    int e=validateStorageModes(modes);if(e)return e;auto bytes=encodeStorageModes(modes);if(bytes.size()>64*1024*1024)return -E2BIG;
    int fd=::open(path.c_str(),O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);if(fd<0)return -errno;
    struct Close{int fd;~Close(){::close(fd);}}close{fd};size_t done=0;
    while(done<bytes.size()){auto n=::write(fd,bytes.data()+done,bytes.size()-done);if(n<0&&errno==EINTR)continue;if(n<=0)return n<0?-errno:-EIO;done+=size_t(n);}if(::fchmod(fd,0600)||::fsync(fd))return -errno;return 0;
}
}
