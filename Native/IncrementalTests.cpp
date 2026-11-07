#include "MemoryFS.hpp"
#include <cassert>
#include <cerrno>
#include <chrono>
#include <condition_variable>
#include <filesystem>
#include <fstream>
#include <future>
#include <iostream>
#include <sys/xattr.h>
using namespace ramnest;
namespace fs=std::filesystem;
static std::mutex gateMutex;
static std::condition_variable gate;
static bool entered=false,released=false;
static ssize_t gatedWriter(int fd,const void*p,size_t size,off_t offset){
    std::unique_lock g(gateMutex);entered=true;gate.notify_all();if(!gate.wait_for(g,std::chrono::seconds(10),[]{return released;})){errno=ETIMEDOUT;return -1;}g.unlock();return pwrite(fd,p,size,offset);
}
static std::string bytes(const fs::path&p){std::ifstream in(p,std::ios::binary);return std::string(std::istreambuf_iterator<char>(in),{});}
int main(){
 const char* fixtureRoot=getenv("RAMNEST_TEST_ROOT");assert(fixtureRoot);auto base=fs::path(fixtureRoot);fs::create_directories(base);std::string pattern=(base/"incremental-XXXXXX").string();auto temp=mkdtemp(pattern.data());assert(temp);fs::path fixture=temp;
 MemoryFS tree(256*1024*1024);
 for(int i=0;i<100;i++){auto name="/f"+std::to_string(i);assert(tree.create(name,S_IFREG|0600)==0&&tree.write(name,"old",3,0)==3);}
 assert(tree.link("/f0","/alias")==0);
 assert(tree.exportTree((fixture/"first").string())==0);auto first=tree.lastExportStats();assert(first.written==300&&first.decoded==100*pageSize);
 int noopResult=tree.exportTree((fixture/"noop-must-not-exist").string(),false,(fixture/"first").string(),first.generation);std::cout<<"noop_result="<<noopResult<<" fixture="<<fixture<<std::endl;assert(noopResult==0);
 auto noop=tree.lastExportStats();assert(noop.reused&&noop.written==0&&!fs::exists(fixture/"noop-must-not-exist"));
 assert(tree.write("/f1","new",3,0)==3);
 assert(tree.exportTree((fixture/"one-percent").string(),false,(fixture/"first").string(),first.generation)==0);
 auto dirty=tree.lastExportStats();assert(!dirty.reused&&dirty.written==3&&dirty.clonedFiles==99);
 assert(bytes(fixture/"first/f1")=="old"&&bytes(fixture/"one-percent/f1")=="new");
 struct stat old{},now{};assert(::lstat((fixture/"first/f2").c_str(),&old)==0&&::lstat((fixture/"one-percent/f2").c_str(),&now)==0&&old.st_ino!=now.st_ino);
 assert(tree.setxattr("/f2","user.remove","old",0)==0&&tree.chmod("/f2",0640)==0);
 assert(tree.exportTree((fixture/"metadata").string(),false,(fixture/"one-percent").string(),dirty.generation)==0);auto meta=tree.lastExportStats();assert(meta.written==0&&meta.clonedFiles==100);
 assert(::lstat((fixture/"metadata/f2").c_str(),&now)==0&&(now.st_mode&07777)==0640);
 assert(tree.removexattr("/f2","user.remove")==0&&tree.rename("/f2","/renamed")==0&&tree.remove("/f3")==0&&tree.link("/f1","/another")==0);
 assert(tree.exportTree((fixture/"namespace").string(),false,(fixture/"metadata").string(),meta.generation)==0);auto ns=tree.lastExportStats();assert(ns.written==0&&ns.clonedFiles==99);
 assert(!fs::exists(fixture/"namespace/f2")&&!fs::exists(fixture/"namespace/f3")&&bytes(fixture/"namespace/renamed")=="old");
 assert(::getxattr((fixture/"namespace/renamed").c_str(),"user.remove",nullptr,0,0,0)<0&&errno==ENOATTR);
 auto corrupt=fixture/"namespace/f4";int fd=::open(corrupt.c_str(),O_RDWR);assert(fd>=0);assert(::fstat(fd,&old)==0&&::pwrite(fd,"bad",3,0)==3);timespec ts[2]={old.st_atimespec,old.st_mtimespec};assert(futimens(fd,ts)==0);close(fd);
 assert(tree.exportTree((fixture/"corrupt-noop").string(),false,(fixture/"namespace").string(),ns.generation)<0&&!fs::exists(fixture/"corrupt-noop"));
 fd=::open(corrupt.c_str(),O_RDWR);assert(fd>=0&&::pwrite(fd,"old",3,0)==3&&futimens(fd,ts)==0);close(fd);
 // Capture must remain coherent while every disk write is paused indefinitely.
 tree.setExportWriterForTest(gatedWriter);assert(tree.write("/f1","CAP",3,0)==3);
 auto work=std::async(std::launch::async,[&]{return tree.exportTree((fixture/"concurrent").string());});
 {std::unique_lock g(gateMutex);assert(gate.wait_for(g,std::chrono::seconds(5),[]{return entered;}));}
 auto start=std::chrono::steady_clock::now();auto status=tree.metrics();assert(status.content>0);
 assert(tree.write("/f1","NOW",3,0)==3&&tree.rename("/renamed","/after-capture")==0&&tree.remove("/f4")==0);
 auto milliseconds=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();assert(milliseconds<1000);
 {std::lock_guard g(gateMutex);released=true;}gate.notify_all();assert(work.get()==0);
 assert(bytes(fixture/"concurrent/f1")=="CAP"&&fs::exists(fixture/"concurrent/renamed")&&fs::exists(fixture/"concurrent/f4"));assert(tree.accountingOracleForTest());
 tree.setExportWriterForTest(::pwrite);
 assert(tree.exportTree((fixture/"quiesced").string(),true)==0&&tree.isFrozen());auto frozen=tree.lastExportStats();assert(tree.write("/f1","x",1,0)==-EBUSY);
 tree.freeze(false);assert(tree.write("/f1","retry",5,0)==5);assert(tree.exportTree((fixture/"retry").string(),true,(fixture/"quiesced").string(),frozen.generation)==0&&!tree.lastExportStats().reused&&tree.isFrozen());
 tree.freeze(false);assert(tree.create("/private-dir",S_IFDIR|0000)==0);assert(tree.exportTree((fixture/"mode000").string())==0);
 std::cout<<"PASS items8/10 immutable revisions: initial_bytes="<<first.written<<" noop_bytes="<<noop.written<<" dirty1percent_bytes="<<dirty.written<<" cloned="<<dirty.clonedFiles<<" metadata_bytes="<<meta.written<<" contention_ms="<<milliseconds<<"; metadata removal, rename/delete/hardlinks, distinct inodes, same-mtime corruption, coherent paused export, quiesce/thaw/retry, mode000; fixture="<<fixture<<"\n";
}
