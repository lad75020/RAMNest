#include "MemoryFS.hpp"
#include "DebugProfile.hpp"
#include <cassert>
#include <algorithm>
#include <future>
#include <iostream>
#include <filesystem>
#include <fstream>
#include <cstring>
#include <CommonCrypto/CommonDigest.h>
using namespace ramnest;
static constexpr uint64_t MiB=1024*1024;
static std::vector<char> bytes(size_t size,int seed=17,bool compress=false){std::vector<char> b(size);uint32_t x=seed;for(auto& c:b){x=x*1664525U+1013904223U;c=compress?char(seed):char(x>>24);}return b;}
static void file(MemoryFS& t,const std::string& p,const std::vector<char>& b){assert(t.create(p,S_IFREG|0600)==0);assert(t.write(p,b.data(),b.size(),0)==int(b.size()));}
static std::vector<char> read(MemoryFS& t,const std::string& p,size_t size,uint64_t h=0){std::vector<char> b(size);assert(t.read(p,b.data(),b.size(),0,h)==int(size));return b;}
static bool sameTime(timespec a,timespec b){return a.tv_sec==b.tv_sec&&a.tv_nsec==b.tv_nsec;}
static void exactState(MemoryFS& t,const Metrics& m,const struct stat& st,uint64_t gen){auto after=t.metrics();struct stat now{};assert(!t.stat("/f",&now));assert(after.logical==m.logical&&after.content==m.content&&after.payload==m.payload&&after.mapped==m.mapped);assert(now.st_size==st.st_size&&sameTime(now.st_atimespec,st.st_atimespec)&&sameTime(now.st_mtimespec,st.st_mtimespec)&&sameTime(now.st_ctimespec,st.st_ctimespec));assert(t.checkpointState().first==gen);assert(t.accountingOracleForTest());}
// Even a failed assertion during a paused mutation releases and joins the
// owner first. This keeps regressions from stranding a future destructor.
struct PausedWork;
static thread_local PausedWork* pausedWork=nullptr;
struct PausedWork {
    IoTestHooks& hooks;std::future<int>& work;
    PausedWork(IoTestHooks& h,std::future<int>& w):hooks(h),work(w){assert(!pausedWork);pausedWork=this;}
    ~PausedWork(){pausedWork=nullptr;}
    void finish(){hooks.release(UINT64_MAX);if(work.valid())work.wait();}
};
#undef assert
#define assert(expression) do {if(!(expression)){if(pausedWork)pausedWork->finish();std::cerr<<"Assertion failed at "<<__FILE__<<":"<<__LINE__<<": "<<#expression<<std::endl;std::abort();}}while(false)
int main(int argc,char** argv){assert(argc==3);std::string test=argv[1];MemoryFS tree(32*MiB,false);auto data=bytes(pageSize);file(tree,"/f",data);file(tree,"/other",data);auto hooks=std::make_shared<IoTestHooks>();tree.setIoHooksForTest(hooks);
 if(test=="copy"){
  char c;assert(tree.read("/f",&c,1,0)==1&&c==data[0]);auto copied=hooks->copied.load();std::cout<<"raw_slice_copied="<<copied<<" expected=1\n";assert(copied==1);
  hooks->copied=0;hooks->zeroed=0;assert(tree.write("/f",data.data(),data.size(),0)==int(data.size()));assert(hooks->copied==pageSize&&hooks->zeroed==0); // encode only
  hooks->copied=0;assert(tree.create("/new",S_IFREG|0600)==0);assert(tree.write("/new",data.data(),data.size(),0)==int(pageSize));assert(hooks->copied==pageSize&&hooks->zeroed==0);
 }else if(test=="sha256"){
  for(int seed=0;seed<100;seed++){auto b=bytes(pageSize,seed);if(seed<3)std::fill(b.begin(),b.end(),char(seed==0?0:seed==1?255:128));std::array<unsigned char,32> expected{};CC_SHA256(b.data(),CC_LONG(b.size()),expected.data());MappedPage p;assert(!p.encode(b.data(),false)&&p.strongChecksum==expected);std::vector<char> out(pageSize);assert(!p.decode(out.data())&&out==b);}
 }else if(test=="read-progress"||test=="write-progress"){
  bool isRead=test=="read-progress";hooks->arm(isRead?IoTestHooks::Point::readCaptured:IoTestHooks::Point::writeStaged);std::vector<char> out(pageSize);auto work=std::async(std::launch::async,[&]{return isRead?tree.read("/f",out.data(),out.size(),0):tree.write("/f",data.data(),data.size(),0);});PausedWork cleanup(*hooks,work);bool entered=hooks->wait(1);
  auto other=std::async(std::launch::async,[&]{struct stat st;char c;return tree.stat("/other",&st)==0&&tree.read("/other",&c,1,0)==1&&tree.write("/other","z",1,0)==1;});bool progressed=other.wait_for(std::chrono::milliseconds(200))==std::future_status::ready;hooks->release(1);auto result=work.get();bool okay=other.get();std::cout<<test<<" entered="<<entered<<" unrelated_progress="<<progressed<<std::endl;assert(entered&&result==int(pageSize)&&okay&&progressed);
 }else if(test=="integrity"){
  for(bool compressed:{false,true})for(bool zero:{false,true})for(bool partial:{false,true}){MemoryFS t(32*MiB,compressed);auto original=bytes(2*pageSize,23,compressed);file(t,"/f",original);assert(!t.flipPayloadByteForTest("/f",1));auto m=t.metrics();struct stat st{};assert(!t.stat("/f",&st));auto gen=t.checkpointState().first;auto replacement=bytes(2*pageSize,19);if(zero)std::fill(replacement.begin(),replacement.end(),0);assert(t.write("/f",replacement.data(),replacement.size()-(partial?1:0),0)==-EIO);exactState(t,m,st,gen);std::vector<char> out(2*pageSize,'q');assert(t.read("/f",out.data(),out.size(),0)==-EIO);assert(std::equal(out.begin(),out.begin()+pageSize,original.begin()));assert(std::all_of(out.begin()+pageSize,out.end(),[](char c){return c==0;}));exactState(t,m,st,gen);assert(!t.flipPayloadByteForTest("/f",1));assert(read(t,"/f",original.size())==original);}
  // Actual backing and authoritative digest faults after successful reads
  // must both be detected; restoring each fault restores the original bytes.
  auto b=bytes(pageSize);MappedPage p;assert(!p.encode(b.data(),false));std::vector<char> out(pageSize);assert(!p.readSlice(out.data(),0,pageSize));p.bytes[pageSize-1]^=1;assert(p.readSlice(out.data(),0,1)==-EIO);p.bytes[pageSize-1]^=1;assert(!p.decode(out.data())&&out==b);p.strongChecksum[0]^=1;assert(p.readSlice(out.data(),0,1)==-EIO);p.strongChecksum[0]^=1;assert(!p.decode(out.data())&&out==b);
 }else if(test=="read-matrix"){
  for(bool compressed:{false,true}){MemoryFS t(32*MiB,compressed);auto b=bytes(4*MiB+pageSize,44,compressed);assert(!t.create("/f",S_IFREG|0600));for(size_t off=0;off<b.size();off+=MiB){auto n=std::min(size_t(MiB),b.size()-off);assert(t.write("/f",b.data()+off,n,off)==int(n));}
   for(size_t count:{size_t(0),size_t(1),size_t(32768),size_t(65536),size_t(4*MiB)}){std::vector<char> out(count+8,'q');assert(t.read("/f",out.data(),count,1)==int(count));assert(std::equal(out.begin(),out.begin()+count,b.begin()+1));assert(out[count]=='q');}
   char out[9];memset(out,'q',9);assert(t.read("/f",out,9,b.size()-3)==3);assert(out[3]=='q');assert(t.read("/f",out,9,b.size())==0&&out[3]=='q');assert(t.read("/f",out,9,-1)==-EINVAL);assert(t.read("/f",out,4*MiB+1,0)==-EINVAL);assert(!t.truncate("/f",8*MiB));std::vector<char> hole(100,'x');assert(t.read("/f",hole.data(),100,6*MiB)==100&&std::all_of(hole.begin(),hole.end(),[](char c){return !c;}));}
 }else if(test.starts_with("read-lifetime-")){
  auto old=bytes(2*pageSize);assert(tree.write("/f",old.data(),old.size(),0)==int(old.size()));uint64_t h;assert(!tree.open("/f",h));auto before=tree.used();hooks->arm(IoTestHooks::Point::readCaptured);std::vector<char> out(3*pageSize,'q');auto job=std::async(std::launch::async,[&]{return tree.read("/f",out.data(),out.size(),0,h);});PausedWork cleanup(*hooks,job);bool paused=hooks->wait(1);auto action=test.substr(14);int mutation=0;
  if(action=="truncate"){mutation=tree.truncate("/f",0);mutation|=tree.truncate("/f",3*pageSize);auto b=bytes(pageSize,88);mutation|=tree.write("/f",b.data(),b.size(),pageSize)==int(pageSize)?0:1;}
  else if(action=="replace"){mutation=tree.remove("/f");mutation|=tree.create("/f",S_IFREG|0600);mutation|=tree.write("/f","new",3,0)==3?0:1;}
  else {mutation=tree.remove("/f");mutation|=tree.close(h);assert(tree.used()==before-2*pageSize);assert(tree.metrics().mapped>=3*pageSize);}
  hooks->release(1);auto result=job.get();assert(paused&&!mutation&&result==int(old.size()));assert(std::equal(old.begin(),old.end(),out.begin())&&out[old.size()]=='q');if(action!="unlink")assert(!tree.close(h));
 }else if(test=="halves"||test=="overlap"||test=="disjoint"||test=="hardlink"){
  assert(!tree.link("/f","/alias"));auto a=bytes(pageSize,33),b=bytes(pageSize,55);size_t count=test=="overlap"?pageSize:pageSize/2;int64_t second=test=="disjoint"?pageSize:test=="overlap"?0:pageSize/2;
  hooks->arm(IoTestHooks::Point::writeStaged);auto job=std::async(std::launch::async,[&]{return tree.write("/f",a.data(),count,0);});PausedWork cleanup(*hooks,job);bool paused=hooks->wait(1);int result=tree.write(test=="hardlink"?"/alias":"/f",b.data(),count,second);hooks->release(1);int first=job.get();assert(paused&&first==int(count)&&result==int(count));auto out=read(tree,"/f",second+count>pageSize?second+count:pageSize);assert(std::equal(a.begin(),a.begin()+count,out.begin()));if(test!="overlap")assert(std::equal(b.begin(),b.begin()+count,out.begin()+second));assert(hooks->retries==(test=="disjoint"?0:1));
 }else if(test=="append"){
  uint64_t a,b;assert(!tree.open("/f",a,O_WRONLY|O_APPEND)&&!tree.open("/f",b,O_WRONLY|O_APPEND));hooks->arm(IoTestHooks::Point::writeStaged);auto job=std::async(std::launch::async,[&]{return tree.write("", "AAAA",4,0,a);});PausedWork cleanup(*hooks,job);bool paused=hooks->wait(1);int second=tree.write("","BBBB",4,0,b);hooks->release(1);assert(job.get()==4&&second==4&&paused);auto out=read(tree,"/f",pageSize+8);assert(std::string(out.end()-8,out.end())=="BBBBAAAA");assert(!tree.close(a)&&!tree.close(b));
 }else if(test=="fallback"){
  hooks->arm(IoTestHooks::Point::writeStaged,2);auto job=std::async(std::launch::async,[&]{return tree.write("/f","A",1,0);});PausedWork cleanup(*hooks,job);bool first=hooks->wait(1);assert(tree.write("/f","B",1,0)==1);hooks->release(1);bool second=hooks->wait(2);assert(tree.write("/f","C",1,0)==1);hooks->release(2);int result=job.get();assert(first&&second&&result==1&&hooks->retries==2&&hooks->fallbacks==1);assert(read(tree,"/f",1)[0]=='A');
 }else if(test.starts_with("write-race-")){
  auto action=test.substr(11);uint64_t h=0;if(action=="stale"||action=="unlinked"||action=="handle-rename")assert(!tree.open("/f",h));hooks->arm(IoTestHooks::Point::writeStaged);auto job=std::async(std::launch::async,[&]{return tree.write("/f","NEW",3,0,h);});PausedWork cleanup(*hooks,job);bool paused=hooks->wait(1);int expected=3;
  if(action=="freeze"){tree.freeze(true);tree.freeze(false);expected=-EBUSY;}
  else if(action=="stale"){assert(!tree.close(h));expected=-EBADF;}
  else if(action=="unlinked"){assert(!tree.remove("/f"));}
  else if(action=="handle-rename"){assert(!tree.rename("/f","/renamed"));}
  else if(action=="aba"){assert(!tree.rename("/f","/saved")&&!tree.rename("/saved","/f"));}
  else if(action=="exchange"){assert(!tree.exchange("/f","/other"));}
  else if(action=="replace"){assert(!tree.remove("/f")&&!tree.create("/f",S_IFREG|0600));}
  else if(action=="truncate"){assert(!tree.truncate("/f",0));}
  else if(action=="otrunc"){uint64_t handle;assert(!tree.open("/f",handle,O_RDWR|O_TRUNC)&&!tree.close(handle));}
  else if(action=="setattr"){Attributes a;a.valid=8|1|0x80000000U;a.size=1;a.mode=0640;a.flags=UF_HIDDEN;assert(!tree.setattr("/f",a));}
  else if(action=="atime"){char c;assert(tree.read("/f",&c,1,0)==1);}
  else assert(false);
  hooks->release(1);int result=job.get();assert(paused&&result==expected);
  if(result==3){auto out=read(tree,action=="handle-rename"?"/renamed":"/f",3,h);assert(std::string(out.begin(),out.end())=="NEW");}
  if(action=="truncate"||action=="otrunc"||action=="setattr"){struct stat st;assert(!tree.stat("/f",&st)&&st.st_size==3);}
  if(action=="atime"||action=="unlinked"||action=="handle-rename")assert(hooks->retries==0);
  if(h&&action!="stale")assert(!tree.close(h));
 }else if(test=="read-freeze"){
  struct stat before{},after{};assert(!tree.stat("/f",&before));hooks->arm(IoTestHooks::Point::readCaptured);std::vector<char> out(pageSize);auto job=std::async(std::launch::async,[&]{return tree.read("/f",out.data(),out.size(),0);});PausedWork cleanup(*hooks,job);bool paused=hooks->wait(1);tree.freeze(true);tree.freeze(false);auto gen=tree.checkpointState().first;hooks->release(1);assert(job.get()==int(pageSize)&&paused&&out==data);assert(!tree.stat("/f",&after)&&sameTime(before.st_atimespec,after.st_atimespec)&&gen==tree.checkpointState().first);
 }else if(test=="profile-regions"){
#ifdef RAMNEST_DEBUG_PROFILING
  auto window=std::make_shared<profile::Window>("fixture","read","memory",false,0);profile::active.store(window);hooks->arm(IoTestHooks::Point::readCaptured);std::vector<char> out(pageSize);auto job=std::async(std::launch::async,[&]{return tree.read("/f",out.data(),out.size(),0);});PausedWork cleanup(*hooks,job);bool paused=hooks->wait(1);auto captureHolds=window->counters[size_t(profile::Metric::tree_hold)].calls.load();auto earlyHashes=window->counters[size_t(profile::Metric::sha256)].calls.load();hooks->release(1);assert(job.get()==int(pageSize)&&paused&&captureHolds==1&&earlyHashes==0);assert(tree.write("/f",data.data(),data.size(),0)==int(pageSize));profile::active.store(nullptr);assert(window->counters[size_t(profile::Metric::tree_hold)].calls==4&&window->counters[size_t(profile::Metric::tree_wait)].calls==4);assert(window->counters[size_t(profile::Metric::sha256)].calls==3);
#endif
 }else if(test=="quota-same"){
  MemoryFS t(pageSize,false);assert(!t.create("/a",S_IFREG|0600));auto hook=std::make_shared<IoTestHooks>();t.setIoHooksForTest(hook);hook->arm(IoTestHooks::Point::writeStaged);auto job=std::async(std::launch::async,[&]{return t.write("/a",data.data(),data.size(),0);});PausedWork cleanup(*hook,job);bool paused=hook->wait(1);assert(t.write("/a",data.data(),data.size(),pageSize)==int(pageSize));hook->release(1);assert(job.get()==-ENOSPC&&paused&&t.used()==pageSize&&t.accountingOracleForTest());
 }else if(test=="quota"||test=="resize"){
  MemoryFS t(test=="quota"?pageSize:2*pageSize,false);assert(!t.create("/a",S_IFREG|0600)&&!t.create("/b",S_IFREG|0600));auto hook=std::make_shared<IoTestHooks>();t.setIoHooksForTest(hook);hook->arm(IoTestHooks::Point::writeStaged);auto job=std::async(std::launch::async,[&]{return t.write("/a",data.data(),data.size(),0);});PausedWork cleanup(*hook,job);bool paused=hook->wait(1);assert(t.write("/b",data.data(),data.size(),0)==int(pageSize));if(test=="resize")assert(!t.resize(pageSize));hook->release(1);int result=job.get();assert(paused&&result==-ENOSPC&&t.used()==pageSize&&t.accountingOracleForTest());
 }else if(test=="allocation"){
  for(int fail=0;fail<8;fail++){auto m=tree.metrics();struct stat st;assert(!tree.stat("/f",&st));auto gen=tree.checkpointState().first;hooks->failAfter(fail);auto b=bytes(2*pageSize,99);int e=tree.write("/f",b.data(),b.size(),0);hooks->failAfter(-1);if(e<0){assert(e==-ENOMEM);exactState(tree,m,st,gen);}else assert(e==int(b.size()));}
  tree.setCaptureLimitForTest(1);char out[2]={'q','q'};auto gen=tree.checkpointState().first;assert(tree.read("/f",out,1,0)==-ENOMEM&&out[0]==0&&out[1]=='q');assert(tree.write("/f","A",1,0)==-ENOMEM&&tree.checkpointState().first==gen);tree.setCaptureLimitForTest(0);
 }else if(test=="physical"){
  hooks->arm(IoTestHooks::Point::readCaptured);std::vector<char> out(pageSize);auto job=std::async(std::launch::async,[&]{return tree.read("/f",out.data(),out.size(),0);});PausedWork cleanup(*hooks,job);bool paused=hooks->wait(1);tree.setBackingLimitForTest(3*pageSize);assert(tree.write("/f",data.data(),data.size(),0)==int(pageSize));auto m=tree.metrics();assert(m.mapped==3*pageSize);assert(tree.write("/f",data.data(),data.size(),0)==-ENOMEM);hooks->release(1);assert(job.get()==int(pageSize)&&paused);assert(tree.metrics().mapped==2*pageSize);
 }else if(test=="capture-pool"){
  // One read capture fits; another concurrent capture cannot use a private pool.
  tree.setCaptureLimitForTest(65*sizeof(MappedPage)+512);hooks->arm(IoTestHooks::Point::readCaptured);std::vector<char> out(pageSize);auto job=std::async(std::launch::async,[&]{return tree.read("/f",out.data(),out.size(),0);});PausedWork cleanup(*hooks,job);bool paused=hooks->wait(1);char c='q';int result=tree.read("/other",&c,1,0);hooks->release(1);assert(job.get()==int(pageSize)&&paused&&result==-ENOMEM&&c==0);tree.setCaptureLimitForTest(0);
 }else if(test=="capture-export"){
  auto base=std::filesystem::path(argv[2])/("io-pool-"+std::to_string(getpid()));std::filesystem::create_directories(base);tree.setCaptureLimitForTest(65*sizeof(MappedPage)+512);hooks->arm(IoTestHooks::Point::readCaptured);std::vector<char> out(pageSize);auto job=std::async(std::launch::async,[&]{return tree.read("/f",out.data(),out.size(),0);});PausedWork cleanup(*hooks,job);bool paused=hooks->wait(1);int exported=tree.exportTree((base/"rejected").string());hooks->release(1);assert(job.get()==int(pageSize)&&paused&&exported==-ENOMEM);assert(!tree.exportTree((base/"accepted").string()));std::filesystem::remove_all(base);
 }else if(test=="export"||test=="failed-thaw"||test=="quiesce"){
  std::filesystem::path base=std::filesystem::path(argv[2])/("io-"+test+"-"+std::to_string(getpid()));std::filesystem::create_directories(base);
  if(test=="export"){hooks->arm(IoTestHooks::Point::exportCaptured);auto job=std::async(std::launch::async,[&]{return tree.exportTree((base/"G").string());});PausedWork cleanup(*hooks,job);bool paused=hooks->wait(1);assert(tree.write("/f","NEW",3,0)==3);hooks->release(1);assert(job.get()==0&&paused);auto generation=tree.lastExportStats().generation;std::ifstream f(base/"G/f",std::ios::binary);std::vector<char> old((std::istreambuf_iterator<char>(f)),{});assert(old==data);assert(!tree.exportTree((base/"next").string(),false,(base/"G").string(),generation)&&!tree.lastExportStats().reused);}
  else {hooks->arm(IoTestHooks::Point::writeStaged);auto job=std::async(std::launch::async,[&]{return tree.write("/f","NEW",3,0);});PausedWork cleanup(*hooks,job);bool paused=hooks->wait(1);if(test=="failed-thaw"){tree.setCaptureLimitForTest(1);assert(tree.exportTree((base/"fail").string(),true)==-ENOMEM&&!tree.isFrozen());tree.setCaptureLimitForTest(0);}else assert(!tree.exportTree((base/"frozen").string(),true)&&tree.isFrozen());hooks->release(1);assert(job.get()==-EBUSY&&paused);}
  std::filesystem::remove_all(base);
 }else assert(false);
 assert(tree.accountingOracleForTest());std::cout<<"PASS native io "<<test<<std::endl;
}
