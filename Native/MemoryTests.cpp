#include "MemoryFS.hpp"
#include <cassert>
#include <algorithm>
#include <cstring>
#include <filesystem>
#include <iostream>
#include <thread>
#include <unistd.h>
using namespace ramnest;
#include "StackTests.hpp"
static void rootHandlePopulateScenarios(const std::string& base){
    namespace fs=std::filesystem;
    fs::create_directories(base);std::string pattern=base+"/ramnest-root-populate-XXXXXX";
    auto directory=mkdtemp(pattern.data());assert(directory);fs::path fixture=directory,source=fixture/"source";
    fs::create_directories(source/"dir");
    {std::ofstream output(source/"file-é & name");output<<"fixture bytes";}
    {std::ofstream output(source/"dir"/"nested");output<<"nested bytes";}
    assert(::link((source/"file-é & name").c_str(),(source/"alias").c_str())==0);
    const std::vector<std::string> empty={".",".."},expected={".","..","alias","dir","file-é & name"};
    auto coherent=[&](MemoryFS& memory,uint64_t handle){
        std::vector<std::string> live,cached;assert(memory.entries("/",live)==0);
        assert(memory.directoryEntries(handle,cached)==0&&cached==live);
    };
    for(bool frozen:{false,true}){
        MemoryFS memory(16*1024*1024);memory.freeze(frozen);
        std::vector<uint64_t> handles(3);std::vector<std::string> names;
        for(auto invalid:{uint64_t(0),UINT64_MAX})assert(memory.checkHandle(invalid,true)==-EBADF&&memory.directoryEntries(invalid,names)==-EBADF);
        for(auto& handle:handles){assert(memory.openDirectory("/",handle)==0);assert(memory.directoryEntries(handle,names)==0&&names==empty);}
        uint64_t closed=0;assert(memory.openDirectory("/",closed)==0&&memory.close(closed)==0);
        assert(memory.checkHandle(closed,true)==-EBADF&&memory.directoryEntries(closed,names)==-EBADF);
        struct stat before{},after{},path{};assert(memory.stat("/",&before)==0);
        auto progress=memory.operationProgress();int populated=memory.populate(source.string());
        std::cout<<"ROOT_HANDLE_POPULATE initially_frozen="<<frozen<<" handles="<<handles.size()<<" result="<<populated<<std::endl;
        assert(populated==0&&memory.isFrozen()&&memory.operationProgress()>progress);
        assert(memory.entries("/",names)==0&&names==expected&&memory.stat("/",&path)==0&&path.st_ino==before.st_ino);
        for(auto handle:handles){
            assert(memory.checkHandle(handle,true)==0&&memory.checkHandle(handle)==-EBADF);
            assert(memory.stat("",&after,handle)==0&&after.st_ino==before.st_ino&&after.st_mode==path.st_mode);
            coherent(memory,handle);
        }
        assert(memory.directoryEntries(closed,names)==-EBADF);
        assert(memory.stat("/alias",&after)==0&&memory.stat("/file-é & name",&path)==0&&after.st_ino==path.st_ino);
        char bytes[13]{};assert(memory.read("/alias",bytes,sizeof bytes,0)==sizeof bytes&&!memcmp(bytes,"fixture bytes",sizeof bytes));
        assert(memory.create("/blocked",S_IFREG|0600)==-EBUSY&&memory.write("/alias","x",1,0)==-EBUSY);
        uint64_t later=0;assert(memory.openDirectory("/",later)==0&&later>closed);coherent(memory,later);
        progress=memory.operationProgress();assert(memory.populate(source.string())==-EBUSY&&memory.operationProgress()==progress);
        for(auto handle:handles)assert(memory.close(handle)==0);
        assert(memory.close(later)==0&&memory.checkHandle(later,true)==-EBADF);
    }
    // Namespace contents reject import even with no handle or only a benign root handle.
    for(mode_t mode:{S_IFREG,S_IFDIR,S_IFLNK})for(bool rootHandle:{false,true}){
        MemoryFS memory(16*1024*1024);uint64_t root=0;
        if(rootHandle)assert(memory.openDirectory("/",root)==0);
        if(mode==S_IFLNK)assert(memory.symlink("fixture target","/existing")==0);
        else assert(memory.create("/existing",mode|0700)==0);
        assert(memory.populate(source.string())==-EBUSY&&!memory.isFrozen()&&memory.operationProgress()==0);
        std::vector<std::string> names;assert(memory.entries("/",names)==0&&names==std::vector<std::string>({".","..","existing"}));
        if(rootHandle)assert(memory.close(root)==0);
    }
    // Detached, legitimate handles must still block an otherwise-empty namespace.
    for(bool frozen:{false,true})for(int kind=0;kind<5;kind++){
        MemoryFS memory(16*1024*1024);uint64_t root=0,handle=0;
        assert(memory.openDirectory("/",root)==0);
        if(kind<3){
            assert(memory.create("/detached",S_IFREG|0600)==0&&memory.write("/detached","kept",4,0)==4);
            const int flags[]={O_RDONLY,O_WRONLY,O_RDWR};assert(memory.open("/detached",handle,flags[kind])==0);
            assert(memory.remove("/detached")==0);
        }else{
            if(kind==3){assert(memory.create("/detached",S_IFDIR|0700)==0&&memory.openDirectory("/detached",handle)==0);}
            else assert(memory.create("/detached",S_IFDIR|0700,&handle,O_RDONLY)==0); // No directory snapshot: not an opendir handle.
            assert(memory.remove("/detached",true)==0);
        }
        struct stat before{},after{};assert(memory.stat("",&before,handle)==0);auto used=memory.used();memory.freeze(frozen);
        assert(memory.populate(source.string())==-EBUSY&&memory.isFrozen()==frozen&&memory.used()==used&&memory.operationProgress()==0);
        assert(memory.stat("",&after,handle)==0&&after.st_ino==before.st_ino);coherent(memory,root);
        if(kind==0){char bytes[4];assert(memory.read("",bytes,sizeof bytes,0,handle)==4&&!memcmp(bytes,"kept",4));}
        assert(memory.close(handle)==0&&memory.populate(source.string())==0);coherent(memory,root);assert(memory.close(root)==0);
    }
    // Failed imports keep the freeze guard, inode and a listing of the partial tree.
    for(bool frozen:{false,true})for(int failure=0;failure<4;failure++){
        MemoryFS memory(failure==3?pageSize:16*1024*1024);uint64_t root=0;assert(memory.openDirectory("/",root)==0);memory.freeze(frozen);
        struct stat before{},after{};assert(memory.stat("/",&before)==0);
        if(failure==1)memory.setImportReaderForTest(throwingReader);
        if(failure==2)memory.setImportReaderForTest(+[](int,void*,size_t)->ssize_t{throw std::bad_alloc();});
        const int errors[]={-ENOENT,-EIO,-ENOMEM,-ENOSPC};
        assert(memory.populate((failure==0?fixture/"missing":source).string())==errors[failure]&&memory.isFrozen());
        assert(memory.stat("",&after,root)==0&&after.st_ino==before.st_ino);coherent(memory,root);
        assert(memory.create("/blocked",S_IFREG|0600)==-EBUSY&&memory.close(root)==0);
    }
    // Invalidated snapshots still obey the metadata budget and recover after close.
    fs::path smallSource=fixture/"small-source";fs::create_directory(smallSource);{std::ofstream output(smallSource/"entry");}
    MemoryFS budget(65536);std::vector<uint64_t> handles;uint64_t handle=0;int result=0;
    while((result=budget.openDirectory("/",handle))==0)handles.push_back(handle);
    assert(result==-EMFILE&&!handles.empty()&&handles.size()<4096&&budget.populate(smallSource.string())==0);
    size_t failed=0;std::vector<std::string> names;
    for(;failed<handles.size();failed++){names={"unchanged"};result=budget.directoryEntries(handles[failed],names);if(result)break;assert(names==std::vector<std::string>({".","..","entry"}));}
    assert(failed>0&&failed<handles.size()&&result==-EMFILE&&names==std::vector<std::string>({"unchanged"}));
    assert(budget.close(handles[0])==0);coherent(budget,handles[failed]);
    for(size_t i=1;i<handles.size();i++)assert(budget.close(handles[i])==0);
    MemoryFS countLimit(16*1024*1024);handles.assign(4096,0);
    for(auto& root:handles)assert(countLimit.openDirectory("/",root)==0);
    assert(countLimit.openDirectory("/",handle)==-EMFILE&&countLimit.populate(smallSource.string())==0);
    assert(countLimit.openDirectory("/",handle)==-EMFILE);coherent(countLimit,handles.front());
    assert(countLimit.close(handles.back())==0&&countLimit.openDirectory("/",handle)==0&&handle>handles.back());
    handles.pop_back();for(auto root:handles)assert(countLimit.close(root)==0);assert(countLimit.close(handle)==0);
    std::cout<<"PASS root-handle populate: empty root opendir, refreshed snapshots, inode/handle identity, hardlinks, frozen writes/progress, namespace and detached-handle rejection, invalid/closed handles, failure/exception coherence, metadata and 4096-handle budgets; fixture "<<fixture<<"\n";
}
int main(){
    rootHandlePopulateScenarios(getenv("RAMNEST_TEST_ROOT")?getenv("RAMNEST_TEST_ROOT"):"/private/tmp");
    boundedStackScenarios(getenv("RAMNEST_TEST_ROOT")?getenv("RAMNEST_TEST_ROOT"):"/private/tmp");
    // Exercise the production quota arithmetic above 64 MiB without a huge tree.
    constexpr uint64_t gib=uint64_t(1)<<30, largeMetadata=110*1024*1024;
    static_assert(metadataBudget(0)==65536);
    static_assert(metadataBudget(16*1024*1024)==4*1024*1024);
    static_assert(metadataBudget(256*1024*1024)==64*1024*1024);
    static_assert(metadataBudget(512*1024*1024)==128*1024*1024);
    static_assert(metadataBudget(8*gib)==2*gib);
    static_assert(metadataBudget(UINT64_MAX)==UINT64_MAX/4);
    static_assert(metadataFits(8*gib,largeMetadata,2048));
    static_assert(!metadataFits(256*1024*1024,largeMetadata,0));
    static_assert(metadataFits(8*gib,2*gib-2048,2048));
    static_assert(!metadataFits(8*gib,2*gib-2048,2049));
    static_assert(!metadataFits(8*gib,0,UINT64_MAX));
    static_assert(!metadataFits(8*gib,UINT64_MAX,1));
    MemoryFS metadataOnly(65536);assert(metadataOnly.create("/seed",S_IFREG|0600)==0);
    int metadataResult=0,metadataCount=0;
    for(;metadataCount<1000;metadataCount++){metadataResult=metadataOnly.link("/seed","/alias-"+std::to_string(metadataCount));if(metadataResult)break;}
    assert(metadataCount>0&&metadataCount<1000&&metadataResult==-ENOSPC&&metadataOnly.used()==0);
    assert(metadataOnly.resize(1024*1024)==0);assert(metadataOnly.link("/seed","/after-resize")==0);
    std::cout<<"PASS metadata: capacity/4 with 64 KiB floor, >64 MiB charges at 8 GiB, exact boundary/overflow rejection, small-volume exhaustion and resize\n";
    MemoryFS f(pageSize*2);assert(f.used()==0);assert(f.create("/a",S_IFREG|0640)==0);assert(f.write("/a","hello",5,(pageSize+2))==5);assert(f.used()==pageSize);char b[10]{};assert(f.read("/a",b,7,pageSize)==7);assert(b[0]==0&&b[1]==0&&!memcmp(b+2,"hello",5));
    assert(f.write("/a","x",1,(pageSize*2))==1);assert(f.used()==(pageSize*2));assert(f.write("/a","x",1,0)==-ENOSPC);assert(f.resize(pageSize)==-ENOSPC);assert(f.truncate("/a",(pageSize+2))==0);assert(f.used()==0); // suffix removal leaves an all-zero page, normalized to a hole
    assert(f.truncate("/a",(pageSize*3))==0);assert(f.read("/a",b,5,(pageSize+2))==5);for(int i=0;i<5;i++)assert(b[i]==0);
    assert(f.link("/a","/b")==0);uint64_t h=0;assert(f.open("/a",h)==0);assert(f.remove("/a")==0);assert(f.remove("/b")==0);assert(f.used()==0);assert(f.write("", "z",1,0,h)==1);assert(f.close(h)==0);assert(f.used()==0);
    assert(f.resize(pageSize*4)==0);assert(f.create("/dir",S_IFDIR|0755)==0);assert(f.rename("/dir","/dir/nested")==-EINVAL);assert(f.symlink("../../outside","/dir/link")==0);std::string s;assert(f.readlink("/dir/link",s)==0&&s=="../../outside");assert(f.remove("/dir",true)==-ENOTEMPTY);assert(f.create("/bad/../escape",S_IFREG|0600)<0);
    assert(f.create("/x",S_IFREG|0600)==0);assert(f.write("/x","z",1,INT64_MAX)==-EFBIG);assert(f.write("/x","z",1,-1)==-EFBIG);assert(f.write("/x","abc",3,0)==3);assert(f.setxattr("/x","user.test","value",0)==0);assert(f.rename("/x","/dir/x")==0);assert(f.link("/dir/x","/hard")==0);
    f.freeze(true);assert(f.write("/hard","x",1,0)==-EBUSY);f.freeze(false);
    std::string base=getenv("RAMNEST_TEST_ROOT")?getenv("RAMNEST_TEST_ROOT"):"/private/tmp";std::filesystem::create_directories(base);std::string pattern=base+"/ramnest-memory-XXXXXX";auto tmp=mkdtemp(pattern.data());assert(tmp);std::string snapshot=std::string(tmp)+"/snapshot";assert(f.exportTree(snapshot)==0);MemoryFS copy(1024*1024);assert(copy.importTree(snapshot)==0);assert(copy.getxattr("/hard","user.test",s)==0&&s=="value");struct stat a{},c{};assert(copy.stat("/hard",&a)==0&&copy.stat("/dir/x",&c)==0&&a.st_ino==c.st_ino);memset(b,0,sizeof b);assert(copy.read("/hard",b,3,0)==3&&!memcmp(b,"abc",3));assert(f.exportTree(snapshot)<0); // existing destination fails closed
    assert(f.exportTree(std::string(tmp)+"/frozen",true)==0);assert(f.remove("/hard")==-EBUSY);f.freeze(false);
    MemoryFS parallel(64*1024*1024);std::vector<std::thread>threads;for(int i=0;i<8;i++)threads.emplace_back([&,i]{auto p="/"+std::to_string(i);assert(parallel.create(p,S_IFREG|0600)==0);for(int j=0;j<100;j++)assert(parallel.write(p,"x",1,j*pageSize)==1);assert(parallel.remove(p)==0);});for(auto&t:threads)t.join();assert(parallel.used()==0);std::filesystem::remove_all(tmp);
    std::cout<<"PASS memory: sparse offsets, overflow, ENOSPC, reclaim, resize, links, open-unlink, rename, symlink, xattrs, freeze, real export/import, failed export, concurrent writes\n";
}
