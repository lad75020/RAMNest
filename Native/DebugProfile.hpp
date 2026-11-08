#pragma once
// No profiler declarations, storage, strings or branches in non-Debug products.
#ifdef RAMNEST_DEBUG_PROFILING
#include <array>
#include <atomic>
#include <chrono>
#include <memory>
#include <mutex>
#include <string>
#include <uuid/uuid.h>
namespace ramnest::profile {
enum class Metric {callback_read,callback_write,native_read,native_write,tree_wait,tree_hold,lz4_encode,lz4_decode,sha256,mmap,memcpy,account,compressed_block,raw_block,count};
inline constexpr std::array names={"callback_read","callback_write","native_read","native_write","tree_wait","tree_hold","lz4_encode","lz4_decode","sha256","mmap","memcpy","account","compressed_block","raw_block"};
inline uint64_t now(){return uint64_t(std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now().time_since_epoch()).count());}
struct Counter {std::atomic<uint64_t> calls{0},ns{0},requested{0},returned{0},errors{0};std::array<std::atomic<uint64_t>,5> histogram{};};
struct Window {
    std::string run,phase,backend;bool compression;int periodic;
    uint64_t start=now(),deadline=start+300000000000ULL;
    std::atomic<uint64_t> inFlight{0};std::array<Counter,size_t(Metric::count)> counters;
    Window(std::string r,std::string p,std::string b,bool c,int i):run(std::move(r)),phase(std::move(p)),backend(std::move(b)),compression(c),periodic(i){}
};
// Apple's libc++ does not yet provide atomic<shared_ptr<T>>. The shared_ptr
// atomic free functions retain the same lifetime/admission guarantees.
struct AtomicWindow {
    std::shared_ptr<Window> value;
    std::shared_ptr<Window> load(std::memory_order order=std::memory_order_seq_cst) const {
        return std::atomic_load_explicit(&value,order);
    }
    void store(std::shared_ptr<Window> next,std::memory_order order=std::memory_order_seq_cst) {
        std::atomic_store_explicit(&value,std::move(next),order);
    }
};
inline AtomicWindow active;
inline std::shared_ptr<Window> retired;
inline std::mutex controlMutex;
// Separate from timed windows: preparation and verification also own payloads.
// Never expire this safety reservation into permission to persist test data.
inline std::string fixtureRun;
inline bool periodicInFlight=false;
inline bool claimPeriodic(const std::atomic<int>& period){
    std::lock_guard lock(controlMutex);
    if(!fixtureRun.empty()||periodicInFlight||period.load()<=0)return false;
    periodicInFlight=true;return true;
}
inline void finishPeriodic(){std::lock_guard lock(controlMutex);periodicInFlight=false;}
// Nested scopes inherit the root epoch; an end/new begin never moves old work
// into a fresh window. A retired in-flight window prevents another admission.
inline thread_local std::shared_ptr<Window> threadWindow;
inline thread_local unsigned depth=0;
class Scope {
    std::shared_ptr<Window> window;Metric metric;uint64_t started=0;bool entered=false;
public:
    Scope(Metric m,uint64_t requested=0):metric(m){
        if(depth){window=threadWindow;}
        else {
            window=active.load(std::memory_order_acquire);
            if(window){
                window->inFlight.fetch_add(1);
                if(active.load()!=window||now()>=window->deadline){window->inFlight.fetch_sub(1);window.reset();}
            }
            threadWindow=window;
        }
        depth++;entered=true;
        if(window){started=now();auto& c=window->counters[size_t(metric)];c.requested.fetch_add(requested,std::memory_order_relaxed);
            if(requested)c.histogram[requested<=4096?0:requested<=65536?1:requested<=262144?2:requested<=1048576?3:4].fetch_add(1,std::memory_order_relaxed);}
    }
    Scope(const Scope&)=delete;
    void result(int64_t n){if(window){auto& c=window->counters[size_t(metric)];if(n<0)c.errors.fetch_add(1,std::memory_order_relaxed);else c.returned.fetch_add(uint64_t(n),std::memory_order_relaxed);}}
    ~Scope(){finish();}
    void finish(){if(!entered)return;entered=false;
        if(window){auto& c=window->counters[size_t(metric)];c.ns.fetch_add(now()-started,std::memory_order_relaxed);c.calls.fetch_add(1,std::memory_order_relaxed);}
        if(--depth==0){if(window)window->inFlight.fetch_sub(1);threadWindow.reset();}
    }
};
inline bool validUUID(const std::string& s){uuid_t u;return s.size()==36&&uuid_parse(s.c_str(),u)==0;}
inline std::string render(const Window& w,bool stopped){
    std::string out="OK\t{\"version\":2,\"integrityAlgorithm\":\"sha256\",\"run\":\""+w.run+"\",\"phase\":\""+w.phase+"\",\"backend\":\""+w.backend+"\",\"compression\":"+(w.compression?"true":"false")+",\"periodicMinutes\":"+std::to_string(w.periodic)+",\"debugBuild\":true,\"clock\":\"steady_clock_ns\",\"elapsedNS\":"+std::to_string(now()-w.start)+",\"stopped\":"+(stopped?"true":"false")+",\"expired\":"+(now()>=w.deadline?"true":"false")+",\"inFlight\":"+std::to_string(w.inFlight.load())+",\"metrics\":[";
    for(size_t i=0;i<names.size();i++){if(i)out+=",";auto& c=w.counters[i];out+="{\"id\":\""+std::string(names[i])+"\",\"calls\":"+std::to_string(c.calls.load())+",\"ns\":"+std::to_string(c.ns.load())+",\"requested\":"+std::to_string(c.requested.load())+",\"returned\":"+std::to_string(c.returned.load())+",\"errors\":"+std::to_string(c.errors.load())+",\"histogram\":[";
        for(size_t j=0;j<5;j++){if(j)out+=",";out+=std::to_string(c.histogram[j].load());}out+="]}";}
    return out+"]}";
}
inline std::string command(const std::string& verb,const std::string& arg,const std::string& backend,bool compression,const std::atomic<int>& runningPeriod,bool ready){
    auto sep=arg.find('\t');if(sep==std::string::npos)return "ERR\t22";
    auto run=arg.substr(0,sep),phase=arg.substr(sep+1);
    if(!validUUID(run)||(phase!="write"&&phase!="read"))return "ERR\t22";
    std::lock_guard lock(controlMutex);auto w=active.load();const int periodic=runningPeriod.load();
    if(w&&now()>=w->deadline){active.store(nullptr);retired=w;w.reset();}
    if(verb=="profile-release"){
        if(fixtureRun!=run)return "ERR\t22";
        if(w)return "ERR\t16";
        fixtureRun.clear();return "OK\t"+run;
    }
    if(verb=="profile-begin"){
        if(w||(retired&&retired->inFlight.load())||!ready||periodic!=0||periodicInFlight||(!fixtureRun.empty()&&fixtureRun!=run))return "ERR\t16";
        auto next=std::make_shared<Window>(run,phase,backend,compression,periodic);fixtureRun=run;retired.reset();active.store(next);return render(*next,false);
    }
    if(!w||w->run!=run||w->phase!=phase)return "ERR\t22";
    if(verb=="profile-snapshot")return render(*w,false);
    if(verb!="profile-end")return "ERR\t22";
    active.store(nullptr);retired=w;return render(*w,true);
}
}
#define RN_PROFILE_SCOPE(name,metric) ramnest::profile::Scope name(ramnest::profile::Metric::metric)
#define RN_PROFILE_BYTES(name,metric,bytes) ramnest::profile::Scope name(ramnest::profile::Metric::metric,bytes)
#define RN_PROFILE_RESULT(name,value) name.result(value)
#define RN_PROFILE_RETURN(name,value) do { auto profileReturnValue=(value); name.result(profileReturnValue); return profileReturnValue; } while(false)
#else
#define RN_PROFILE_SCOPE(name,metric)
#define RN_PROFILE_BYTES(name,metric,bytes)
#define RN_PROFILE_RESULT(name,value)
#define RN_PROFILE_RETURN(name,value) return (value)
#endif
