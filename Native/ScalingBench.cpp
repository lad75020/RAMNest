#include "MemoryFS.hpp"
#include <cassert>
#include <chrono>
#include <filesystem>
#include <iostream>
using namespace ramnest;
using Clock=std::chrono::steady_clock;
static double ms(Clock::time_point a,Clock::time_point b){return std::chrono::duration<double,std::milli>(b-a).count();}
int main(int argc,char**argv){
 assert(argc==2);std::filesystem::path root=argv[1];std::filesystem::create_directories(root);
 for(int count:{1000,2000,4000,8000}){
  MemoryFS tree(1024ULL*1024*1024);auto begin=Clock::now();for(int i=0;i<count;i++)assert(tree.create("/f"+std::to_string(i),S_IFREG|0600)==0);auto created=Clock::now();
  for(int i=0;i<count;i++)assert(tree.write("/f"+std::to_string(i),"a",1,0)==1);auto written=Clock::now();uint64_t h;assert(tree.openDirectory("/",h)==0);
  auto paging=Clock::now();std::shared_ptr<const std::vector<std::string>> first,snapshot;assert(tree.directorySnapshot(h,first)==0);for(size_t offset=0;offset<first->size();offset++){assert(tree.directorySnapshot(h,snapshot)==0&&snapshot==first);assert((*snapshot)[offset]==(*first)[offset]);}auto paged=Clock::now();
  for(int i=0;i<1000;i++){auto m=tree.metrics();assert(m.logical==uint64_t(count)*pageSize);}auto status=Clock::now();assert(tree.accountingOracleForTest());
  std::cout<<"{\"nodes\":"<<count<<",\"create_ms\":"<<ms(begin,created)<<",\"write_ms\":"<<ms(created,written)<<",\"paginate_one_entry_ms\":"<<ms(paging,paged)<<",\"metrics1000_ms\":"<<ms(paged,status)<<",\"registry\":"<<tree.registrySizeForTest()<<"}"<<std::endl;
  auto prefix=root/std::to_string(count);std::filesystem::create_directory(prefix);auto initial=prefix/"initial";auto start=Clock::now();assert(tree.exportTree(initial.string())==0);auto exported=Clock::now();auto checkpoint=tree.lastExportStats();
  assert(tree.exportTree((prefix/"noop").string(),false,initial.string(),checkpoint.generation)==0);auto noop=Clock::now();auto reused=tree.lastExportStats();assert(reused.reused&&reused.written==0);
  auto previous=initial;
  for(int percent:{1,10,100}){
   for(int i=0;i<count*percent/100;i++)assert(tree.write("/f"+std::to_string(i),"b",1,0)==1);
   auto destination=prefix/("dirty"+std::to_string(percent));auto t=Clock::now();assert(tree.exportTree(destination.string(),false,previous.string(),checkpoint.generation)==0);auto end=Clock::now();checkpoint=tree.lastExportStats();
   std::cout<<"{\"nodes\":"<<count<<",\"dirty_percent\":"<<percent<<",\"save_ms\":"<<ms(t,end)<<",\"written_bytes\":"<<checkpoint.written<<",\"cloned_files\":"<<checkpoint.clonedFiles<<",\"decoded_bytes\":"<<checkpoint.decoded<<",\"readback_bytes\":"<<checkpoint.readback<<"}"<<std::endl;previous=destination;
  }
  std::cout<<"{\"nodes\":"<<count<<",\"initial_save_ms\":"<<ms(start,exported)<<",\"noop_save_ms\":"<<ms(exported,noop)<<",\"noop_written_bytes\":"<<reused.written<<",\"noop_readback_bytes\":"<<reused.readback<<"}"<<std::endl;
 }
}
