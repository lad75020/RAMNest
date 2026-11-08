#include "MemoryFS.hpp"
#include <cassert>
#include <cstring>
#include <iostream>
#include <vector>
#include <random>
#include <filesystem>
#include <fstream>
#include <sys/acl.h>
#include <sys/xattr.h>
#include <membership.h>
#include <sys/resource.h>
using namespace ramnest;
int main(){
    MemoryFS fs(32*1024*1024);assert(fs.create("/sentinel",S_IFREG|0600)==0);assert(fs.write("/sentinel","kept",4,0)==4);
    struct stat before{},after{};assert(fs.stat("/sentinel",&before)==0);auto metrics=fs.metrics();
    std::vector<uint64_t> handles(4096);for(auto&h:handles)assert(fs.open("/sentinel",h,O_RDONLY)==0);
    uint64_t rejected=999999;auto result=fs.open("/sentinel",rejected,O_WRONLY|O_TRUNC);assert(fs.stat("/sentinel",&after)==0);
    std::cout<<"item1 saturated result="<<result<<" size="<<after.st_size<<" expected="<<before.st_size<<std::endl;
    assert(rejected==999999&&result==-EMFILE&&after.st_size==before.st_size&&fs.metrics().logical==metrics.logical);
    assert(after.st_mtimespec.tv_sec==before.st_mtimespec.tv_sec&&after.st_mtimespec.tv_nsec==before.st_mtimespec.tv_nsec);
    char bytes[4];assert(fs.read("/sentinel",bytes,4,0)==4&&!memcmp(bytes,"kept",4));
    for(auto h:handles)assert(fs.close(h)==0);
    for(int stage=0;stage<3;stage++){
        fs.failOpenAllocationForTest(stage);assert(fs.open("/sentinel",rejected,O_WRONLY|O_TRUNC)==-ENOMEM&&rejected==999999);
        assert(fs.stat("/sentinel",&after)==0&&after.st_size==4&&fs.used()==metrics.logical);
        assert(fs.read("/sentinel",bytes,4,0)==4&&!memcmp(bytes,"kept",4));
    }
    fs.failOpenAllocationForTest(-1);
    MemoryFS small(65536);assert(small.create("/sentinel",S_IFREG|0600)==0&&small.write("/sentinel","kept",4,0)==4);
    handles.clear();uint64_t candidate=0;while(small.open("/sentinel",candidate,O_RDONLY)==0)handles.push_back(candidate);
    assert(handles.size()<4096&&small.open("/sentinel",candidate,O_WRONLY|O_TRUNC)==-EMFILE);
    assert(small.stat("/sentinel",&after)==0&&after.st_size==4&&small.used()==pageSize);
    for(auto h:handles)assert(small.close(h)==0);
    assert(fs.open("/sentinel",rejected,O_WRONLY|O_TRUNC)==0&&fs.stat("/sentinel",&after)==0&&after.st_size==0&&fs.close(rejected)==0);
    std::cout<<"PASS item1 admission sentinel\n";
    MemoryFS atomic(8*pageSize);assert(atomic.create("/atomic",S_IFREG|0600)==0);
    std::vector<char> original(2*pageSize,'a'),replacement(2*pageSize,'b'),readback(2*pageSize);
    assert(atomic.write("/atomic",original.data(),original.size(),0)==int(original.size()));
    struct stat saved{};assert(atomic.stat("/atomic",&saved)==0);auto allocation=atomic.metrics();
    for(int stage=0;stage<2;stage++){
        MappedPage::failAllocationForTest(stage);
        assert(atomic.write("/atomic",replacement.data(),replacement.size(),0)==-ENOMEM);
        assert(atomic.stat("/atomic",&after)==0&&after.st_size==saved.st_size&&after.st_mtimespec.tv_sec==saved.st_mtimespec.tv_sec&&after.st_mtimespec.tv_nsec==saved.st_mtimespec.tv_nsec);
        assert(atomic.read("/atomic",readback.data(),readback.size(),0)==int(readback.size())&&readback==original);
        assert(atomic.metrics().mapped==allocation.mapped&&atomic.accountingOracleForTest());
    }
    MappedPage::failAllocationForTest(-1);
    assert(atomic.flipPayloadByteForTest("/atomic",1)==0&&atomic.write("/atomic",replacement.data(),replacement.size(),0)==-EIO);
    assert(atomic.flipPayloadByteForTest("/atomic",1)==0&&atomic.read("/atomic",readback.data(),readback.size(),0)==int(readback.size())&&readback==original);
    std::cout<<"PASS item9 deterministic staged page ENOMEM and corruption atomicity\n";
    MemoryFS random(256*1024*1024);std::mt19937 rng(77123);
    for(int step=0;step<12000;step++){
        auto a="/f"+std::to_string(rng()%100),b="/f"+std::to_string(rng()%100);
        switch(rng()%9){
            case 0:random.create(a,S_IFREG|0600);break;
            case 1:random.write(a,"changed",7,(rng()%8)*pageSize);break;
            case 2:random.link(a,b);break;
            case 3:random.rename(a,b);break;
            case 4:random.truncate(a,rng()%(8*pageSize));break;
            case 5:random.setxattr(a,"user.test",std::string(rng()%100,'a'),0);break;
            case 6:random.removexattr(a,"user.test");break;
            case 7:random.remove(a);break;
            case 8:{uint64_t h;if(!random.open(a,h)){random.remove(a);random.write("","detached",8,0,h);random.close(h);}break;}
        }
        if(!random.accountingOracleForTest()){std::cerr<<"oracle failed step="<<step<<std::endl;abort();}
    }
    for(int i=0;i<10000;i++){assert(random.create("/churn",S_IFDIR|0700)==0);assert(random.remove("/churn",true)==0);}
    assert(random.registrySizeForTest()<1024&&random.accountingOracleForTest());
    const char* fixtureRoot=getenv("RAMNEST_TEST_ROOT");assert(fixtureRoot);auto base=std::filesystem::path(fixtureRoot);std::filesystem::create_directories(base);std::string pattern=(base/"review-fixture-XXXXXX").string();auto temp=mkdtemp(pattern.data());assert(temp);std::filesystem::path fixture=temp;
    auto source=fixture/"source";std::filesystem::create_directory(source);std::filesystem::create_directory(source/"nested");{std::ofstream out(source/"nested/file");out<<"keep";}
    for(auto path:{source,source/"nested",source/"nested/file"}){
        auto acl=acl_init(1);assert(acl);acl_entry_t entry;assert(acl_create_entry(&acl,&entry)==0);assert(acl_set_tag_type(entry,ACL_EXTENDED_ALLOW)==0);uuid_t owner;assert(mbr_uid_to_uuid(getuid(),owner)==0&&acl_set_qualifier(entry,owner)==0);acl_permset_t perms;assert(acl_get_permset(entry,&perms)==0&&acl_add_perm(perms,ACL_READ_DATA)==0&&acl_set_file(path.c_str(),ACL_TYPE_EXTENDED,acl)==0);acl_free(acl);
        struct stat before{},after{};assert(::lstat((source/"nested/file").c_str(),&before)==0);MemoryFS denied(16*1024*1024);assert(denied.importTree(source.string())==-ENOTSUP);std::vector<std::string> names;assert(denied.entries("/",names)==0&&names.size()==2&&denied.used()==0);assert(::lstat((source/"nested/file").c_str(),&after)==0&&after.st_ino==before.st_ino&&after.st_size==before.st_size);auto empty=acl_init(0);assert(empty&&acl_set_file(path.c_str(),ACL_TYPE_EXTENDED,empty)==0);acl_free(empty);
    }
    // Do not depend on automatically generated macOS attributes for a race.
    assert(::setxattr((source/"nested/file").c_str(),"user.fixture","value",5,0,0)==0);
    for(int failure=0;failure<3;failure++){
        MemoryFS attributes(16*1024*1024);
        auto list=failure==0?+[](const char*,char*,size_t,int)->ssize_t{errno=EIO;return -1;} : failure==1?+[](const char*p,char*b,size_t n,int options)->ssize_t{auto result=::listxattr(p,b,n,options);return b&&result>0?result-1:result;} : ::listxattr;
        auto read=failure==2?+[](const char*p,const char*k,void*b,size_t n,uint32_t position,int options)->ssize_t{auto result=::getxattr(p,k,b,n,position,options);return b&&result>0?result-1:result;} : ::getxattr;
        attributes.setImportAttributesForTest(list,read);assert(attributes.importTree(source.string())==(failure==0?-EIO:-ESTALE));
    }
    std::cout<<"PASS item2 native root/nested/file ACL rejection before any import mutation; native list EIO/list shrink/value shrink failures\n";
    for(int count:{1000,10000,50000}){
        MemoryFS page(1024ULL*1024*1024);for(int i=0;i<count;i++)assert(page.create("/p"+std::to_string(i),S_IFREG|0600)==0);uint64_t dh;assert(page.openDirectory("/",dh)==0);std::shared_ptr<const std::vector<std::string>> stable,current;assert(page.directorySnapshot(dh,stable)==0&&stable->size()==size_t(count+2));assert(page.create("/later",S_IFDIR|0700)==0&&page.remove("/p0")==0);
        for(size_t i=0;i<stable->size();i++)assert(page.directorySnapshot(dh,current)==0&&current==stable);
        assert(page.close(dh)==0&&page.directorySnapshot(dh,current)==-EBADF&&stable->size()==size_t(count+2)&&page.accountingOracleForTest());
    }
    MemoryFS sparse(16*1024*1024);const int64_t high=int64_t(8)<<30;
    assert(sparse.create("/sparse",S_IFREG|0600)==0&&sparse.write("/sparse","x",1,high+100)==1&&sparse.link("/sparse","/alias")==0);
    assert(sparse.create("/all-zero",S_IFREG|0600)==0&&sparse.truncate("/all-zero",int64_t(64)<<30)==0&&sparse.used()==pageSize);
    assert(sparse.exportTree((fixture/"sparse-save").string())==0);MemoryFS remount(16*1024*1024);assert(remount.importTree((fixture/"sparse-save").string())==0);
    char sentinel=0;assert(remount.read("/alias",&sentinel,1,high+100)==1&&sentinel=='x'&&remount.used()<pageSize+4096);
    struct stat primary{},alias{};assert(remount.stat("/sparse",&primary)==0&&remount.stat("/alias",&alias)==0&&primary.st_ino==alias.st_ino&&primary.st_size==high+101);
    assert(sparse.truncate("/sparse",high+50)==0&&sparse.truncate("/sparse",high+101)==0&&sparse.used()==0&&sparse.read("/sparse",&sentinel,1,high+100)==1&&sentinel==0&&sparse.accountingOracleForTest());
    std::cout<<"PASS item5 native no-mount save/remount: 8GiB high offset, 64GiB zero length, hardlinks, exact occupied-page quota, truncate/regrow suffix zero\n";
    auto deep=source/"nested";for(int i=0;i<150;i++){deep/="d";std::filesystem::create_directory(deep);} {std::ofstream out(deep/"leaf");out<<"depth";}
    rlimit limits;assert(getrlimit(RLIMIT_NOFILE,&limits)==0);auto reduced=limits;reduced.rlim_cur=96;assert(setrlimit(RLIMIT_NOFILE,&reduced)==0);MemoryFS imported(64*1024*1024);assert(imported.importTree(source.string())==0&&imported.exportTree((fixture/"deep-export").string())==0);assert(setrlimit(RLIMIT_NOFILE,&limits)==0);
    std::cout<<"PASS item11 1000/10000/50000 stable shared cookies, mutation/closed/pinned snapshot lifetime and 150-deep import/export at 96 FDs\n";
    std::cout<<"PASS item4 randomized 12000 operations and 10000 node churn registry="<<random.registrySizeForTest()<<"\n";
}
