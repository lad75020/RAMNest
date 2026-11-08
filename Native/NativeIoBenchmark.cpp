#include "MemoryFS.hpp"
#include "DebugProfile.hpp"
#include <CommonCrypto/CommonDigest.h>
#include <algorithm>
#include <cassert>
#include <chrono>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <thread>
using namespace ramnest;
static std::string sha(const std::vector<char>& b){unsigned char d[32];CC_SHA256(b.data(),CC_LONG(b.size()),d);std::ostringstream s;for(auto c:d)s<<std::hex<<std::setw(2)<<std::setfill('0')<<unsigned(c);return s.str();}
int main(){
 constexpr size_t total=16*1024*1024;for(bool compressible:{false,true})for(bool compress:{false,true})for(bool single:{false,true})for(size_t request:{size_t(32768),size_t(1024*1024)})for(unsigned workers:{1,4,8}){
 MemoryFS tree(64*1024*1024,compress);auto hooks=std::make_shared<IoTestHooks>();tree.setIoHooksForTest(hooks);std::vector<char> expected(total),output(total);uint32_t x=17;for(size_t i=0;i<total;i++){x=x*1664525U+1013904223U;expected[i]=compressible?char((i/4096)%127+1):char(x>>24);}auto digest=sha(expected);
 if(single)assert(!tree.create("/f",S_IFREG|0600));else for(unsigned w=0;w<workers;w++)assert(!tree.create("/f"+std::to_string(w),S_IFREG|0600));
 for(int phase=0;phase<3;phase++){
  hooks->copied=0;hooks->zeroed=0;hooks->shaBytes=0;hooks->retries=0;hooks->fallbacks=0;hooks->mappedPeak=tree.metrics().mapped;
#ifdef RAMNEST_DEBUG_PROFILING
  auto window=std::make_shared<profile::Window>("native-bench",phase==2?"read":"write","memory",compress,0);profile::active.store(window);
#endif
  auto begin=std::chrono::steady_clock::now();std::vector<std::thread> threads;
  for(unsigned w=0;w<workers;w++)threads.emplace_back([&,w]{size_t first=w*(total/workers),end=first+total/workers;std::string path=single?"/f":"/f"+std::to_string(w);for(size_t pos=first;pos<end;pos+=request){auto count=std::min(request,end-pos);auto off=single?pos:pos-first;int result=phase==2?tree.read(path,output.data()+pos,count,off):tree.write(path,expected.data()+pos,count,off);assert(result==int(count));}});
  for(auto& t:threads)t.join();auto seconds=std::chrono::duration<double>(std::chrono::steady_clock::now()-begin).count();
#ifdef RAMNEST_DEBUG_PROFILING
  profile::active.store(nullptr);
#endif
  auto copied=hooks->copied.load(),zeroed=hooks->zeroed.load(),shaBytes=hooks->shaBytes.load();
  // Every write run has independent full readback; outside its timed window.
  if(phase!=2)for(unsigned w=0;w<workers;w++){size_t first=w*(total/workers),end=first+total/workers;auto path=single?"/f":"/f"+std::to_string(w);for(size_t pos=first;pos<end;pos+=request){auto count=std::min(request,end-pos);assert(tree.read(path,output.data()+pos,count,single?pos:pos-first)==int(count));}}
  assert(sha(output)==digest&&tree.accountingOracleForTest());
  std::cout<<"{\"integrityAlgorithm\":\"sha256\",\"phase\":\""<<(phase==0?"fresh-write":phase==1?"overwrite":"read")<<"\",\"compression\":"<<(compress?"true":"false")<<",\"compressible\":"<<(compressible?"true":"false")<<",\"singleFile\":"<<(single?"true":"false")<<",\"request\":"<<request<<",\"workers\":"<<workers<<",\"bytes\":"<<total<<",\"seconds\":"<<std::setprecision(10)<<seconds<<",\"MBps\":"<<total/seconds/1e6<<",\"sha256\":\""<<digest<<"\",\"verified\":true,\"mappedPeak\":"<<hooks->mappedPeak<<",\"copied\":"<<copied<<",\"zeroed\":"<<zeroed<<",\"shaBytes\":"<<shaBytes<<",\"retries\":"<<hooks->retries<<",\"fallbacks\":"<<hooks->fallbacks;
#ifdef RAMNEST_DEBUG_PROFILING
  std::cout<<",\"treeWaitNS\":"<<window->counters[size_t(profile::Metric::tree_wait)].ns<<",\"treeHoldNS\":"<<window->counters[size_t(profile::Metric::tree_hold)].ns;
#endif
  std::cout<<"}"<<std::endl;
 }
}}
