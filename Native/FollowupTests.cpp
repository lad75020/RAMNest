#include "MemoryFS.hpp"
#include <cassert>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <future>
#include <condition_variable>
#include <iostream>
#include <copyfile.h>
#include <sys/xattr.h>
using namespace ramnest;
namespace fs=std::filesystem;
static std::mutex mutex;static std::condition_variable cv;static bool entered=false,released=false;
static ssize_t writer(int fd,const void*p,size_t n,off_t at){std::unique_lock g(mutex);entered=true;cv.notify_all();if(!cv.wait_for(g,std::chrono::seconds(10),[]{return released;}))return -1;return pwrite(fd,p,n,at);}
static std::string read(const fs::path&p){std::ifstream f(p);return {std::istreambuf_iterator<char>(f),{}};}
int main(int argc,char**argv){assert(argc==3);fs::path base=fs::path(argv[2])/ ("native-followup-"+std::to_string(getpid())+"-"+argv[1]);assert(fs::create_directory(base));std::string which=argv[1];
 if(which=="pins"){
  MemoryFS tree(16*pageSize,false);assert(tree.create("/f",S_IFREG|0600)==0&&tree.write("/f","old",3,0)==3);
  uint64_t h;assert(tree.open("/f",h,O_RDWR)==0);tree.setExportWriterForTest(writer);
  auto job=std::async(std::launch::async,[&]{return tree.exportTree((base/"G").string());});
  {std::unique_lock g(mutex);assert(cv.wait_for(g,std::chrono::seconds(5),[]{return entered;}));}
  assert(tree.write("/f","new",3,0)==3);
  tree.setBackingLimitForTest(2*pageSize);
  assert(tree.write("/f","retry",5,0)==-ENOMEM);
  char liveBytes[3];assert(tree.read("/f",liveBytes,3,0)==3&&std::string(liveBytes,3)=="new");
  assert(tree.metrics().mapped==2*pageSize);assert(tree.used()==pageSize);
  assert(tree.remove("/f")==0&&tree.close(h)==0);
  auto live=tree.used(),physical=tree.metrics().mapped;bool oracle=tree.accountingOracleForTest();
  {std::lock_guard g(mutex);released=true;}cv.notify_all();assert(job.get()==0);
  std::cout<<"snapshot_only live="<<live<<" physical="<<physical<<" released="<<tree.metrics().mapped<<std::endl;
  assert(live==0&&physical==pageSize&&oracle&&tree.metrics().mapped==0&&tree.accountingOracleForTest());
 } else if(which=="capture-limit"){
  MemoryFS tree(16*pageSize);assert(tree.create("/f",S_IFREG|0600)==0&&tree.write("/f","old",3,0)==3);auto before=tree.metrics();
  tree.setCaptureLimitForTest(1);assert(tree.exportTree((base/"reject").string(),true)==-ENOMEM&&!tree.isFrozen());
  assert(tree.metrics().mapped==before.mapped&&tree.used()==before.logical&&tree.accountingOracleForTest());
 } else if(which=="symlink"){
  MemoryFS tree(16*pageSize);assert(tree.symlink("target","/a")==0);assert(tree.link("/a","/b")==-ENOTSUP);
  auto source=base/"source";fs::create_directory(source);assert(::symlink("target",(source/"a").c_str())==0&&::linkat(AT_FDCWD,(source/"a").c_str(),AT_FDCWD,(source/"b").c_str(),0)==0);
  MemoryFS imported(16*pageSize);assert(imported.importTree(source.string())==-ENOTSUP);std::vector<std::string> names;assert(imported.entries("/",names)==0&&names.size()==2);
 } else if(which=="topology"){
  for(bool split:{false,true}){
   MemoryFS tree(16*pageSize);assert(tree.create("/a",S_IFREG|0600)==0&&tree.write("/a","same",4,0)==4);
   if(split)assert(tree.link("/a","/b")==0);else{assert(tree.create("/b",S_IFREG|0600)==0&&tree.write("/b","same",4,0)==4);struct stat st;assert(tree.stat("/a",&st)==0);timespec t[2]={st.st_atimespec,st.st_mtimespec};assert(tree.times("/b",t)==0);}
   auto prior=base/(split?"split":"merge");assert(tree.exportTree(prior.string())==0);auto generation=tree.lastExportStats().generation;
   if(split){assert(::rename((prior/"b").c_str(),(base/"saved").c_str())==0);assert(copyfile((prior/"a").c_str(),(prior/"b").c_str(),nullptr,COPYFILE_ALL|COPYFILE_NOFOLLOW)==0);}else{assert(::unlink((prior/"b").c_str())==0&&::link((prior/"a").c_str(),(prior/"b").c_str())==0);}
   assert(tree.exportTree((base/(split?"unused-split":"unused-merge")).string(),false,prior.string(),generation)<0);
  }
 } else if(which=="compressed-corruption"||which=="compressed-valid"){
  MemoryFS tree(16*pageSize);assert(tree.create("/f",S_IFREG|0600)==0&&tree.truncate("/f",20)==0);
  auto prior=base/"prior";assert(tree.exportTree(prior.string())==0);auto generation=tree.lastExportStats().generation;
  std::array<unsigned char,36> header{};uint32_t magic=0x636d7066,type=1;uint64_t length=20;
  memcpy(header.data(),&magic,4);memcpy(header.data()+4,&type,4);memcpy(header.data()+8,&length,8);memset(header.data()+16,which=="compressed-corruption"?'X':0,20);
  assert(::setxattr((prior/"f").c_str(),"com.apple.decmpfs",header.data(),header.size(),0,XATTR_NOFOLLOW)==0&&::lchflags((prior/"f").c_str(),UF_COMPRESSED)==0);
  assert(read(prior/"f")==std::string(20,which=="compressed-corruption"?'X':0));assert(tree.chmod("/f",0640)==0);
  auto result=tree.exportTree((base/"next").string(),false,prior.string(),generation);
  std::cout<<"compressed_old_candidate result="<<result<<std::endl;
  if(which=="compressed-corruption")assert(result==-EIO);
  else{assert(result==0&&tree.lastExportStats().clonedFiles==0&&read(base/"next/f")==std::string(20,0));struct stat st{};assert(::lstat((base/"next/f").c_str(),&st)==0&&!(st.st_flags&UF_COMPRESSED));}
 } else if(which=="frozen-read"){
  MemoryFS tree(16*pageSize);assert(tree.create("/f",S_IFREG|0600)==0&&tree.write("/f","data",4,0)==4);
  assert(tree.exportTree((base/"prior").string(),true)==0);auto generation=tree.lastExportStats().generation;
  struct stat before{},after{};assert(tree.stat("/f",&before)==0);char data[4];assert(tree.read("/f",data,4,0)==4&&tree.stat("/f",&after)==0);
  assert(after.st_atimespec.tv_sec==before.st_atimespec.tv_sec&&after.st_atimespec.tv_nsec==before.st_atimespec.tv_nsec);
  assert(tree.exportTree((base/"unused").string(),true,(base/"prior").string(),generation)==0&&tree.lastExportStats().reused);
 } else if(which=="generation"){
  MemoryFS tree(16*pageSize);assert(tree.create("/f",S_IFREG|0600)==0&&tree.write("/f","G",1,0)==1);tree.setExportWriterForTest(writer);
  auto job=std::async(std::launch::async,[&]{return tree.exportTree((base/"G").string());});{std::unique_lock g(mutex);assert(cv.wait_for(g,std::chrono::seconds(5),[]{return entered;}));}
  assert(tree.write("/f","G+1",3,0)==3);{std::lock_guard g(mutex);released=true;}cv.notify_all();assert(job.get()==0);auto generation=tree.lastExportStats().generation;tree.setExportWriterForTest(::pwrite);
  assert(read(base/"G/f")=="G");assert(tree.exportTree((base/"next").string(),false,(base/"G").string(),generation)==0);assert(!tree.lastExportStats().reused&&read(base/"next/f")=="G+1");
 }
 std::cout<<"PASS native followup "<<which<<"\n";
}
