#include "MemoryFS.hpp"
#include <cassert>
#include <cerrno>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdlib>
#include <filesystem>
#include <future>
#include <iostream>
using namespace ramnest;
static std::atomic<uint64_t> allocated{0};static bool measuring=false;
void* operator new(size_t size){if(measuring)allocated.fetch_add(size);if(auto p=malloc(size))return p;throw std::bad_alloc();}
void operator delete(void*p)noexcept{free(p);}void operator delete(void*p,size_t)noexcept{free(p);}
static std::mutex gateMutex;static std::condition_variable gate;static bool entered=false,released=false;
static ssize_t pauseWriter(int fd,const void*p,size_t count,off_t offset){std::unique_lock g(gateMutex);entered=true;gate.notify_all();if(!gate.wait_for(g,std::chrono::seconds(10),[]{return released;})){errno=ETIMEDOUT;return -1;}g.unlock();return pwrite(fd,p,count,offset);}
int main(int argc,char**argv){
 assert(argc==3);std::string mode=argv[1];std::filesystem::path base=argv[2];std::filesystem::create_directories(base);std::string pattern=(base/"performance-XXXXXX").string();auto temp=mkdtemp(pattern.data());assert(temp);std::filesystem::path fixture=temp;
 if(mode=="workspace"){
  std::vector<char> source(pageSize,'A');{MappedPage warm;assert(warm.encode(source.data(),false)==0);}allocated=0;measuring=true;{MappedPage raw;assert(raw.encode(source.data(),false)==0);}measuring=false;
  std::cout<<"raw_encode_allocated_bytes="<<allocated.load()<<" expected_lt=4096"<<std::endl;assert(allocated<4096);return 0;
 }
 MemoryFS tree(256*1024*1024);assert(tree.create("/file",S_IFREG|0600)==0&&tree.write("/file","old",3,0)==3);
 if(mode=="pagination"){
  for(int i=0;i<1000;i++)assert(tree.create("/p"+std::to_string(i),S_IFREG|0600)==0);uint64_t h;assert(tree.openDirectory("/",h)==0);allocated=0;measuring=true;
  for(int i=0;i<1000;i++){
#ifdef RAMNEST_BASELINE
   std::vector<std::string> v;assert(tree.directoryEntries(h,v)==0);
#else
   std::shared_ptr<const std::vector<std::string>> v;assert(tree.directorySnapshot(h,v)==0);
#endif
  }
  measuring=false;std::cout<<"pagination1000_allocated_bytes="<<allocated.load()<<" expected_lt=65536"<<std::endl;assert(allocated<65536);return 0;
 }
 if(mode=="noop"){
  uint64_t written=0; // real export writer calls tracked by production stats or disk workload
  assert(tree.exportTree((fixture/"first").string())==0);
#ifdef RAMNEST_BASELINE
  static uint64_t writes=0;tree.setExportWriterForTest(+[](int fd,const void*p,size_t n,off_t off)->ssize_t{writes+=n;return pwrite(fd,p,n,off);});
  assert(tree.exportTree((fixture/"second").string())==0);written=writes;
#else
  auto checkpoint=tree.lastExportStats();assert(tree.exportTree((fixture/"second").string(),false,(fixture/"first").string(),checkpoint.generation)==0);written=tree.lastExportStats().written;
#endif
  std::cout<<"noop_written_bytes="<<written<<" expected=0"<<std::endl;assert(written==0);return 0;
 }
 tree.setExportWriterForTest(pauseWriter);auto work=std::async(std::launch::async,[&]{return tree.exportTree((fixture/"concurrent").string());});{std::unique_lock g(gateMutex);assert(gate.wait_for(g,std::chrono::seconds(5),[]{return entered;}));}
 auto reader=std::async(std::launch::async,[&]{return tree.metrics();});auto result=reader.wait_for(std::chrono::milliseconds(100));bool ready=result==std::future_status::ready;
 {std::lock_guard g(gateMutex);released=true;}gate.notify_all();assert(work.get()==0);(void)reader.get();std::cout<<"metrics_progress_while_export_paused="<<ready<<" expected=1"<<std::endl;assert(ready);
}
