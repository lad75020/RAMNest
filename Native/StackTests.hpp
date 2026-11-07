// Run import/export and block scratch paths on the same small worker stack that
// reproduced the installed helper's SIGBUS. All payload buffers live on the heap.
#include <fstream>
#include <pthread.h>
#include <sys/xattr.h>
struct StackJob {std::string source,destination,leaf;bool compression;};
static ssize_t throwingReader(int,void*,size_t){throw std::runtime_error("injected read exception");}
static ssize_t throwingWriter(int,const void*,size_t,off_t){throw std::bad_alloc();}
static void* boundedStackWorker(void* raw){
    auto& job=*static_cast<StackJob*>(raw);
    std::cout<<"BOUNDED_WORKER_STACK_BYTES "<<pthread_get_stacksize_np(pthread_self())<<"\n";
    auto sourceDirectory=std::filesystem::path(job.source)/std::filesystem::path(job.leaf).parent_path();
    struct stat directoryBefore{};assert(::lstat(sourceDirectory.c_str(),&directoryBefore)==0);
    MemoryFS memory(16*1024*1024,job.compression);
    assert(memory.populate(job.source)==0&&memory.isFrozen());
    const std::string path="/"+job.leaf;
    std::vector<char> bytes(pageSize,'A'),actual(pageSize);
    assert(memory.read(path,actual.data(),actual.size(),0)==int(actual.size())&&actual==bytes);
    auto metrics=memory.metrics();assert(metrics.content==6*pageSize+3&&metrics.logical>=2*pageSize);
    assert(metrics.mapped==(job.compression?vmPageSize+pageSize:2*pageSize));
    assert(memory.exportTree(job.destination)==0&&memory.isFrozen());
    struct stat directoryAfter{};
    auto exportedDirectory=std::filesystem::path(job.destination)/std::filesystem::path(job.leaf).parent_path();
    assert(::lstat(exportedDirectory.c_str(),&directoryAfter)==0);
    assert(directoryAfter.st_mode==directoryBefore.st_mode&&directoryAfter.st_flags==directoryBefore.st_flags);
    assert(directoryAfter.st_mtimespec.tv_sec==directoryBefore.st_mtimespec.tv_sec&&directoryAfter.st_mtimespec.tv_nsec==directoryBefore.st_mtimespec.tv_nsec);
    MemoryFS restored(16*1024*1024,job.compression);assert(restored.importTree(job.destination)==0);
    assert(restored.read(path,actual.data(),actual.size(),0)==int(actual.size())&&actual==bytes);
    struct stat a{},b{};assert(restored.stat(path,&a)==0&&restored.stat("/hardlink",&b)==0&&a.st_ino==b.st_ino);
    assert(a.st_flags==(UF_HIDDEN|UF_NODUMP));std::string value;
    assert(restored.getxattr(path,"user.stack",value)==0&&value=="metadata");
    assert(restored.readlink(path+"-link",value)==0&&value=="leaf");
    std::ifstream randomInput(std::filesystem::path(job.source)/"random",std::ios::binary);
    std::string random(std::istreambuf_iterator<char>(randomInput),{});
    assert(restored.read("/random",actual.data(),actual.size(),0)==int(actual.size()));
    assert(std::equal(actual.begin(),actual.end(),random.begin(),random.end()));
    assert(restored.stat("/sparse",&a)==0&&a.st_size==int64_t(4*pageSize+3)&&a.st_blocks==0);
    assert(restored.read("/sparse",actual.data(),actual.size(),pageSize)==int(actual.size()));
    assert(std::all_of(actual.begin(),actual.end(),[](char c){return c==0;}));
    // Exercise write/encode, partial-block truncate/decode and zero regrowth on
    // the bounded stack as well, with every original block verified on export.
    memory.freeze(false);assert(memory.write(path,"patch",5,123)==5);
    assert(memory.truncate(path,129)==0&&memory.truncate(path,pageSize)==0);
    assert(memory.read(path,actual.data(),actual.size(),0)==int(actual.size()));
    assert(std::string(actual.data()+123,5)=="patch");
    assert(std::all_of(actual.begin()+129,actual.end(),[](char c){return c==0;}));
    assert(memory.exportTree(job.destination+"-quiesced",true)==0&&memory.isFrozen());
    memory.freeze(false);memory.setExportWriterForTest(throwingWriter);
    assert(memory.exportTree(job.destination+"-exception",true)==-ENOMEM&&!memory.isFrozen());
    memory.freeze(true);assert(memory.exportTree(job.destination+"-frozen-exception")==-ENOMEM&&memory.isFrozen());
    MemoryFS failed(16*1024*1024);failed.setImportReaderForTest(throwingReader);
    assert(failed.populate(job.source)==-EIO&&failed.isFrozen());
    MemoryFS limited(pageSize);assert(limited.populate(job.source)==-ENOSPC&&limited.isFrozen());
    assert(memory.read(path,actual.data(),actual.size(),0)==int(actual.size()));
    assert(std::string(actual.data()+123,5)=="patch"); // Failed exports kept the RAM tree.
    return nullptr;
}
static void boundedStackScenarios(const std::string& base){
    namespace fs=std::filesystem;
    fs::create_directories(base);std::string pattern=base+"/ramnest-stack-XXXXXX";
    auto directory=mkdtemp(pattern.data());assert(directory);fs::path root=directory,source=root/"source",nested=source;
    fs::create_directory(source);std::string leaf;
    for(int i=0;i<64;i++){nested/="d";leaf+="d/";fs::create_directory(nested);}leaf+="leaf";
    {std::ofstream output(nested/"leaf",std::ios::binary);output<<std::string(pageSize,'A');}
    {std::vector<char> random(pageSize);arc4random_buf(random.data(),random.size());std::ofstream output(source/"random",std::ios::binary);output.write(random.data(),random.size());}
    {std::ofstream output(source/"sparse",std::ios::binary);output.seekp(4*pageSize+2);output.put(0);}
    assert(::link((nested/"leaf").c_str(),(source/"hardlink").c_str())==0);
    assert(::symlink("leaf",(nested/"leaf-link").c_str())==0);
    assert(::setxattr((nested/"leaf").c_str(),"user.stack","metadata",8,0,XATTR_NOFOLLOW)==0);
    assert(::lchflags((nested/"leaf").c_str(),UF_HIDDEN|UF_NODUMP)==0);
    assert(::chmod(nested.c_str(),0550)==0);
    assert(::lchflags(nested.c_str(),UF_HIDDEN|UF_NODUMP)==0);
    timespec timestamp[2]={{1234567890,123456},{1234567890,654321}};
    assert(::utimensat(AT_FDCWD,nested.c_str(),timestamp,0)==0);
    for(bool compression:{true,false}){
        StackJob job{source.string(),(root/(compression?"compressed":"raw")).string(),leaf,compression};
        pthread_attr_t attr;assert(pthread_attr_init(&attr)==0);assert(pthread_attr_setstacksize(&attr,512*1024)==0);
        pthread_t thread;assert(pthread_create(&thread,&attr,boundedStackWorker,&job)==0);
        pthread_attr_destroy(&attr);assert(pthread_join(thread,nullptr)==0);
    }
    std::cout<<"PASS bounded stack: 64-level populate/export, compressed/raw content readback, hardlinks, symlinks, xattrs/flags, sparse zeros, patch/truncate, exception freeze restoration, ENOSPC; fixture "<<root<<"\n";
}
