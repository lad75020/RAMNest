#include "MemoryFS.hpp"
#include "DebugProfile.hpp"
#include <algorithm>
#include <compression.h>
#include <cassert>
#include <filesystem>
#include <fstream>
#include <future>
#include <iostream>
#include <sstream>
#include <iomanip>
using namespace ramnest;
namespace fs=std::filesystem;
static std::vector<char> data(size_t n,bool compressed){std::vector<char> b(n,'Z');uint32_t x=17;for(auto& c:b){x=x*1664525U+1013904223U;if(!compressed)c=char(x>>24);}return b;}
static void file(MemoryFS& t,const std::vector<char>& b){assert(!t.create("/f",S_IFREG|0600));assert(t.write("/f",b.data(),b.size(),0)==int(b.size()));}
static bool timeEqual(timespec a,timespec b){return a.tv_sec==b.tv_sec&&a.tv_nsec==b.tv_nsec;}
struct State {
    Metrics metrics;struct stat st{};uint64_t generation;
    explicit State(MemoryFS& t):metrics(t.metrics()),generation(t.checkpointState().first){assert(!t.stat("/f",&st));}
    void unchanged(MemoryFS& t){auto m=t.metrics();struct stat now{};assert(!t.stat("/f",&now));assert(m.logical==metrics.logical&&m.content==metrics.content&&m.payload==metrics.payload&&m.mapped==metrics.mapped);assert(now.st_size==st.st_size&&timeEqual(now.st_atimespec,st.st_atimespec)&&timeEqual(now.st_mtimespec,st.st_mtimespec)&&timeEqual(now.st_ctimespec,st.st_ctimespec));assert(generation==t.checkpointState().first&&t.accountingOracleForTest());}
};
static void flip(MemoryFS& t,bool digest,uint64_t page){assert(!(digest?t.flipDigestByteForTest("/f",page,31):t.flipPayloadByteForTest("/f",page)));}
static void restored(MemoryFS& t,const std::vector<char>& b){std::vector<char> out(b.size());assert(t.read("/f",out.data(),out.size(),0)==int(b.size())&&out==b);assert(t.accountingOracleForTest());}
static std::string hex(const std::array<unsigned char,32>& d){std::ostringstream s;for(auto c:d)s<<std::hex<<std::setw(2)<<std::setfill('0')<<unsigned(c);return s.str();}
static void pages(){
    for(bool compressed:{false,true}){
        auto b=data(pageSize,compressed);MappedPage p;assert(!p.encode(b.data(),compressed)&&p.compressed==compressed);std::vector<char> out(pageSize);
        if(compressed)assert(hex(p.strongChecksum)=="944044fe482bc4e91085c15c5a923a1b9e02eac98d3bce04997d6dbecd2a5b8d");
        assert(!p.readSlice(out.data(),0,1)&&out[0]==b[0]);
        // Actual backing corruption after prior success. Raw mutation is outside
        // the requested byte; the compressed stream header is changed separately.
        auto offset=compressed?0:pageSize-1;p.bytes[offset]^=1;assert(p.readSlice(out.data(),0,1)==-EIO);p.bytes[offset]^=1;assert(!p.decode(out.data())&&out==b);
        p.strongChecksum[31]^=1;assert(p.readSlice(out.data(),0,1)==-EIO);p.strongChecksum[31]^=1;assert(!p.decode(out.data())&&out==b);
        auto payload=p.payload;p.payload=0;assert(p.decode(out.data())==-EIO);p.payload=payload;
        auto mapped=p.mapped;p.mapped=payload-1;assert(p.decode(out.data())==-EIO);p.mapped=mapped;
        p.mapped=pageSize+1;assert(p.decode(out.data())==-EIO);p.mapped=mapped;
        p.payload=compressed?1:pageSize-1;assert(p.decode(out.data())==-EIO);p.payload=payload;assert(!p.decode(out.data())&&out==b);
    }
    // A valid compressed stream can decode to the full length with only bytes
    // outside the requested slice changed. Require the digest to catch it.
    auto tail=data(pageSize,true);tail.back()='Y';MappedPage compressed;assert(!compressed.encode(tail.data(),true)&&compressed.compressed);
    std::vector<char> changed(pageSize),tiny(1);bool outsideSlice=false;
    for(size_t offset=compressed.payload;offset>0&&!outsideSlice;){--offset;compressed.bytes[offset]^=1;
        auto length=compression_decode_buffer(reinterpret_cast<uint8_t*>(changed.data()),pageSize,reinterpret_cast<const uint8_t*>(compressed.bytes),compressed.payload,nullptr,COMPRESSION_LZ4);
        if(length==pageSize&&changed[0]==tail[0]&&changed!=tail){outsideSlice=true;assert(compressed.readSlice(tiny.data(),0,1)==-EIO);}
        compressed.bytes[offset]^=1;
    }
    assert(outsideSlice&&!compressed.decode(changed.data())&&changed==tail);
    std::vector<char> zero(pageSize);MappedPage p;assert(!p.encode(zero.data(),false));assert(hex(p.strongChecksum)=="de2f256064a0af797747c2b97505dc0b9f3df0de4f489eac731c23ae9ca9cc31");
}
static void slices(){
    for(bool compressed:{false,true}){
        MemoryFS t(32*pageSize,compressed);auto b=data(pageSize,compressed);file(t,b);auto h=std::make_shared<IoTestHooks>();t.setIoHooksForTest(h);char c=0;
        assert(t.read("/f",&c,1,0)==1&&c==b[0]&&h->shaBytes==pageSize); // full logical page for a one-byte request
        for(bool digest:{false,true}){flip(t,digest,0);State state(t);assert(t.read("/f",&c,1,0)==-EIO);state.unchanged(t);flip(t,digest,0);restored(t,b);}
        if(!compressed){assert(!t.flipPayloadByteForTest("/f",0,pageSize-1));assert(t.read("/f",&c,1,0)==-EIO);assert(!t.flipPayloadByteForTest("/f",0,pageSize-1));restored(t,b);}
    }
}
static void overwrites(){
    for(bool compressed:{false,true})for(bool digest:{false,true})for(bool zero:{false,true})for(int request:{0,1,2}){
        MemoryFS t(32*pageSize,compressed);auto b=data(2*pageSize,compressed);file(t,b);auto replacement=data(2*pageSize,false);if(zero)std::fill(replacement.begin(),replacement.end(),0);
        // Last page fails after the first replacement was staged. Also cover
        // partial and exact full-page writes against the corrupt old page.
        flip(t,digest,1);State state(t);size_t count=request==0?1:request==1?pageSize:2*pageSize;size_t offset=request==2?0:pageSize;
        assert(t.write("/f",replacement.data(),count,offset)==-EIO);state.unchanged(t);flip(t,digest,1);restored(t,b);
    }
}
static void truncateTail(){for(bool compressed:{false,true})for(bool digest:{false,true}){MemoryFS t(32*pageSize,compressed);auto b=data(2*pageSize,compressed);file(t,b);flip(t,digest,1);State state(t);assert(t.truncate("/f",pageSize+1)==-EIO);state.unchanged(t);flip(t,digest,1);restored(t,b);}}
static std::string diskBytes(const fs::path& path){std::ifstream in(path,std::ios::binary);return {std::istreambuf_iterator<char>(in),{}};}
static void diskFlip(const fs::path& path){int fd=::open(path.c_str(),O_RDWR|O_NOFOLLOW);assert(fd>=0);struct stat st{};assert(!fstat(fd,&st));char c;assert(::pread(fd,&c,1,pageSize-1)==1);c^=1;assert(::pwrite(fd,&c,1,pageSize-1)==1);timespec times[2]={st.st_atimespec,st.st_mtimespec};assert(!futimens(fd,times));assert(!::close(fd));}
static void exports(const fs::path& base){
    unsigned serial=0;
    for(bool compressed:{false,true})for(bool digest:{false,true}){
        auto root=base/std::to_string(serial++);assert(fs::create_directory(root));MemoryFS t(32*pageSize,compressed);auto b=data(2*pageSize,compressed);file(t,b);auto h=std::make_shared<IoTestHooks>();t.setIoHooksForTest(h);
        // Fresh export must decode corrupt RAM, even without any previous file.
        flip(t,digest,1);State before(t);assert(t.exportTree((root/"bad-fresh").string())==-EIO);before.unchanged(t);flip(t,digest,1);
        auto prior=root/"prior";assert(!t.exportTree(prior.string(),true));auto g=t.lastExportStats().generation;
        // Positive no-op proves this is a current saved checkpoint, not an early
        // metadata mismatch. Every no-op must verify memory AND read disk.
        h->shaBytes=0;assert(!t.exportTree((root/"unused").string(),true,prior.string(),g));auto stats=t.lastExportStats();assert(stats.reused&&stats.decoded==2*pageSize&&stats.readback==b.size()&&h->shaBytes==4*pageSize&&!fs::exists(root/"unused"));
        flip(t,digest,1);assert(t.exportTree((root/"bad-noop").string(),true,prior.string(),g)==-EIO);assert(!fs::exists(root/"bad-noop"));flip(t,digest,1);
        diskFlip(prior/"f");assert(t.exportTree((root/"disk-noop").string(),true,prior.string(),g)==-EIO);assert(!fs::exists(root/"disk-noop"));diskFlip(prior/"f");
        // Metadata-only current change keeps dataGeneration and saved G eligible
        // for candidate verification; the positive run confirms actual cloning.
        t.freeze(false);assert(!t.chmod("/f",0640));auto candidate=root/"candidate";assert(!t.exportTree(candidate.string(),true,prior.string(),g));stats=t.lastExportStats();assert(stats.clonedFiles==1&&stats.written==0&&stats.decoded==2*pageSize);g=stats.generation;
        assert(diskBytes(candidate/"f")==std::string(b.begin(),b.end()));t.freeze(false);assert(!t.chmod("/f",0600));t.freeze(true);
        flip(t,digest,1);h->shaBytes=0;assert(t.exportTree((root/"bad-candidate").string(),true,candidate.string(),g)==-EIO);assert(h->shaBytes>=pageSize);flip(t,digest,1);
        diskFlip(candidate/"f");h->shaBytes=0;assert(t.exportTree((root/"disk-candidate").string(),true,candidate.string(),g)==-EIO);assert(h->shaBytes>=3*pageSize);diskFlip(candidate/"f");
        assert(!t.exportTree((root/"restored-candidate").string(),true,candidate.string(),g));assert(t.lastExportStats().clonedFiles==1&&t.accountingOracleForTest());
    }
}
static void digestRace(){
    for(bool compressed:{false,true})for(bool metadataChange:{false,true}){
        MemoryFS t(32*pageSize,compressed);auto b=data(pageSize,compressed);file(t,b);auto h=std::make_shared<IoTestHooks>();t.setIoHooksForTest(h);State before(t);h->arm(IoTestHooks::Point::writeStaged);
#ifdef RAMNEST_DEBUG_PROFILING
        profile::active.store(std::make_shared<profile::Window>("old-window","write","fskit",compressed,0));
#endif
        auto job=std::async(std::launch::async,[&]{return t.write("/f","NEW",3,0);});bool paused=h->wait(1);
        // Descriptor fault leaves generation unchanged: samePage must compare
        // the authoritative digest, then retry and detect the corrupt old data.
        int mutation=t.flipDigestByteForTest("/f",0,7);
        int metadata=metadataChange?t.chmod("/f",0640):0;
        State expected(t);expected.metrics=before.metrics; // excludes staged backing

#ifdef RAMNEST_DEBUG_PROFILING
        profile::active.store(std::make_shared<profile::Window>("fixture","write","fskit",compressed,0));
#endif
        h->release(UINT64_MAX);int result=job.get();
#ifdef RAMNEST_DEBUG_PROFILING
        profile::active.store(nullptr);
#endif
        assert(paused&&!mutation&&!metadata&&result==-EIO&&h->retries==1);expected.unchanged(t);assert(!t.flipDigestByteForTest("/f",0,7));restored(t,b);
    }
}
int main(int argc,char** argv){assert(argc==3);std::string test=argv[1];
    fs::path base=fs::path(argv[2])/("checksum-"+test+"-"+std::to_string(getpid()));fs::create_directories(base);
    if(test=="pages")pages();else if(test=="slices")slices();else if(test=="overwrites")overwrites();else if(test=="truncate")truncateTail();else if(test=="exports")exports(base);else if(test=="digest-race")digestRace();else assert(false);
    fs::remove_all(base);std::cout<<"PASS checksum "<<test<<std::endl;
}
