#include "MemoryFS.hpp"
#include <cassert>
#include <iostream>
#include <mach/mach.h>
#include <thread>
using namespace ramnest;
static uint64_t rss(){mach_task_basic_info info{};mach_msg_type_number_t count=MACH_TASK_BASIC_INFO_COUNT;assert(task_info(mach_task_self(),MACH_TASK_BASIC_INFO,reinterpret_cast<task_info_t>(&info),&count)==KERN_SUCCESS);return info.resident_size;}
static uint64_t settle(){std::this_thread::sleep_for(std::chrono::milliseconds(250));return rss();}
static uint64_t hash(const char*p){uint64_t h=1;for(size_t i=0;i<pageSize;i++)h=(h*131)^static_cast<unsigned char>(p[i]);return h;}
int main(){
    constexpr uint64_t size=128*1024*1024;MemoryFS tree(size*2);std::array<char,pageSize>chunk{},out{};std::vector<uint64_t>hashes;uint64_t initial=settle();assert(tree.create("/random",S_IFREG|0600)==0);
    for(uint64_t off=0;off<size;off+=pageSize){arc4random_buf(chunk.data(),chunk.size());hashes.push_back(hash(chunk.data()));assert(tree.write("/random",chunk.data(),chunk.size(),off)==int(chunk.size()));}
    for(uint64_t off=0;off<size;off+=pageSize){assert(tree.read("/random",out.data(),out.size(),off)==int(out.size()));assert(hash(out.data())==hashes[off/pageSize]);}
    uint64_t random=settle();assert(random>initial+96*1024*1024);assert(tree.truncate("/random",size/2)==0);uint64_t truncated=settle();assert(random>truncated+48*1024*1024);assert(tree.remove("/random")==0);uint64_t unlinked=settle();assert(truncated>unlinked+48*1024*1024);
    assert(tree.create("/compressible",S_IFREG|0600)==0);chunk.fill('A');for(uint64_t off=0;off<size;off+=pageSize)assert(tree.write("/compressible",chunk.data(),chunk.size(),off)==int(chunk.size()));for(uint64_t off=0;off<size;off+=pageSize){assert(tree.read("/compressible",out.data(),out.size(),off)==int(out.size())&&out==chunk);}
    auto metrics=tree.metrics();uint64_t compressible=settle();assert(metrics.mapped==size/4);assert(random>compressible+64*1024*1024);assert(tree.remove("/compressible")==0);uint64_t final=settle();assert(compressible>final+24*1024*1024);
    std::cout<<"{\"initialRSS\":"<<initial<<",\"random128MiBRSS\":"<<random<<",\"truncate64MiBRSS\":"<<truncated<<",\"unlinkRSS\":"<<unlinked<<",\"compressible128MiBRSS\":"<<compressible<<",\"compressedMapped\":"<<metrics.mapped<<",\"finalRSS\":"<<final<<",\"status\":\"PASS\"}\n";
}
