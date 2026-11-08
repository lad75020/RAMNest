#pragma once
#include <array>
#ifdef RAMNEST_IO_TESTING
#include <condition_variable>
#include <chrono>
#include <thread>
#endif
#include <atomic>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>
#include <sys/stat.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <stdexcept>
#include <unistd.h>
#include <sys/statvfs.h>
#include <sys/xattr.h>
namespace ramnest {
enum class FileVerification { sha256, sizeAndModTime };
constexpr uint64_t pageSize = 65536; // logical compression block, four arm64 VM pages
constexpr uint64_t vmPageSize = 16384;
// A quota only: metadata and payload backing still grow with actual content.
constexpr uint64_t metadataBudget(uint64_t capacity){return capacity/4<65536?65536:capacity/4;}
constexpr bool metadataFits(uint64_t capacity,uint64_t used,uint64_t extra){
    auto maximum=metadataBudget(capacity);return extra<=maximum&&used<=maximum-extra;
}
#ifdef RAMNEST_IO_TESTING
// Dedicated fixture ABI only; neither production library nor helper defines it.
struct IoTestHooks {
    enum class Point { readCaptured, writeStaged, exportCaptured };
    std::mutex mutex; std::condition_variable cv;
    Point point=Point::readCaptured; unsigned remaining=0; uint64_t hits=0,released=0;
    std::thread::id owner{}; std::atomic<int> allocationFailure{-1};
    std::atomic<uint64_t> copied{0},zeroed{0},shaBytes{0},retries{0},fallbacks{0},mappedPeak{0};
    void arm(Point p,unsigned count=1){std::lock_guard g(mutex);point=p;remaining=count;owner={};}
    bool wait(uint64_t n){std::unique_lock g(mutex);return cv.wait_for(g,std::chrono::seconds(5),[&]{return hits>=n;});}
    void release(uint64_t n){std::lock_guard g(mutex);released=n;cv.notify_all();}
    void pause(Point p){std::unique_lock g(mutex);if(p!=point||!remaining||(owner!=std::thread::id{}&&owner!=std::this_thread::get_id()))return;
        owner=std::this_thread::get_id();remaining--;auto ticket=++hits;cv.notify_all();
        cv.wait_for(g,std::chrono::seconds(5),[&]{return released>=ticket;});}
    void failAfter(int n){std::lock_guard g(mutex);allocationFailure=n;}
    bool fail(){if(allocationFailure.load(std::memory_order_relaxed)<0)return false;std::lock_guard g(mutex);if(allocationFailure<0)return false;if(!allocationFailure)return true;allocationFailure--;return false;}
};
#endif
struct Accounting;
struct DirectorySnapshot {
    std::vector<std::string> names;
    std::shared_ptr<Accounting> accounting;uint64_t bytes=0;
    ~DirectorySnapshot();
};
struct Backing {
    char* bytes=nullptr;size_t mapped=0,payload=0;
    std::shared_ptr<Accounting> accounting;
    ~Backing();
};
struct MappedPage {
private:
    // Bound when a backing is created; descriptor copies/captures carry it.
    // No runtime policy setter: replacing a page replaces the whole descriptor.
    FileVerification fileVerification;
public:
    char* bytes=nullptr;
    size_t mapped=0, payload=0;
    bool compressed=false;
    std::array<unsigned char,32> strongChecksum{};
    explicit MappedPage(FileVerification policy=FileVerification::sha256):fileVerification(policy){}
    FileVerification verificationPolicy()const {return fileVerification;}
    std::shared_ptr<Backing> storage;
    MappedPage(const MappedPage&)=default; MappedPage& operator=(const MappedPage&)=default;
    MappedPage(MappedPage&&)=default; MappedPage& operator=(MappedPage&&)=default;
    static void failAllocationForTest(int);
    int encode(const char*,bool,std::shared_ptr<Accounting> = {});
    int decode(char*) const;
    int verifyRaw() const;
    int readSlice(char*,size_t,size_t) const;
};
struct Attributes {uint32_t valid=0;mode_t mode=0;uid_t uid=0;gid_t gid=0;int64_t size=0;timespec access{},modify{},birth{},change{},backup{};uint32_t flags=0;};
struct Metrics { uint64_t logical=0, content=0, payload=0, mapped=0; };
struct Accounting {
    mutable std::recursive_mutex mutex;
    std::vector<std::weak_ptr<Backing>> backings;
    uint64_t backingLive=0,directoryLive=0,mappedLimit=UINT64_MAX,captureBytes=0;
    std::atomic<uint64_t> directoryBytes{0};
    std::vector<std::weak_ptr<DirectorySnapshot>> directories;
    std::atomic<uint64_t> logical{0},content{0},payload{0},mapped{0},metadata{0},live{0};
};
struct Node {
    uint64_t dataGeneration=1,metadataGeneration=1,shapeEpoch=1;
    uint64_t ino; mode_t mode; uid_t uid; gid_t gid; uint64_t links=1; int64_t size=0;
    timespec atime{}, mtime{}, ctime{}, birth{}, backup{}; uint32_t flags=0;
    std::map<uint64_t, MappedPage> pages;
    std::map<std::string,std::shared_ptr<Node>> children;
    std::map<std::string,std::string> attrs;
    std::string target;
    std::shared_ptr<Accounting> accounting;
    Metrics charged{};
    uint64_t chargedMetadata=0,attributeBytes=0,namespaceBytes=0,subdirectories=0,payloadBytes=0,mappedBytes=0;
    void account();
    ~Node();
};
class MemoryFS {
    mutable std::recursive_mutex mutex;
    std::mutex exportMutex;
    uint64_t generation=1,checkpointGeneration=0,captureLimitForTest=0;
    struct Checkpoint {uint64_t data,metadata;std::string path;std::map<std::string,std::string> generatedAttributes={};};
    std::unordered_map<uint64_t,Checkpoint> checkpoint;
    void changed(const std::shared_ptr<Node>&n,bool data=false){n->metadataGeneration++;if(data)n->dataGeneration++;generation++;}
    std::shared_ptr<Accounting> accounting=std::make_shared<Accounting>();
    std::shared_ptr<Node> root;
    std::unordered_map<uint64_t,std::shared_ptr<Node>> handles;
    std::vector<std::weak_ptr<Node>> nodes;
    std::unordered_map<uint64_t,int> handleFlags;
    std::unordered_map<uint64_t,std::shared_ptr<const std::vector<std::string>>> dirEntries;
    uint64_t nextIno=1, nextHandle=1;
    std::atomic<uint64_t> capacity;
    int openAllocationFailure=-1;
    uint64_t freezeEpoch=1,namespaceEpoch=1;
    void setFrozenUnlocked(bool value){frozen=value;++freezeEpoch;}
    uint64_t captureLimitUnlocked()const;
    struct IoCapture;
    int captureWriteUnlocked(const std::string&,size_t,int64_t,uint64_t,IoCapture&);
    void capturePagesUnlocked(IoCapture&);
    int stageWrite(const IoCapture&,const char*,size_t,std::map<uint64_t,MappedPage>&);
    int commitWriteUnlocked(const std::shared_ptr<Node>&,int64_t,size_t,std::map<uint64_t,MappedPage>&);
    int writeSerializedUnlocked(const std::string&,const char*,size_t,int64_t,uint64_t=0);
    bool frozen=false;
    bool compression=true;
    const FileVerification fileVerification;
    std::shared_ptr<Node> make(mode_t mode);
    std::shared_ptr<Node> lookup(const std::string& path) const;
    std::pair<std::shared_ptr<Node>,std::string> parent(const std::string& path) const;
    std::shared_ptr<Node> file(const std::string& path,uint64_t h) const;
    uint64_t usedUnlocked() const;
    uint64_t metadataUnlocked() const;
    bool metadataRoom(uint64_t) const;
    using ExportWriter=ssize_t(*)(int,const void*,size_t,off_t);
    ExportWriter exportWriter=::pwrite;
    using ExtentSeeker=off_t(*)(int,off_t,int);
    ExtentSeeker extentSeeker=::lseek;
    using ImportReader=ssize_t(*)(int,void*,size_t);
    ImportReader importReader=::read;
    using AttributeLister=ssize_t(*)(const char*,char*,size_t,int);
    using AttributeReader=ssize_t(*)(const char*,const char*,void*,size_t,uint32_t,int);
    AttributeLister importAttributeLister=::listxattr;
    AttributeReader importAttributeReader=::getxattr;
    // Completed import/export work only. Observers must never take the tree mutex.
    static_assert(std::atomic<uint64_t>::is_always_lock_free);
    std::atomic<uint64_t> progress{0};
    void advanced(){progress.fetch_add(1,std::memory_order_relaxed);}
#ifdef RAMNEST_IO_TESTING
    std::shared_ptr<IoTestHooks> ioHooks;
#endif
public:
#ifdef RAMNEST_IO_TESTING
    void setIoHooksForTest(std::shared_ptr<IoTestHooks> hooks){std::lock_guard g(mutex);ioHooks=std::move(hooks);}
#endif
    explicit MemoryFS(uint64_t bytes,bool compressionEnabled=true,FileVerification verification=FileVerification::sha256);
    FileVerification verificationPolicy()const {return fileVerification;}
    Metrics metrics() const;
    bool accountingOracleForTest() const;
    size_t registrySizeForTest() const {std::lock_guard g(mutex);return nodes.size();}
    void failOpenAllocationForTest(int stage){openAllocationFailure=stage;}
    void setExportWriterForTest(ExportWriter writer){exportWriter=writer;}
    void setExtentSeekerForTest(ExtentSeeker seeker){extentSeeker=seeker;}
    void setImportReaderForTest(ImportReader reader){importReader=reader;}
    void setImportAttributesForTest(AttributeLister list,AttributeReader read){importAttributeLister=list;importAttributeReader=read;}
    uint64_t operationProgress() const {return progress.load(std::memory_order_relaxed);}
#ifdef RAMNEST_IO_TESTING
    // Reversible XOR faults for owned fixtures only, with no generation change.
    // Call only while no worker can access the affected backing bytes.
    int flipPayloadByteForTest(const std::string&,uint64_t,size_t=0);
    int flipDigestByteForTest(const std::string&,uint64_t,size_t=0);
#endif
    int stat(const std::string&,struct stat*,uint64_t h=0);
    int entries(const std::string&,std::vector<std::string>&);
    int create(const std::string&, mode_t, uint64_t* handle=nullptr, int flags=O_RDWR);
    int symlink(const std::string& target,const std::string& path);
    int readlink(const std::string&,std::string&);
    int link(const std::string&,const std::string&);
    int rename(const std::string&,const std::string&);
    int remove(const std::string&,bool directory=false);
    int open(const std::string&,uint64_t&,int flags=O_RDWR);
    int openDirectory(const std::string&,uint64_t&);
    int directoryEntries(uint64_t,std::vector<std::string>&);
    int directorySnapshot(uint64_t,std::shared_ptr<const std::vector<std::string>>&);
    int checkHandle(uint64_t,bool directory=false);
    int access(const std::string&,int);
    int flags(const std::string&,uint32_t);
    int extraTimes(const std::string&,timespec*,timespec*,timespec*,bool set);
    int exchange(const std::string&,const std::string&);
    int renameExclusive(const std::string&,const std::string&);
    int close(uint64_t);
    int read(const std::string&,char*,size_t,int64_t,uint64_t=0);
    int write(const std::string&,const char*,size_t,int64_t,uint64_t=0);
    int truncate(const std::string&,int64_t,uint64_t=0);
    int setattr(const std::string&,const Attributes&,uint64_t=0);
    int chmod(const std::string&,mode_t);
    int chown(const std::string&,uid_t,gid_t);
    int times(const std::string&,const timespec[2]);
    int setxattr(const std::string&,const std::string&,const std::string&,int);
    int getxattr(const std::string&,const std::string&,std::string&);
    int setxattrAt(const std::string&,const std::string&,const std::string&,int,uint32_t);
    int getxattrAt(const std::string&,const std::string&,std::string&,uint32_t);
    int listxattr(const std::string&,std::string&);
    int removexattr(const std::string&,const std::string&);
    void statfs(struct statvfs*);
    uint64_t used() const;
    uint64_t limit() const;
    int resize(uint64_t);
    void freeze(bool);
    int importTree(const std::string&,const std::string& modeDigest="");
    int populate(const std::string&,const std::string& modeDigest="");
    bool isFrozen() const;
    std::pair<uint64_t,bool> checkpointState()const {std::lock_guard g(mutex);return {generation,frozen};}
    struct ExportStats {uint64_t generation=0,written=0,readback=0,decoded=0,clonedFiles=0,files=0,fileVerificationSHA256Bytes=0;bool reused=false;std::string modeMapDigest;};
    ExportStats lastExportStats()const {std::lock_guard g(mutex);return exportStats;}
    void setCaptureLimitForTest(uint64_t limit){std::lock_guard g(mutex);captureLimitForTest=limit;}
    void setBackingLimitForTest(uint64_t limit){std::lock_guard g(accounting->mutex);accounting->mappedLimit=limit;}
    int exportTree(const std::string&,bool keepFrozen=false,const std::string& previous="",uint64_t previousGeneration=0,bool privateStorage=false);
private:
    ExportStats exportStats;

};
}
