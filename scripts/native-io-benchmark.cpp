// No mounts: bounded request latency/allocation workload, linked to a chosen core.
#include "../Native/MemoryFS.hpp"
#include <algorithm>
#include <cassert>
#include <chrono>
#include <cstdlib>
#include <iostream>
#include <cmath>
#include <random>
using namespace ramnest;
static bool measuring=false;static uint64_t allocationCalls=0,allocationBytes=0;
void* operator new(size_t size){if(measuring){allocationCalls++;allocationBytes+=size;}if(auto p=malloc(size))return p;throw std::bad_alloc();}
void operator delete(void*p)noexcept{free(p);}void operator delete(void*p,size_t)noexcept{free(p);}
using Clock=std::chrono::steady_clock;
int main(){
 for(bool compression:{false,true})for(bool randomBytes:{false,true})for(bool unaligned:{false,true})for(size_t size:{size_t(1),size_t(4096),size_t(65536),size_t(1048576),size_t(4194304)}){
  MemoryFS tree(64*1024*1024,compression);assert(tree.create("/io",S_IFREG|0600)==0);std::vector<char> data(size,'A'),output(size);std::mt19937 random(88411);
  if(randomBytes)for(auto&c:data)c=char(random());
  assert(tree.write("/io",data.data(),size,unaligned?17:0)==int(size));assert(tree.read("/io",output.data(),size,unaligned?17:0)==int(size)&&output==data);
  size_t iterations=size<65536?128:std::max(size_t(8),size_t(16*1024*1024)/size);std::vector<double>writes,reads;writes.reserve(iterations);reads.reserve(iterations);allocationCalls=allocationBytes=0;
  for(size_t i=0;i<iterations;i++){
   // Mix sequential and seeded random offsets without exceeding 16 MiB.
   uint64_t off=(i%2?random()%(12*1024*1024):i*size%(12*1024*1024))+(unaligned?17:0);
   auto start=Clock::now();measuring=true;int wrote=tree.write("/io",data.data(),size,off);measuring=false;auto written=Clock::now();assert(wrote==int(size));
   measuring=true;int got=tree.read("/io",output.data(),size,off);measuring=false;auto end=Clock::now();assert(got==int(size)&&output==data);
   writes.push_back(std::chrono::duration<double,std::micro>(written-start).count());reads.push_back(std::chrono::duration<double,std::micro>(end-written).count());
  }
  std::sort(writes.begin(),writes.end());std::sort(reads.begin(),reads.end());
#ifndef RAMNEST_BASELINE
  assert(tree.accountingOracleForTest());
#endif
  auto metrics=tree.metrics();assert(tree.remove("/io")==0&&tree.metrics().mapped==0);
  std::cout<<"{\"compression\":"<<compression<<",\"random_bytes\":"<<randomBytes<<",\"unaligned\":"<<unaligned<<",\"request_bytes\":"<<size<<",\"iterations\":"<<iterations<<",\"write_p50_us\":"<<writes[iterations/2]<<",\"write_p99_us\":"<<writes[std::min(iterations-1,iterations*99/100)]<<",\"read_p50_us\":"<<reads[iterations/2]<<",\"read_p99_us\":"<<reads[std::min(iterations-1,iterations*99/100)]<<",\"cpp_allocations_per_pair\":"<<double(allocationCalls)/iterations<<",\"cpp_allocated_bytes_per_pair\":"<<double(allocationBytes)/iterations<<",\"mapped_before_unlink\":"<<metrics.mapped<<",\"mapped_after_unlink\":0}"<<std::endl;
 }
}
