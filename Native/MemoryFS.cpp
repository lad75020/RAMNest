#include "MemoryFS.hpp"
#include "StorageModes.hpp"
#include <algorithm>
#include <compression.h>
#include <CommonCrypto/CommonDigest.h>
#include <cerrno>
#include <cstring>
#include <filesystem>
#include <fcntl.h>
#include <set>
#include <sys/xattr.h>
#include <sys/acl.h>
#include <copyfile.h>
#include <sys/clonefile.h>
#include <unistd.h>
namespace fs=std::filesystem;
namespace ramnest {
// SEEK_DATA is an optimization; FUSE-T NFS can reject it with ENOTTY.
// ENXIO remains end-of-data, and all other errors still propagate.
static bool unsupportedExtents(int error){return error==EINVAL||error==ENOTSUP||error==ENOTTY;}
static uint64_t blockHash(const char*data){uint64_t hash=1469598103934665603ULL;for(size_t i=0;i<pageSize;i++){hash^=static_cast<unsigned char>(data[i]);hash*=1099511628211ULL;}return hash;}
// One bounded workspace per active worker, no decoded page retained as a cache.
// The raw path never allocates an encoded buffer or compression scratch.
struct Workspace {
    std::vector<char> decoded;
    std::vector<uint8_t> encoded,scratch;
    char* decodeBuffer(){if(decoded.empty())decoded.resize(pageSize);return decoded.data();}
    void encoder(){
        static const size_t scratchSize=compression_encode_scratch_buffer_size(COMPRESSION_LZ4);
        if(scratchSize>16*1024*1024)throw std::runtime_error("invalid LZ4 workspace");
        if(encoded.empty())encoded.resize(pageSize);if(scratch.size()!=scratchSize)scratch.resize(scratchSize);
    }
};
static thread_local Workspace workspace;
static thread_local int pageAllocationFailure=-1;
void MappedPage::failAllocationForTest(int after){pageAllocationFailure=after;}
static std::array<unsigned char,32> strongHash(const char*data){std::array<unsigned char,32> digest;CC_SHA256(data,CC_LONG(pageSize),digest.data());return digest;}
int MappedPage::encode(const char*source,bool enabled,std::shared_ptr<Accounting> accounting)try{
    if(pageAllocationFailure==0)return -ENOMEM;if(pageAllocationFailure>0)pageAllocationFailure--;
    size_t length=0;
    if(enabled){workspace.encoder();length=compression_encode_buffer(workspace.encoded.data(),pageSize,reinterpret_cast<const uint8_t*>(source),pageSize,workspace.scratch.data(),COMPRESSION_LZ4);}
    size_t rounded=length?((length+vmPageSize-1)/vmPageSize)*vmPageSize:pageSize;
    compressed=length>0&&rounded<pageSize;payload=compressed?length:pageSize;mapped=compressed?rounded:pageSize;
    // Physical admission includes immutable export pins and fallible staged
    // replacement pages. Reserve under the same lock as registration/release.
    std::unique_lock<std::recursive_mutex> backingGuard;
    if(accounting){
        backingGuard=std::unique_lock(accounting->mutex);
        if(mapped>accounting->mappedLimit || accounting->mapped.load()>accounting->mappedLimit-mapped)return -ENOMEM;
    }
    bytes=static_cast<char*>(mmap(nullptr,mapped,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANON,-1,0));if(bytes==MAP_FAILED){bytes=nullptr;return -ENOMEM;}
    storage=std::make_shared<Backing>();storage->bytes=bytes;storage->mapped=mapped;storage->payload=payload;
    if(accounting){
        std::lock_guard g(accounting->mutex);
        if(accounting->backings.size()>=std::max(uint64_t(1024),accounting->backingLive*2)){
            auto& registry=accounting->backings;registry.erase(std::remove_if(registry.begin(),registry.end(),[](auto&w){return w.expired();}),registry.end());
        }
        accounting->backings.push_back(storage);storage->accounting=accounting;accounting->backingLive++;
        accounting->payload.fetch_add(payload);accounting->mapped.fetch_add(mapped);
    }
    memcpy(bytes,compressed?static_cast<const void*>(workspace.encoded.data()):static_cast<const void*>(source),payload);checksum=blockHash(source);strongChecksum=strongHash(source);return 0;
}catch(const std::bad_alloc&){if(bytes&&!storage){munmap(bytes,mapped);bytes=nullptr;}return -ENOMEM;}
Backing::~Backing(){if(bytes)munmap(bytes,mapped);if(accounting){std::lock_guard g(accounting->mutex);accounting->payload.fetch_sub(payload);accounting->mapped.fetch_sub(mapped);accounting->backingLive--;}}
int MappedPage::decode(char*dest)const{
    if(!bytes||payload==0||payload>mapped||mapped>pageSize)return -EIO;
    if(compressed){auto result=compression_decode_buffer(reinterpret_cast<uint8_t*>(dest),pageSize,reinterpret_cast<const uint8_t*>(bytes),payload,nullptr,COMPRESSION_LZ4);if(result!=pageSize)return -EIO;}
    else{if(payload!=pageSize)return -EIO;memcpy(dest,bytes,pageSize);}
    return blockHash(dest)==checksum&&strongHash(dest)==strongChecksum?0:-EIO;
}
void Node::account(){
    if(!accounting)return;
    std::lock_guard guard(accounting->mutex);
    Metrics current{pages.size()*pageSize+attributeBytes+target.size(),S_ISREG(mode)?uint64_t(size):0,payloadBytes,mappedBytes};
    accounting->logical.fetch_add(current.logical-charged.logical);
    accounting->content.fetch_add(current.content-charged.content);
    uint64_t metadata=1024+attrs.size()*256+namespaceBytes;
    accounting->metadata.fetch_add(metadata-chargedMetadata);charged=current;chargedMetadata=metadata;
}
Node::~Node(){if(accounting){std::lock_guard guard(accounting->mutex);accounting->logical.fetch_sub(charged.logical);accounting->content.fetch_sub(charged.content);accounting->metadata.fetch_sub(chargedMetadata);accounting->live.fetch_sub(1);}}
struct NodeChange {std::shared_ptr<Node> node;~NodeChange(){if(node)node->account();}};
DirectorySnapshot::~DirectorySnapshot(){if(accounting){std::lock_guard g(accounting->mutex);accounting->directoryBytes.fetch_sub(bytes);accounting->directoryLive--;}}
static std::shared_ptr<const std::vector<std::string>> directoryNames(std::vector<std::string>&&names,const std::shared_ptr<Accounting>&accounting){
    auto snapshot=std::make_shared<DirectorySnapshot>();snapshot->names=std::move(names);
    for(auto&name:snapshot->names)snapshot->bytes+=64+name.size();
    {std::lock_guard g(accounting->mutex);auto& registry=accounting->directories;
        if(registry.size()>=std::max(uint64_t(1024),accounting->directoryLive*2))registry.erase(std::remove_if(registry.begin(),registry.end(),[](auto&w){return w.expired();}),registry.end());
        registry.push_back(snapshot);snapshot->accounting=accounting;accounting->directoryBytes.fetch_add(snapshot->bytes);accounting->directoryLive++;
    }
    return std::shared_ptr<const std::vector<std::string>>(snapshot,&snapshot->names);
}
static timespec now(){ timespec t; clock_gettime(CLOCK_REALTIME,&t); return t; }
static uint64_t backingBudget(uint64_t capacity){
    // One serialized export; at most 64 MiB of historical pin growth plus one
    // bounded 4 MiB request. Larger concurrent overwrites receive ENOMEM/retry.
    const uint64_t extra=std::min(capacity,uint64_t(64*1024*1024))+4*1024*1024;
    return capacity>UINT64_MAX-extra?UINT64_MAX:capacity+extra;
}
MemoryFS::MemoryFS(uint64_t bytes,bool compressionEnabled):capacity(bytes),compression(compressionEnabled){accounting->mappedLimit=backingBudget(bytes);root=make(S_IFDIR|0755);}
std::shared_ptr<Node> MemoryFS::make(mode_t mode){
    if(nodes.size()>=std::max(uint64_t(1024),accounting->live.load()*2))nodes.erase(std::remove_if(nodes.begin(),nodes.end(),[](auto& w){return w.expired();}),nodes.end());
    if(accounting->live.load()>=100000) throw std::bad_alloc();
    auto n=std::make_shared<Node>();n->ino=nextIno++;n->mode=mode;n->uid=getuid();n->gid=getgid();
    n->atime=n->mtime=n->ctime=n->birth=now();nodes.push_back(n);n->accounting=accounting;accounting->live.fetch_add(1);n->account();return n;
}
static std::vector<std::string> parts(const std::string& path){
    std::vector<std::string> out;size_t start=0;
    while(start<path.size()){auto end=path.find('/',start);if(end==std::string::npos)end=path.size();auto p=path.substr(start,end-start);if(!p.empty()){if(p=="."||p==".."||p.size()>255)return {"\x01"};out.push_back(p);}start=end+1;}return out;
}
std::shared_ptr<Node> MemoryFS::lookup(const std::string& p)const{auto n=root;for(auto& c:parts(p)){if(!S_ISDIR(n->mode))return {};auto i=n->children.find(c);if(i==n->children.end())return {};n=i->second;}return n;}
std::pair<std::shared_ptr<Node>,std::string> MemoryFS::parent(const std::string& p)const{auto v=parts(p);if(v.empty())return {};auto name=v.back();v.pop_back();auto n=root;for(auto& c:v){auto i=n->children.find(c);if(i==n->children.end()||!S_ISDIR(i->second->mode))return {};n=i->second;}if(name=="\x01")return {};return {n,name};}
std::shared_ptr<Node> MemoryFS::file(const std::string& p,uint64_t h)const{if(h){auto i=handles.find(h);return i==handles.end()?nullptr:i->second;}return lookup(p);}
uint64_t MemoryFS::usedUnlocked()const{return accounting->logical.load();}
uint64_t MemoryFS::metadataUnlocked()const{return accounting->metadata.load()+handles.size()*256+accounting->directoryBytes.load();}
bool MemoryFS::metadataRoom(uint64_t extra)const{return metadataFits(capacity,metadataUnlocked(),extra);}
uint64_t MemoryFS::used()const{return usedUnlocked();}
uint64_t MemoryFS::limit()const{return capacity.load();}
Metrics MemoryFS::metrics()const{std::lock_guard g(accounting->mutex);return {accounting->logical.load(),accounting->content.load(),accounting->payload.load(),accounting->mapped.load()};}
bool MemoryFS::accountingOracleForTest()const{
    std::lock_guard g(mutex);Metrics m{};uint64_t meta=0,live=0;
    for(auto&w:nodes)if(auto n=w.lock()){
        live++;m.logical+=n->pages.size()*pageSize+n->target.size();if(S_ISREG(n->mode))m.content+=n->size;
        uint64_t names=0,subdirs=0;for(auto&[name,child]:n->children){names+=512+name.size();subdirs+=S_ISDIR(child->mode);}
        if(names!=n->namespaceBytes||subdirs!=n->subdirectories)return false;
        meta+=1024+n->attrs.size()*256+names;
        for(auto&[k,v]:n->attrs)m.logical+=k.size()+v.size();
        for(auto&[_,p]:n->pages){m.payload+=p.payload;m.mapped+=p.mapped;}
    }

    // Physical backing includes old pages pinned by a concurrent export and
    // detached inode lifetime; each shared mmap is counted exactly once.
    std::lock_guard backingGuard(accounting->mutex);uint64_t physicalPayload=0,physicalMapped=0;
    for(auto&w:accounting->backings)if(auto b=w.lock()){physicalPayload+=b->payload;physicalMapped+=b->mapped;}
    uint64_t snapshots=0;for(auto&w:accounting->directories)if(auto snapshot=w.lock())snapshots+=snapshot->bytes;
    return snapshots==accounting->directoryBytes.load()&&live==accounting->live.load()&&meta==accounting->metadata.load()&&m.logical==accounting->logical.load()&&m.content==accounting->content.load()&&physicalPayload==accounting->payload.load()&&physicalMapped==accounting->mapped.load();
}
int MemoryFS::corruptBlockForTest(const std::string&p,uint64_t index){std::lock_guard g(mutex);auto n=lookup(p);if(!n||!n->pages.contains(index))return -ENOENT;n->pages[index].checksum^=1;return 0;}
int MemoryFS::stat(const std::string&p,struct stat*s,uint64_t h){std::lock_guard g(mutex);auto n=file(p,h);if(!n)return h?-EBADF:-ENOENT;memset(s,0,sizeof(*s));s->st_ino=n->ino;s->st_mode=n->mode;s->st_uid=n->uid;s->st_gid=n->gid;s->st_nlink=S_ISDIR(n->mode)?2+n->subdirectories:n->links;s->st_size=n->size;s->st_blksize=pageSize;s->st_blocks=n->pages.size()*(pageSize/512);s->st_atimespec=n->atime;s->st_mtimespec=n->mtime;s->st_ctimespec=n->ctime;s->st_birthtimespec=n->birth;s->st_flags=n->flags;return 0;}
int MemoryFS::entries(const std::string&p,std::vector<std::string>&out){std::lock_guard g(mutex);auto n=lookup(p);if(!n)return -ENOENT;if(!S_ISDIR(n->mode))return -ENOTDIR;out={".",".."};for(auto& c:n->children)out.push_back(c.first);return 0;}
int MemoryFS::create(const std::string&p,mode_t mode,uint64_t*h,int flags)try{
    std::lock_guard g(mutex);if(frozen)return -EBUSY;auto [par,name]=parent(p);if(!par)return -ENOENT;
    if(par->children.contains(name))return -EEXIST;if(par->flags&UF_IMMUTABLE)return -EPERM;
    if(h&&(handles.size()>=4096||!metadataRoom(512)))return -EMFILE;if(!metadataRoom(2048+name.size()))return -ENOSPC;
    auto n=make(mode);const auto candidate=nextHandle;
    try{if(h){handles.emplace(candidate,n);handleFlags.emplace(candidate,flags);}par->children.emplace(name,n);}
    catch(...){handles.erase(candidate);handleFlags.erase(candidate);throw;}
    par->namespaceBytes+=512+name.size();par->subdirectories+=S_ISDIR(mode);par->account();par->mtime=par->ctime=now();changed(par);
    if(h){*h=candidate;nextHandle++;}return 0;
}catch(const std::bad_alloc&){return -ENOMEM;}
int MemoryFS::symlink(const std::string&t,const std::string&p){std::lock_guard g(mutex);if(t.size()>4096)return -ENAMETOOLONG;if(t.size()>capacity-usedUnlocked())return -ENOSPC;int e=create(p,S_IFLNK|0777);if(e)return e;auto n=lookup(p);n->target=t;n->size=t.size();n->account();changed(n,true);return 0;}
int MemoryFS::readlink(const std::string&p,std::string&t){std::lock_guard g(mutex);auto n=lookup(p);if(!n)return -ENOENT;if(!S_ISLNK(n->mode))return -EINVAL;t=n->target;return 0;}
int MemoryFS::link(const std::string&a,const std::string&b){std::lock_guard g(mutex);if(frozen)return -EBUSY;auto n=lookup(a);if(!n)return -ENOENT;if(S_ISDIR(n->mode))return -EPERM;if(S_ISLNK(n->mode))return -ENOTSUP;auto [par,name]=parent(b);if(!par)return -ENOENT;if(par->children.contains(name))return -EEXIST;if(!metadataRoom(512+name.size()))return -ENOSPC;par->children.emplace(name,n);par->namespaceBytes+=512+name.size();par->account();par->mtime=par->ctime=now();n->links++;n->ctime=now();changed(n);changed(par);return 0;}
int MemoryFS::rename(const std::string&a,const std::string&b)try{
    std::lock_guard g(mutex);if(frozen)return -EBUSY;if(a==b)return 0;if(a=="/"||b=="/"||b.starts_with(a+"/"))return -EINVAL;
    auto n=lookup(a);if(!n)return -ENOENT;auto [ap,an]=parent(a);auto [bp,bn]=parent(b);if(!ap||!bp)return -ENOENT;
    if((ap->flags|bp->flags|n->flags)&(UF_IMMUTABLE|UF_APPEND))return -EPERM;
    auto old=lookup(b);if(old){if(old==n)return 0;if(old->flags&(UF_IMMUTABLE|UF_APPEND))return -EPERM;if(S_ISDIR(old->mode)!=S_ISDIR(n->mode))return S_ISDIR(n->mode)?-ENOTDIR:-EISDIR;if(!old->children.empty())return -ENOTEMPTY;}
    auto extra=old?0:512+bn.size();if(extra>512+an.size()&&!metadataRoom(extra-512-an.size()))return -ENOSPC;
    if(old){bp->children.find(bn)->second=n;old->links--;bp->subdirectories-=S_ISDIR(old->mode);}
    else{bp->children.emplace(bn,n);bp->namespaceBytes+=extra;}
    bp->subdirectories+=S_ISDIR(n->mode);ap->children.erase(an);ap->namespaceBytes-=512+an.size();ap->subdirectories-=S_ISDIR(n->mode);
    ap->mtime=ap->ctime=bp->mtime=bp->ctime=n->ctime=now();ap->account();bp->account();changed(ap);changed(bp);changed(n);return 0;
}catch(const std::bad_alloc&){return -ENOMEM;}
int MemoryFS::remove(const std::string&p,bool dir){std::lock_guard g(mutex);if(frozen)return -EBUSY;auto n=lookup(p);NodeChange accountGuard{n};if(!n)return -ENOENT;if(n->flags&(UF_IMMUTABLE|UF_APPEND))return -EPERM;if(S_ISDIR(n->mode)!=dir)return dir?-ENOTDIR:-EISDIR;if(dir&&!n->children.empty())return -ENOTEMPTY;auto [par,name]=parent(p);if(!par)return -EPERM;par->children.erase(name);par->namespaceBytes-=512+name.size();par->subdirectories-=S_ISDIR(n->mode);par->mtime=par->ctime=now();par->account();n->links--;changed(par);changed(n);return 0;}
int MemoryFS::open(const std::string&p,uint64_t&h,int flags){
    std::lock_guard g(mutex);auto n=lookup(p);if(!n)return -ENOENT;if(!S_ISREG(n->mode))return -EISDIR;
    if((flags&O_ACCMODE)!=O_RDONLY&&frozen)return -EBUSY;
    if((flags&O_ACCMODE)!=O_RDONLY&&!(n->mode&S_IWUSR))return -EACCES;
    if((flags&O_ACCMODE)!=O_WRONLY&&!(n->mode&S_IRUSR))return -EACCES;
    if(handles.size()>=4096||!metadataRoom(512))return -EMFILE;
    const auto candidate=nextHandle;
    // Both allocating insertions precede the first data mutation. Erasing either
    // reservation is nonthrowing, including the truncate rejection path.
    try{
        if(openAllocationFailure==0)throw std::bad_alloc();
        handles.emplace(candidate,n);
        if(openAllocationFailure==1)throw std::bad_alloc();
        handleFlags.emplace(candidate,flags);
        if(openAllocationFailure==2)throw std::bad_alloc();
    }catch(const std::bad_alloc&){handles.erase(candidate);handleFlags.erase(candidate);return -ENOMEM;}
    if((flags&O_TRUNC)&&(flags&O_ACCMODE)!=O_RDONLY){
        int e=truncate(p,0);if(e){handles.erase(candidate);handleFlags.erase(candidate);return e;}
    }
    h=candidate;nextHandle++;return 0;
}
int MemoryFS::close(uint64_t h){std::lock_guard g(mutex);handleFlags.erase(h);if(auto i=dirEntries.find(h);i!=dirEntries.end()){dirEntries.erase(i);}return handles.erase(h)?0:-EBADF;}
int MemoryFS::read(const std::string&p,char*b,size_t count,int64_t off,uint64_t h){
    std::lock_guard g(mutex);if(off<0||count>4*1024*1024)return -EINVAL;auto n=file(p,h);if(!n)return h?-EBADF:-ENOENT;if(h&&(handleFlags[h]&O_ACCMODE)==O_WRONLY)return -EBADF;if(!S_ISREG(n->mode))return -EISDIR;if(off>=n->size)return 0;count=std::min(count,size_t(n->size-off));memset(b,0,count);char*decoded;try{decoded=workspace.decodeBuffer();}catch(const std::bad_alloc&){return -ENOMEM;}
    for(size_t done=0;done<count;){uint64_t pos=uint64_t(off)+done;size_t len=std::min(count-done,size_t(pageSize-pos%pageSize));auto i=n->pages.find(pos/pageSize);if(i!=n->pages.end()){int e=i->second.decode(decoded);if(e)return e;memcpy(b+done,decoded+pos%pageSize,len);}done+=len;}if(!frozen){n->atime=now();changed(n);}return int(count);
}
int MemoryFS::write(const std::string&p,const char*b,size_t count,int64_t off,uint64_t h){
    std::lock_guard g(mutex);if(frozen)return -EBUSY;if(off<0||count>4*1024*1024||uint64_t(off)>uint64_t(INT64_MAX)-count)return -EFBIG;auto n=file(p,h);NodeChange accountGuard{n};if(!n)return h?-EBADF:-ENOENT;if(h&&(handleFlags[h]&O_ACCMODE)==O_RDONLY)return -EBADF;if(n->flags&UF_IMMUTABLE)return -EPERM;if(h&&(handleFlags[h]&O_APPEND))off=n->size;if(uint64_t(off)>uint64_t(INT64_MAX)-count)return -EFBIG;if(!S_ISREG(n->mode))return -EISDIR;if(count==0)return 0;
    uint64_t first=uint64_t(off)/pageSize,last=(uint64_t(off)+count-1)/pageSize,missing=0;for(auto page=first;page<=last;page++)if(!n->pages.contains(page))missing++;(void)missing;
    // Stage every changed block before replacing any valid backing. Scratch is one
    // 64 KiB decoded block plus bounded system LZ4 workspace, never the whole file.
    std::map<uint64_t,MappedPage> staged;
    try{auto decoded=workspace.decodeBuffer();for(size_t done=0;done<count;){uint64_t pos=uint64_t(off)+done,index=pos/pageSize;size_t len=std::min(count-done,size_t(pageSize-pos%pageSize));auto old=n->pages.find(index);if(old!=n->pages.end()){int e=old->second.decode(decoded);if(e)return e;}else memset(decoded,0,pageSize);memcpy(decoded+pos%pageSize,b+done,len);MappedPage block;if(std::any_of(decoded,decoded+pageSize,[](char c){return c!=0;})){int e=block.encode(decoded,compression,accounting);if(e)return e;}staged.emplace(index,std::move(block));done+=len;}
    }catch(const std::bad_alloc&){return -ENOMEM;}
    uint64_t added=0,removed=0;for(auto&[key,b]:staged){if(b.bytes&&!n->pages.contains(key))added++;if(!b.bytes&&n->pages.contains(key))removed++;}
    if(added>removed&&(added-removed)>(capacity-usedUnlocked())/pageSize)return -ENOSPC;
    while(!staged.empty()){auto i=staged.begin();auto key=i->first;if(auto old=n->pages.find(key);old!=n->pages.end()){n->payloadBytes-=old->second.payload;n->mappedBytes-=old->second.mapped;n->pages.erase(old);}if(i->second.bytes){n->payloadBytes+=i->second.payload;n->mappedBytes+=i->second.mapped;n->pages.insert(staged.extract(i));}else staged.erase(i);}
    n->size=std::max(n->size,off+int64_t(count));n->mtime=n->ctime=now();changed(n,true);return int(count);
}
int MemoryFS::truncate(const std::string&p,int64_t size,uint64_t h){
    std::lock_guard g(mutex);if(frozen)return -EBUSY;if(size<0)return -EINVAL;auto n=file(p,h);NodeChange accountGuard{n};if(!n)return h?-EBADF:-ENOENT;if(h&&(handleFlags[h]&O_ACCMODE)==O_RDONLY)return -EBADF;if(n->flags&(UF_IMMUTABLE|UF_APPEND))return -EPERM;if(!S_ISREG(n->mode))return -EISDIR;
    uint64_t keep=(uint64_t(size)+pageSize-1)/pageSize;
    if(size<n->size&&size%pageSize){auto i=n->pages.find(uint64_t(size)/pageSize);if(i!=n->pages.end()){try{auto decoded=workspace.decodeBuffer();int e=i->second.decode(decoded);if(e)return e;memset(decoded+size%pageSize,0,pageSize-size%pageSize);MappedPage replacement;e=replacement.encode(decoded,compression,accounting);if(e)return e;n->payloadBytes+=replacement.payload-i->second.payload;n->mappedBytes+=replacement.mapped-i->second.mapped;if(std::any_of(decoded,decoded+pageSize,[](char c){return c!=0;}))i->second=std::move(replacement);
            else{n->payloadBytes-=replacement.payload;n->mappedBytes-=replacement.mapped;n->pages.erase(i);}}catch(const std::bad_alloc&){return -ENOMEM;}}}
    for(auto i=n->pages.lower_bound(keep);i!=n->pages.end();i++){n->payloadBytes-=i->second.payload;n->mappedBytes-=i->second.mapped;}
    n->pages.erase(n->pages.lower_bound(keep),n->pages.end());n->size=size;n->mtime=n->ctime=now();changed(n,true);return 0;
}
int MemoryFS::setattr(const std::string&p,const Attributes&a,uint64_t h){
    std::lock_guard g(mutex);if(frozen)return -EBUSY;auto n=file(p,h);NodeChange accountGuard{n};if(!n)return h?-EBADF:-ENOENT;
    constexpr uint32_t supported=0x3fU|0xf0000000U;if(a.valid&~supported)return -ENOTSUP;
    if((a.valid&2)&&a.uid!=getuid())return -EPERM;if((a.valid&4)&&a.gid!=getgid())return -EPERM;
    if((a.valid&0x80000000U)&&(a.flags&~uint32_t(UF_NODUMP|UF_HIDDEN)))return -ENOTSUP;
    for(auto bit:{4,5})if(a.valid&(1U<<bit)){auto t=bit==4?a.access:a.modify;if(t.tv_nsec!=UTIME_NOW&&t.tv_nsec!=UTIME_OMIT&&(t.tv_nsec<0||t.tv_nsec>=1000000000))return -EINVAL;}
    for(auto bit:{28,29,30})if(a.valid&(1U<<bit)){auto t=bit==28?a.birth:bit==29?a.change:a.backup;if(t.tv_nsec<0||t.tv_nsec>=1000000000)return -EINVAL;}
    if(a.valid&8){int e=truncate(p,a.size,h);if(e)return e;}
    if(a.valid&1)n->mode=(n->mode&S_IFMT)|(a.mode&07777);if(a.valid&2)n->uid=a.uid;if(a.valid&4)n->gid=a.gid;
    auto current=now();if((a.valid&16)&&a.access.tv_nsec!=UTIME_OMIT)n->atime=a.access.tv_nsec==UTIME_NOW?current:a.access;if((a.valid&32)&&a.modify.tv_nsec!=UTIME_OMIT)n->mtime=a.modify.tv_nsec==UTIME_NOW?current:a.modify;
    n->ctime=current;if(a.valid&(1U<<28))n->birth=a.birth;if(a.valid&(1U<<29))n->ctime=a.change;if(a.valid&(1U<<30))n->backup=a.backup;if(a.valid&(1U<<31))n->flags=a.flags;changed(n);return 0;
}
int MemoryFS::chmod(const std::string&p,mode_t m){std::lock_guard g(mutex);if(frozen)return -EBUSY;auto n=lookup(p);NodeChange accountGuard{n};if(!n)return -ENOENT;if(n->flags&UF_IMMUTABLE)return -EPERM;n->mode=(n->mode&S_IFMT)|(m&07777);n->ctime=now();changed(n);return 0;}
int MemoryFS::chown(const std::string&p,uid_t u,gid_t v){std::lock_guard g(mutex);if(frozen)return -EBUSY;auto n=lookup(p);NodeChange accountGuard{n};if(!n)return -ENOENT;if(u!=uid_t(-1)&&u!=getuid())return -EPERM;if(v!=gid_t(-1)&&v!=getgid())return -EPERM;if(u!=uid_t(-1))n->uid=u;if(v!=gid_t(-1))n->gid=v;changed(n);return 0;}
int MemoryFS::times(const std::string&p,const timespec t[2]){std::lock_guard g(mutex);if(frozen)return -EBUSY;auto n=lookup(p);NodeChange accountGuard{n};if(!n)return -ENOENT;for(int i=0;i<2;i++)if(t&&t[i].tv_nsec!=UTIME_NOW&&t[i].tv_nsec!=UTIME_OMIT&&(t[i].tv_nsec<0||t[i].tv_nsec>=1000000000))return -EINVAL;auto current=now();if(!t||t[0].tv_nsec!=UTIME_OMIT)n->atime=(!t||t[0].tv_nsec==UTIME_NOW)?current:t[0];if(!t||t[1].tv_nsec!=UTIME_OMIT)n->mtime=(!t||t[1].tv_nsec==UTIME_NOW)?current:t[1];n->ctime=current;changed(n);return 0;}
int MemoryFS::setxattr(const std::string&p,const std::string&k,const std::string&v,int flags){std::lock_guard g(mutex);if(frozen)return -EBUSY;auto n=lookup(p);NodeChange accountGuard{n};if(!n)return -ENOENT;if(n->flags&UF_IMMUTABLE)return -EPERM;if(flags&~(XATTR_CREATE|XATTR_REPLACE|XATTR_NOFOLLOW))return -EINVAL;if(k=="com.apple.decmpfs")return -ENOTSUP;if(k.empty()||k.size()>255||v.size()>1024*1024)return -E2BIG;bool exists=n->attrs.contains(k);if(!exists&&!metadataRoom(256+k.size()))return -ENOSPC;if((flags&XATTR_CREATE)&&exists)return -EEXIST;if((flags&XATTR_REPLACE)&&!exists)return -ENOATTR;uint64_t old=exists?k.size()+n->attrs[k].size():0;if(k.size()+v.size()>capacity-usedUnlocked()+old)return -ENOSPC;auto value=v;if(exists)n->attrs.find(k)->second.swap(value);else n->attrs.emplace(k,std::move(value));n->attributeBytes+=k.size()+v.size()-old;n->ctime=now();changed(n);return 0;}
int MemoryFS::getxattr(const std::string&p,const std::string&k,std::string&v){std::lock_guard g(mutex);auto n=lookup(p);if(!n)return -ENOENT;if(!n->attrs.contains(k))return -ENOATTR;v=n->attrs[k];return 0;}
int MemoryFS::setxattrAt(const std::string&p,const std::string&key,const std::string&value,int flags,uint32_t position){std::lock_guard g(mutex);if(!position)return setxattr(p,key,value,flags);if(key!="com.apple.ResourceFork")return -EINVAL;if(position>1024*1024||value.size()>1024*1024-position)return -E2BIG;std::string old;int e=getxattr(p,key,old);if(e&&e!=-ENOATTR)return e;if((flags&XATTR_CREATE)&&e==0)return -EEXIST;if((flags&XATTR_REPLACE)&&e==-ENOATTR)return -ENOATTR;if(old.size()<position+value.size())old.resize(position+value.size(),0);old.replace(position,value.size(),value);return setxattr(p,key,old,flags);}
int MemoryFS::getxattrAt(const std::string&p,const std::string&key,std::string&value,uint32_t position){std::lock_guard g(mutex);if(position&&key!="com.apple.ResourceFork")return -EINVAL;int e=getxattr(p,key,value);if(e)return e;if(position>=value.size())value.clear();else if(position)value.erase(0,position);return 0;}
int MemoryFS::listxattr(const std::string&p,std::string&v){std::lock_guard g(mutex);auto n=lookup(p);if(!n)return -ENOENT;v.clear();for(auto&a:n->attrs){v+=a.first;v+='\0';}return 0;}
int MemoryFS::removexattr(const std::string&p,const std::string&k){std::lock_guard g(mutex);if(frozen)return -EBUSY;auto n=lookup(p);NodeChange accountGuard{n};if(!n)return -ENOENT;if(n->flags&UF_IMMUTABLE)return -EPERM;auto i=n->attrs.find(k);if(i==n->attrs.end())return -ENOATTR;n->attributeBytes-=k.size()+i->second.size();n->attrs.erase(i);n->ctime=now();changed(n);return 0;}
int MemoryFS::openDirectory(const std::string&p,uint64_t&h)try{
    std::lock_guard g(mutex);auto n=lookup(p);if(!n)return -ENOENT;if(!S_ISDIR(n->mode))return -ENOTDIR;
    uint64_t extra=512+131;for(auto&[name,_]:n->children)extra+=64+name.size();
    if(handles.size()>=4096||!metadataRoom(extra))return -EMFILE;
    auto v=std::make_shared<std::vector<std::string>>();v->reserve(n->children.size()+2);v->push_back(".");v->push_back("..");for(auto&[name,_]:n->children)v->push_back(name);
    const auto candidate=nextHandle;
    try{handles.emplace(candidate,n);handleFlags.emplace(candidate,O_RDONLY);dirEntries.emplace(candidate,directoryNames(std::move(*v),accounting));}
    catch(...){handles.erase(candidate);handleFlags.erase(candidate);dirEntries.erase(candidate);throw;}
    h=candidate;nextHandle++;return 0;
}catch(const std::bad_alloc&){return -ENOMEM;}
int MemoryFS::directorySnapshot(uint64_t h,std::shared_ptr<const std::vector<std::string>>&v)try{
    std::lock_guard g(mutex);auto snapshot=dirEntries.find(h);if(snapshot==dirEntries.end())return -EBADF;
    if(!snapshot->second){
        auto n=file("",h);if(!n||n!=root||!S_ISDIR(n->mode))return -EBADF;
        uint64_t extra=131;for(auto&[name,_]:n->children)extra+=64+name.size();if(!metadataRoom(extra))return -EMFILE;
        auto entries=std::make_shared<std::vector<std::string>>();entries->reserve(n->children.size()+2);entries->push_back(".");entries->push_back("..");for(auto&[name,_]:n->children)entries->push_back(name);
        snapshot->second=directoryNames(std::move(*entries),accounting);
    }
    v=snapshot->second;return 0;
}catch(const std::bad_alloc&){return -ENOMEM;}
int MemoryFS::directoryEntries(uint64_t h,std::vector<std::string>&v){std::shared_ptr<const std::vector<std::string>> snapshot;int e=directorySnapshot(h,snapshot);if(!e)v=*snapshot;return e;}
int MemoryFS::checkHandle(uint64_t h,bool directory){std::lock_guard g(mutex);if(!handles.contains(h))return -EBADF;return S_ISDIR(handles[h]->mode)==directory?0:-EBADF;}
int MemoryFS::access(const std::string&p,int mask){std::lock_guard g(mutex);auto n=lookup(p);if(!n)return -ENOENT;if(mask&~(R_OK|W_OK|X_OK))return -EINVAL;if((mask&W_OK)&&frozen)return -EBUSY;if((mask&R_OK)&&!(n->mode&S_IRUSR))return -EACCES;if((mask&W_OK)&&!(n->mode&S_IWUSR))return -EACCES;if((mask&X_OK)&&!(n->mode&S_IXUSR))return -EACCES;return 0;}
int MemoryFS::flags(const std::string&p,uint32_t value){std::lock_guard g(mutex);if(frozen)return -EBUSY;if(value&~uint32_t(UF_NODUMP|UF_HIDDEN))return -ENOTSUP;auto n=lookup(p);NodeChange accountGuard{n};if(!n)return -ENOENT;n->flags=value;n->ctime=now();changed(n);return 0;}
int MemoryFS::extraTimes(const std::string&p,timespec*backup,timespec*birth,timespec*change,bool set){std::lock_guard g(mutex);if(set&&frozen)return -EBUSY;auto n=lookup(p);NodeChange accountGuard{n};if(!n)return -ENOENT;if(set){for(auto*t:{backup,birth,change})if(t&&(t->tv_nsec<0||t->tv_nsec>=1000000000))return -EINVAL;if(n->flags&UF_IMMUTABLE)return -EPERM;if(backup)n->backup=*backup;if(birth)n->birth=*birth;if(change)n->ctime=*change;changed(n);}else{if(backup)*backup=n->backup;if(birth)*birth=n->birth;if(change)*change=n->ctime;}return 0;}
int MemoryFS::exchange(const std::string&a,const std::string&b){std::lock_guard g(mutex);if(frozen)return -EBUSY;auto x=lookup(a),y=lookup(b);if(!x||!y)return -ENOENT;if(!S_ISREG(x->mode)||!S_ISREG(y->mode))return -EINVAL;if((x->flags|y->flags)&UF_IMMUTABLE)return -EPERM;auto[ap,an]=parent(a);auto[bp,bn]=parent(b);std::swap(ap->children[an],bp->children[bn]);ap->mtime=ap->ctime=bp->mtime=bp->ctime=now();changed(ap);changed(bp);return 0;}
int MemoryFS::renameExclusive(const std::string&a,const std::string&b){std::lock_guard g(mutex);if(lookup(b))return -EEXIST;return rename(a,b);}
void MemoryFS::statfs(struct statvfs*s){std::lock_guard g(mutex);memset(s,0,sizeof(*s));s->f_bsize=s->f_frsize=pageSize;s->f_blocks=capacity/pageSize;s->f_bfree=s->f_bavail=(capacity-usedUnlocked())/pageSize;s->f_files=100000;s->f_ffree=100000-accounting->live.load();s->f_namemax=255;}
int MemoryFS::resize(uint64_t bytes){std::lock_guard g(mutex);if(bytes<usedUnlocked())return -ENOSPC;{std::lock_guard a(accounting->mutex);accounting->mappedLimit=backingBudget(bytes);}capacity=bytes;return 0;}
void MemoryFS::freeze(bool v){std::lock_guard g(mutex);frozen=v;}
bool MemoryFS::isFrozen()const{std::lock_guard g(mutex);return frozen;}
// Small guards also cover allocation/injected-I/O exceptions while the tree is locked.
struct RestoreFrozen {bool& state;bool value;~RestoreFrozen(){state=value;}};
struct ScopedFD {int value;~ScopedFD(){if(value>=0)::close(value);}};
int MemoryFS::populate(const std::string&p,const std::string& modeDigest){
    std::lock_guard g(mutex);if(!root->children.empty())return -EBUSY;
    // Old callers must never silently import widened physical modes from a
    // managed v2 revision. Legacy sources have no out-of-namespace mode map.
    if(modeDigest.empty()&&fs::path(p).filename()=="data"){
        struct stat marker{};if(::lstat((fs::path(p).parent_path()/"modes.bin").c_str(),&marker)==0)return -EPROTONOSUPPORT;
        if(errno!=ENOENT)return -errno;
    }
    // FSKit may opendir the fresh root before startup import. Admit only those
    // complete, read-only directory handles, never detached nodes or file handles.
    if(handles.size()!=handleFlags.size()||handles.size()!=dirEntries.size())return -EBUSY;
    for(auto&[h,n]:handles){
        auto flags=handleFlags.find(h);
        if(!h||!n||n!=root||!S_ISDIR(n->mode)||flags==handleFlags.end()||flags->second!=O_RDONLY||!dirEntries.contains(h))return -EBUSY;
    }
    // The tree mutex makes invalidation and import indivisible to readers. Do
    // this before import so error/exception paths also expose any partial tree.
    for(auto&[_,snapshot]:dirEntries)snapshot.reset();
    RestoreFrozen restore{frozen,true};frozen=false;return importTree(p,modeDigest);
}
static int supportedSecurity(const fs::path& path){
    struct stat st{};if(::lstat(path.c_str(),&st))return -errno;
    if(st.st_uid!=getuid()||st.st_gid!=getgid())return -EPERM;
    if(S_ISLNK(st.st_mode)&&st.st_nlink>1)return -ENOTSUP;
    errno=0;acl_t acl=acl_get_link_np(path.c_str(),ACL_TYPE_EXTENDED);
    if(!acl)return errno==ENOENT||errno==ENOTSUP?0:-errno;
    acl_entry_t entry;int result=acl_get_entry(acl,ACL_FIRST_ENTRY,&entry);acl_free(acl);
    return result<0&&errno==EINVAL?0:-ENOTSUP;
}
int MemoryFS::importTree(const std::string& path,const std::string& modeDigest){
    std::lock_guard g(mutex);
    try{
        if(modeDigest.empty()&&fs::path(path).filename()=="data"){
            struct stat marker{};if(::lstat((fs::path(path).parent_path()/"modes.bin").c_str(),&marker)==0)return -EPROTONOSUPPORT;
            if(errno!=ENOENT)return -errno;
        }
        StorageModeMap modes;
        if(!modeDigest.empty()){int e=readStorageModes((fs::path(path).parent_path()/"modes.bin").string(),modes,modeDigest);if(e)return e;modes=includedStorageModes(modes);}
        // Complete security preflight before creating even the first native node.
        std::vector<fs::path> pending{fs::path(path)};
        std::set<std::string> seen;
        std::map<std::pair<dev_t,ino_t>,std::pair<mode_t,uint64_t>> logicalLinks;
        std::map<std::pair<dev_t,ino_t>,uint64_t> linkCounts;
        while(!pending.empty()){
            auto current=std::move(pending.back());pending.pop_back();
            struct stat st{};if(::lstat(current.c_str(),&st))return -errno;
            if(current!=fs::path(path)&&snapshotExcludedDirectory(current.filename().string(),st.st_mode))continue;
            int e=supportedSecurity(current);if(e)return e;
            if(!modeDigest.empty()){
                auto relative=current==fs::path(path)?"":current.lexically_relative(path).string();auto record=modes.find(relative);
                if(record==modes.end()||record->second.kind!=storageKind(st.st_mode)||(st.st_mode&07777)!=storagePhysical(record->second))return -ESTALE;
                seen.insert(relative);
                if(S_ISREG(st.st_mode)){
                    auto identity=std::pair(st.st_dev,st.st_ino);auto [it,inserted]=logicalLinks.emplace(identity,std::pair(record->second.mode,uint64_t(st.st_nlink)));
                    if(!inserted&&it->second.first!=record->second.mode)return -ESTALE;linkCounts[identity]++;
                }
            }
            if(S_ISDIR(st.st_mode))for(const auto& child:fs::directory_iterator(current))pending.push_back(child.path());
        }
        if(!modeDigest.empty()&&seen.size()!=modes.size())return -ESTALE;
        if(!modeDigest.empty())for(auto&[identity,record]:logicalLinks)if(linkCounts[identity]!=record.second)return -ESTALE;
        std::map<std::pair<dev_t,ino_t>,std::string> links;
        // One reusable heap block for the whole walk, independent of directory depth.
        std::vector<char> buffer(pageSize);
        struct Frame {
            fs::path src;std::string dest;struct stat st{};std::vector<fs::path> children;size_t next=0;bool entered=false;
            Frame(fs::path source,std::string target):src(std::move(source)),dest(std::move(target)){}
        };
        std::vector<Frame> stack;stack.push_back({fs::path(path),"/"});
        auto metadata=[&](const Frame& frame)->int{
            const auto& src=frame.src;const auto& dest=frame.dest;const auto& st=frame.st;
            // read(2) decoded file bytes: never replay decmpfs storage metadata.
            auto logicalFlags=S_ISREG(st.st_mode)?st.st_flags&~uint32_t(UF_COMPRESSED):st.st_flags;
            auto n=lookup(dest);NodeChange accountGuard{n};n->atime=st.st_atimespec;n->mtime=st.st_mtimespec;n->mode=st.st_mode;n->birth=st.st_birthtimespec;
            if(!modeDigest.empty()){
                auto i=modes.find(dest=="/"?"":dest.substr(1));
                if(i==modes.end()||i->second.kind!=storageKind(st.st_mode)||(st.st_mode&07777)!=storagePhysical(i->second))return -ESTALE;
                n->mode=(st.st_mode&S_IFMT)|i->second.mode;
            }
            if(logicalFlags&~uint32_t(UF_NODUMP|UF_HIDDEN))return -ENOTSUP;n->flags=logicalFlags;
            // Without XATTR_SHOWCOMPRESSION, storage resource forks remain hidden.
            auto size=importAttributeLister(src.c_str(),nullptr,0,XATTR_NOFOLLOW);
            if(size<0&&errno!=ENOTSUP&&errno!=ENOATTR)return -errno;
            if(size>0){
                std::vector<char> keys(size);auto listed=importAttributeLister(src.c_str(),keys.data(),keys.size(),XATTR_NOFOLLOW);if(listed<0)return -errno;if(listed!=size)return -ESTALE;
                for(size_t pos=0;pos<keys.size();){
                    auto end=std::find(keys.begin()+pos,keys.end(),char(0));if(end==keys.end())return -EIO;std::string k(keys.begin()+pos,end);pos+=k.size()+1;if(k=="com.apple.decmpfs")continue;
                    auto len=importAttributeReader(src.c_str(),k.c_str(),nullptr,0,0,XATTR_NOFOLLOW);if(len<0)return -errno;
                    if(len>1024*1024)return -E2BIG;std::string v(len,'\0');auto got=importAttributeReader(src.c_str(),k.c_str(),v.data(),v.size(),0,XATTR_NOFOLLOW);if(got<0)return -errno;if(got!=len)return -ESTALE;
                    int e=setxattr(dest,k,v,0);if(e)return e;advanced();
                }
            }
            struct stat after{};if(::lstat(src.c_str(),&after))return -errno;
            if(after.st_ino!=st.st_ino||after.st_dev!=st.st_dev||after.st_mode!=st.st_mode||after.st_uid!=st.st_uid||after.st_gid!=st.st_gid||after.st_size!=st.st_size||after.st_ctimespec.tv_sec!=st.st_ctimespec.tv_sec||after.st_ctimespec.tv_nsec!=st.st_ctimespec.tv_nsec)return -ESTALE;
            changed(n);advanced();return 0;
        };
        while(!stack.empty()){
            auto& frame=stack.back();int e=0;
            if(!frame.entered){
                if(::lstat(frame.src.c_str(),&frame.st))return -errno;
                if(frame.dest!="/"&&snapshotExcludedDirectory(frame.src.filename().string(),frame.st.st_mode)){stack.pop_back();continue;}
                int security=supportedSecurity(frame.src);if(security)return security;
                auto& st=frame.st;
                if(S_ISDIR(st.st_mode)){
                    if(frame.dest!="/"){e=create(frame.dest,st.st_mode);if(e)return e;advanced();}
                    for(auto& child:fs::directory_iterator(frame.src))frame.children.push_back(child.path());frame.entered=true;
                }else{
                    if(S_ISLNK(st.st_mode)){
                        // A symlink buffer is bounded too; it does not live per directory.
                        auto count=::readlink(frame.src.c_str(),buffer.data(),4096);if(count<0)return -errno;
                        e=symlink(std::string(buffer.data(),count),frame.dest);if(e)return e;
                    }else if(S_ISREG(st.st_mode)){
                        auto key=std::pair(st.st_dev,st.st_ino);
                        if(links.contains(key)){e=link(links[key],frame.dest);if(e)return e;advanced();stack.pop_back();continue;}
                        links[key]=frame.dest;e=create(frame.dest,st.st_mode);if(e)return e;
                        ScopedFD fd{::open(frame.src.c_str(),O_RDONLY|O_NOFOLLOW|O_CLOEXEC)};if(fd.value<0)return -errno;
                        struct stat before;if(::fstat(fd.value,&before))return -errno;
                        if(before.st_ino!=st.st_ino||before.st_dev!=st.st_dev)return -ESTALE;
                        int64_t off=0;bool extents=!(before.st_flags&UF_COMPRESSED);
                        while(off<before.st_size){
                            if(extents){
                                auto data=extentSeeker(fd.value,off,SEEK_DATA);
                                if(data<0){const int error=errno;if(error==ENXIO){off=before.st_size;break;}if(unsupportedExtents(error))extents=false;else return -error;}
                                else off=std::max(off,int64_t(data/pageSize*pageSize));
                            }
                            if(off>=before.st_size)break;
                            if(::lseek(fd.value,off,SEEK_SET)<0)return -errno;
                            size_t wanted=size_t(std::min(int64_t(pageSize),before.st_size-off)),done=0;
                            while(done<wanted){auto count=importReader(fd.value,buffer.data()+done,wanted-done);if(count<0&&errno==EINTR)continue;if(count<0)return -errno;if(!count)return -ESTALE;done+=size_t(count);}
                            if(std::any_of(buffer.begin(),buffer.begin()+wanted,[](char c){return c!=0;})){
                                e=write(frame.dest,buffer.data(),wanted,off);if(e<0)return e;
                            }
                            off+=wanted;advanced();
                        }
                        struct stat after;if(::fstat(fd.value,&after))return -errno;
                        if(off!=before.st_size||after.st_size!=before.st_size||after.st_mtimespec.tv_sec!=before.st_mtimespec.tv_sec||after.st_mtimespec.tv_nsec!=before.st_mtimespec.tv_nsec||after.st_ctimespec.tv_sec!=before.st_ctimespec.tv_sec||after.st_ctimespec.tv_nsec!=before.st_ctimespec.tv_nsec)return -ESTALE;
                        e=truncate(frame.dest,st.st_size);if(e)return e;
                    }else return -ENOTSUP;
                    e=metadata(frame);if(e)return e;stack.pop_back();continue;
                }
            }
            if(frame.next<frame.children.size()){
                auto src=frame.children[frame.next++];
                auto dest=frame.dest=="/"?"/"+src.filename().string():frame.dest+"/"+src.filename().string();
                stack.push_back({std::move(src),std::move(dest)});
            }else{
                // Postorder preserves directory timestamps/flags after children.
                e=metadata(frame);if(e)return e;stack.pop_back();
            }
        }
        return 0;
    }catch(const fs::filesystem_error&e){return -e.code().value();}catch(const std::bad_alloc&){return -ENOMEM;}catch(...){return -EIO;}
}
static int openDirectoryNoFollow(const std::string& path){
    ScopedFD fd{::open("/",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)};if(fd.value<0)return -1;
    for(auto& part:parts(path)){auto next=::openat(fd.value,part.c_str(),O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(next<0)return -1;::close(fd.value);fd.value=next;}
    int result=fd.value;fd.value=-1;return result;
}
// A pinned tree owns copies of namespace/metadata and shared immutable page
// backing. Disk work never observes mutable Node maps and never holds tree.mutex.
int MemoryFS::exportTree(const std::string&path,bool keepFrozen,const std::string&previous,uint64_t previousGeneration,bool privateStorage){
    std::lock_guard exportGuard(exportMutex);
    ExportStats stats;bool wasFrozen=false,success=false,noOp=false;
    std::vector<std::pair<std::shared_ptr<Node>,std::string>> items;
    std::unordered_map<uint64_t,std::shared_ptr<Node>> snapshots;
    std::unordered_map<uint64_t,Checkpoint> oldCheckpoint,newCheckpoint;
    struct ThawGuard {MemoryFS* fs;bool& success;bool& old;bool keep;~ThawGuard(){if(keep&&!success){std::lock_guard g(fs->mutex);fs->frozen=old;}}} thaw{this,success,wasFrozen,keepFrozen};
    try{
        {
            std::lock_guard g(mutex);wasFrozen=frozen;if(keepFrozen)frozen=true;
            stats.generation=generation;oldCheckpoint=checkpoint;
            noOp=!previous.empty()&&previousGeneration==checkpointGeneration&&generation==checkpointGeneration;
            // Transient decoded data remains two 64 KiB buffers. Captured
            // namespace/metadata/page-index copies have a separate finite cap.
            const uint64_t captureLimit=captureLimitForTest?captureLimitForTest:std::max(uint64_t(1024*1024),std::min(uint64_t(128*1024*1024),metadataBudget(capacity)));
            uint64_t captureBytes=0;
            auto reserveCapture=[&](uint64_t amount){if(amount>captureLimit||captureBytes>captureLimit-amount)throw std::bad_alloc();captureBytes+=amount;};
            reserveCapture(512);
            std::vector<std::pair<std::shared_ptr<Node>,std::string>> pending{{root,""}};
            while(!pending.empty()){
                auto [original,relative]=std::move(pending.back());pending.pop_back();
                std::shared_ptr<Node> copy;
                if(auto i=snapshots.find(original->ino);i!=snapshots.end())copy=i->second;
                else{
                    uint64_t nodeBytes=sizeof(Node)+256+original->namespaceBytes+original->pages.size()*(sizeof(MappedPage)+64)+original->attributeBytes+original->attrs.size()*128;
                    reserveCapture(nodeBytes);
                    copy=std::make_shared<Node>(*original);copy->accounting.reset();copy->children.clear();
                    snapshots.emplace(original->ino,copy);
                }
                for(auto i=original->children.rbegin();i!=original->children.rend();++i){
                    if(snapshotExcludedDirectory(i->first,i->second->mode))continue;
                    reserveCapture(512+relative.size()+1+i->first.size());
                    pending.emplace_back(i->second,relative.empty()?i->first:relative+"/"+i->first);
                }
                items.emplace_back(copy,std::move(relative));
            }
            // Global generation includes disposable Trash changes. Reuse is
            // possible when every included inode and its canonical path match
            // the checkpoint. Independent disk verification below still runs.
            if(!noOp&&!previous.empty()&&previousGeneration==checkpointGeneration&&snapshots.size()==oldCheckpoint.size()){
                noOp=true;std::set<uint64_t> seen;
                for(auto&[n,relative]:items)if(seen.insert(n->ino).second){
                    auto old=oldCheckpoint.find(n->ino);
                    if(old==oldCheckpoint.end()||old->second.data!=n->dataGeneration||old->second.metadata!=n->metadataGeneration||old->second.path!=relative){noOp=false;break;}
                }
            }
        }
        StorageModeMap modes;
        if(privateStorage){for(auto&[n,relative]:items)modes.emplace(relative,StorageMode{storageKind(n->mode),mode_t(n->mode&07777)});int e=validateStorageModes(modes);if(e)return e;stats.modeMapDigest=storageDigest(encodeStorageModes(modes));}
        StorageModeMap priorModes;
        if(privateStorage&&!previous.empty()){
            int e=readStorageModes((fs::path(previous).parent_path()/"modes.bin").string(),priorModes);if(e)return e;
            priorModes=includedStorageModes(priorModes);
            if(noOp&&priorModes!=modes)return -ESTALE;
        }
        std::vector<char> decoded(pageSize),disk(pageSize);
        ScopedFD oldRoot{previous.empty()? -1 : openDirectoryNoFollow(previous)};
        if(!previous.empty()&&oldRoot.value<0)return -errno;
        auto openPrevious=[&](const std::string&relative)->int{
            ScopedFD current{::dup(oldRoot.value)};if(current.value<0)return -1;
            auto components=parts(relative);
            for(size_t i=0;i<components.size();i++){
                int next=::openat(current.value,components[i].c_str(),O_RDONLY|O_NOFOLLOW|O_CLOEXEC|(i+1<components.size()?O_DIRECTORY:0));
                if(next<0)return -1;::close(current.value);current.value=next;
            }
            int result=current.value;current.value=-1;return result;
        };
        // Independent disk readback covers data in unexpected extents as well as
        // expected pages. Sparse holes cannot conceal injected nonzero content.
        auto validateData=[&](const std::shared_ptr<Node>&n,int fd)->int{
            struct stat st{};if(::fstat(fd,&st))return -errno;if(st.st_size!=n->size||!S_ISREG(st.st_mode))return -ESTALE;
            std::set<uint64_t> pages;for(auto&[index,_]:n->pages)pages.insert(index);
            int64_t offset=0;bool extents=(st.st_flags&UF_COMPRESSED)==0;
            while(offset<n->size){
                if(extents){auto data=extentSeeker(fd,offset,SEEK_DATA);if(data<0){const int error=errno;if(error==ENXIO)break;if(unsupportedExtents(error))extents=false;else return -error;}else offset=std::max(offset,int64_t(data/pageSize*pageSize));}
                if(offset>=n->size)break;pages.insert(uint64_t(offset)/pageSize);offset+=std::min(int64_t(pageSize),n->size-offset);
            }
            for(auto index:pages){
                std::fill(disk.begin(),disk.end(),0);auto count=size_t(std::min(int64_t(pageSize),n->size-int64_t(index*pageSize)));size_t done=0;
                while(done<count){auto got=::pread(fd,disk.data()+done,count-done,off_t(index*pageSize+done));if(got<0&&errno==EINTR)continue;if(got<=0)return got<0?-errno:-EIO;done+=size_t(got);stats.readback+=size_t(got);advanced();}
                auto block=n->pages.find(index);
                if(block==n->pages.end()){if(std::any_of(disk.begin(),disk.end(),[](char c){return c!=0;}))return -EIO;}
                else if(strongHash(disk.data())!=block->second.strongChecksum)return -EIO;
            }
            return 0;
        };
        auto validateMetadata=[&](const std::shared_ptr<Node>&n,const fs::path&dest)->int{
            struct stat st{};if(::lstat(dest.c_str(),&st))return -errno;
            auto physical=privateStorage?((n->mode&S_IFMT)|storagePhysical(StorageMode{storageKind(n->mode),mode_t(n->mode&07777)})):n->mode;
            if(st.st_mode!=physical||st.st_uid!=n->uid||st.st_gid!=n->gid||st.st_flags!=n->flags)return -ESTALE;
            if(!S_ISDIR(n->mode)&&(st.st_mtimespec.tv_sec!=n->mtime.tv_sec||st.st_mtimespec.tv_nsec!=n->mtime.tv_nsec))return -ESTALE;
            int security=supportedSecurity(dest);if(security)return security;
            auto count=::listxattr(dest.c_str(),nullptr,0,XATTR_NOFOLLOW);if(count<0)return -errno;
            std::vector<char> keys(count);if(count&&::listxattr(dest.c_str(),keys.data(),keys.size(),XATTR_NOFOLLOW)!=count)return -ESTALE;
            auto receipt=oldCheckpoint.find(n->ino);size_t expectedCount=n->attrs.size();
            if(receipt!=oldCheckpoint.end())for(auto&[key,_]:receipt->second.generatedAttributes)if(!n->attrs.contains(key))expectedCount++;
            size_t attrs=0;
            for(size_t pos=0;pos<keys.size();){
                auto end=std::find(keys.begin()+pos,keys.end(),char(0));if(end==keys.end())return -EIO;std::string key(keys.begin()+pos,end);pos+=key.size()+1;
                const std::string* expected=nullptr;
                if(auto logical=n->attrs.find(key);logical!=n->attrs.end())expected=&logical->second;
                else if(receipt!=oldCheckpoint.end()){auto generated=receipt->second.generatedAttributes.find(key);if(generated!=receipt->second.generatedAttributes.end())expected=&generated->second;}
                if(!expected)return -ESTALE;
                auto len=::getxattr(dest.c_str(),key.c_str(),nullptr,0,0,XATTR_NOFOLLOW);if(len<0)return -errno;if(size_t(len)!=expected->size())return -ESTALE;
                std::string value(len,0);if(::getxattr(dest.c_str(),key.c_str(),value.data(),value.size(),0,XATTR_NOFOLLOW)!=len||value!=*expected)return -ESTALE;attrs++;
            }
            return attrs==expectedCount?0:-ESTALE;
        };
        auto verifyMemory=[&](const std::shared_ptr<Node>&n)->int{for(auto&[_,block]:n->pages){int e=block.decode(decoded.data());if(e)return e;stats.decoded+=pageSize;}return 0;};
        if(noOp){
            std::set<std::string> expectedPaths;
            std::map<uint64_t,std::pair<dev_t,ino_t>> aliases;
            std::map<std::pair<dev_t,ino_t>,uint64_t> identities;
            std::map<std::pair<dev_t,ino_t>,std::pair<uint64_t,uint64_t>> physicalLinks;
            for(auto&[n,relative]:items){
                auto dest=fs::path(previous)/relative;int e=validateMetadata(n,dest);if(e)return e;expectedPaths.insert(relative);
                if(S_ISREG(n->mode)){
                    ScopedFD fd{openPrevious(relative)};if(fd.value<0)return -errno;struct stat st{};if(::fstat(fd.value,&st))return -errno;auto identity=std::pair(st.st_dev,st.st_ino);
                    auto& bounds=physicalLinks[identity];bounds.first++;bounds.second=st.st_nlink;
                    if(auto alias=aliases.find(n->ino);alias!=aliases.end()){if(alias->second!=identity)return -ESTALE;}
                    else{if(identities.contains(identity))return -ESTALE;aliases.emplace(n->ino,identity);identities.emplace(identity,n->ino);e=verifyMemory(n);if(e)return e;e=validateData(n,fd.value);if(e)return e;}
                }
                if(S_ISLNK(n->mode)){std::vector<char> target(4097);auto size=::readlink(dest.c_str(),target.data(),4096);if(size<0||std::string(target.data(),size)!=n->target)return -ESTALE;}
            }
            for(auto&[_,bounds]:physicalLinks)if(bounds.first!=bounds.second)return -EXDEV;
            std::vector<fs::path> pending{fs::path(previous)};while(!pending.empty()){auto directory=std::move(pending.back());pending.pop_back();for(auto& child:fs::directory_iterator(directory)){struct stat st{};if(::lstat(child.path().c_str(),&st))return -errno;if(snapshotExcludedDirectory(child.path().filename().string(),st.st_mode))continue;auto relative=child.path().lexically_relative(previous).string();if(!expectedPaths.contains(relative))return -ESTALE;if(S_ISDIR(st.st_mode))pending.push_back(child.path());}}
            // The included disk view is unchanged, but the session generation
            // still covers disposable Trash mutations for quiesce/thaw safety.
            stats.reused=true;success=true;std::lock_guard g(mutex);checkpointGeneration=stats.generation;exportStats=stats;return 0;
        }
        std::map<uint64_t,fs::path> links;
        for(auto&[n,relative]:items){
            auto dest=fs::path(path)/relative;
            if(S_ISDIR(n->mode)){if(::mkdir(dest.c_str(),0700))return -errno;advanced();continue;}
            if(S_ISLNK(n->mode)){if(::symlink(n->target.c_str(),dest.c_str()))return -errno;continue;}
            if(links.contains(n->ino)){if(::link(links[n->ino].c_str(),dest.c_str()))return -errno;continue;}
            stats.files++;links[n->ino]=dest;newCheckpoint.emplace(n->ino,Checkpoint{n->dataGeneration,n->metadataGeneration,relative});
            int e=0;bool cloned=false;
            auto old=oldCheckpoint.find(n->ino);
            if(oldRoot.value>=0&&previousGeneration==checkpointGeneration&&old!=oldCheckpoint.end()&&old->second.data==n->dataGeneration){
                // Old checkpoints can have anchored an included alias inside
                // excluded Trash. Never open that path or widen its inode.
                auto components=parts(old->second.path);if(components.size()>1&&std::find(components.begin(),components.end()-1,".Trashes")!=components.end()-1)return -EXDEV;
                int security=supportedSecurity(fs::path(previous)/old->second.path);if(security)return security;
                ScopedFD prior{openPrevious(old->second.path)};
                if(prior.value<0)return -errno;
                e=verifyMemory(n);if(e)return e;e=validateData(n,prior.value);if(e)return e;
                struct stat priorInfo{};if(::fstat(prior.value,&priorInfo))return -errno;
                if(privateStorage){auto record=priorModes.find(old->second.path);if(record==priorModes.end()||record->second.kind!=2||(priorInfo.st_mode&07777)!=storagePhysical(record->second))return -ESTALE;}
                // A storage-compressed candidate can hide logical data from
                // SEEK_DATA and carries decmpfs state that must not be replayed.
                // Validate decoded bytes above, then regenerate from RAM instead.
                if(!(priorInfo.st_flags&UF_COMPRESSED)){
                    if(::fclonefileat(prior.value,AT_FDCWD,dest.c_str(),CLONE_NOFOLLOW)==0){cloned=true;stats.clonedFiles++;}
                    else if(errno!=ENOTSUP&&errno!=EXDEV&&errno!=EINVAL)return -errno;
                }
            }
            ScopedFD fd{::open(dest.c_str(),(cloned?O_RDONLY:O_RDWR)|O_NOFOLLOW|O_CLOEXEC|(cloned?0:O_CREAT|O_EXCL),0600)};if(fd.value<0)return -errno;
            if(cloned){
                // Finish this owned copy with CURRENT metadata, including removals.
                // The previous revision remains untouched and never shares an inode.
                if(::fchmod(fd.value,0600))return -errno;
                auto count=::flistxattr(fd.value,nullptr,0,0);if(count<0)return -errno;std::vector<char> keys(count);
                if(count&&::flistxattr(fd.value,keys.data(),keys.size(),0)!=count)return -ESTALE;
                for(size_t pos=0;pos<keys.size();){auto end=std::find(keys.begin()+pos,keys.end(),char(0));if(end==keys.end())return -EIO;std::string key(keys.begin()+pos,end);pos+=key.size()+1;if(!n->attrs.contains(key)&&::fremovexattr(fd.value,key.c_str(),0))return -errno;}
            }
            if(!cloned){
                for(auto&[page,block]:n->pages){e=block.decode(decoded.data());if(e)return e;stats.decoded+=pageSize;auto count=size_t(std::min(int64_t(pageSize),n->size-int64_t(page*pageSize)));size_t done=0;
                    while(done<count){auto wrote=exportWriter(fd.value,decoded.data()+done,count-done,off_t(page*pageSize+done));if(wrote<0&&errno==EINTR)continue;if(wrote<=0||size_t(wrote)>count-done)return wrote<0&&errno?-errno:-EIO;done+=size_t(wrote);stats.written+=size_t(wrote);advanced();}
                }
            }
            if((!cloned&&::ftruncate(fd.value,n->size))||::fsync(fd.value))return -errno;
            e=validateData(n,fd.value);if(e)return e;
        }
        // Metadata is applied postorder while descriptors still permit inode
        // fsync, including mode 000 directories. The enclosing stage is private.
        std::set<uint64_t> metadataApplied;
        for(auto i=items.rbegin();i!=items.rend();++i){
            auto n=i->first;if(!metadataApplied.insert(n->ino).second)continue;auto dest=fs::path(path)/i->second;
            ScopedFD fd{S_ISLNK(n->mode)? -1 : ::open(dest.c_str(),O_RDONLY|O_NOFOLLOW|O_CLOEXEC|(S_ISDIR(n->mode)?O_DIRECTORY:0))};if(!S_ISLNK(n->mode)&&fd.value<0)return -errno;
            for(auto&[key,value]:n->attrs){if(::setxattr(dest.c_str(),key.c_str(),value.data(),value.size(),0,XATTR_NOFOLLOW))return -errno;advanced();}
            auto& receipt=newCheckpoint.try_emplace(n->ino,Checkpoint{n->dataGeneration,n->metadataGeneration,i->second}).first->second;
            auto count=::listxattr(dest.c_str(),nullptr,0,XATTR_NOFOLLOW);if(count<0)return -errno;std::vector<char> keys(count);
            if(count&&::listxattr(dest.c_str(),keys.data(),keys.size(),XATTR_NOFOLLOW)!=count)return -ESTALE;
            for(size_t pos=0;pos<keys.size();){auto end=std::find(keys.begin()+pos,keys.end(),char(0));if(end==keys.end())return -EIO;std::string key(keys.begin()+pos,end);pos+=key.size()+1;if(n->attrs.contains(key))continue;
                if(key!="com.apple.provenance")return -ESTALE; // only known OS-created metadata, never arbitrary private-stage additions
                auto length=::getxattr(dest.c_str(),key.c_str(),nullptr,0,0,XATTR_NOFOLLOW);if(length<0)return -errno;if(length>1024*1024)return -E2BIG;std::string value(length,0);if(::getxattr(dest.c_str(),key.c_str(),value.data(),value.size(),0,XATTR_NOFOLLOW)!=length)return -ESTALE;receipt.generatedAttributes.emplace(key,std::move(value));
            }
            if(!S_ISLNK(n->mode)&&::fchmod(fd.value,privateStorage?storagePhysical(modes.at(i->second)):n->mode&07777))return -errno;
            if(privateStorage&&S_ISLNK(n->mode)&&::fchmodat(AT_FDCWD,dest.c_str(),storagePhysical(modes.at(i->second)),AT_SYMLINK_NOFOLLOW))return -errno;
            timespec ts[2]={n->atime,n->mtime};if(::utimensat(AT_FDCWD,dest.c_str(),ts,AT_SYMLINK_NOFOLLOW))return -errno;
            if(::lchflags(dest.c_str(),n->flags))return -errno;
            if(fd.value>=0&&::fsync(fd.value))return -errno;
            advanced();
        }
        if(privateStorage){int e=writeStorageModes(path+".modes",modes);if(e)return e;}
        {std::lock_guard g(mutex);checkpoint=std::move(newCheckpoint);checkpointGeneration=stats.generation;exportStats=stats;}
        success=true;return 0;
    }catch(const fs::filesystem_error&e){return -e.code().value();}catch(const std::bad_alloc&){return -ENOMEM;}catch(...){return -EIO;}
}
}
