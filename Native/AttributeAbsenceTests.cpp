#define main ramnest_helper_entry
#include "Helper.cpp"
#undef main
#include <cassert>
#include <sys/xattr.h>

static bool failAllocation=false;
void* operator new(std::size_t size){
    if(failAllocation)throw std::bad_alloc();
    if(auto p=std::malloc(size?size:1))return p;
    throw std::bad_alloc();
}
void operator delete(void* p)noexcept{std::free(p);}

int main(){
    tree=std::make_unique<MemoryFS>(16*1024*1024);
    assert(tree->create("/file",S_IFREG|0600)==0);
    assert(tree->create("/directory",S_IFDIR|0700)==0);
    const auto before=tree->metrics();
    const auto used=tree->used();
    int failures=0;
    for(const auto backend:{"fskit","nfs","smb"}){
        auto ops=backendOperations(backend);
        assert(!ops.renamex); // backend selection must not enable legacy renamex.
        const int absent=std::string(backend)=="fskit"?-ENOATTR:0;
        for(const auto path:{"/file","/directory"}){
            for(const size_t size:{size_t(0),size_t(8)}){
                char buffer[8];memset(buffer,0x5a,sizeof buffer);
                const int result=ops.listxattr(path,size?buffer:nullptr,size);
                if(result!=absent){std::cerr<<"FAIL "<<backend<<" empty "<<path<<" size "<<size<<": got "<<result<<", expected "<<absent<<"\n";failures++;}
                for(char byte:buffer)assert(byte==0x5a);
            }
            std::string names="unchanged";
            assert(tree->listxattr(path,names)==0&&names.empty());
            struct stat st{};assert(tree->stat(path,&st)==0&&st.st_size==0);
        }
        assert(ops.listxattr("/missing",nullptr,0)==-ENOENT);
        // Path conversion allocates inside lx. Its exception boundary must survive
        // both the original and FSKit callback, with no absence translation.
        const std::string longPath="/"+std::string(100,'x');
        failAllocation=true;
        const int fault=ops.listxattr(longPath.c_str(),nullptr,0);
        failAllocation=false;
        assert(fault==-ENOMEM);
    }
    const auto after=tree->metrics();
    assert(used==tree->used()&&before.logical==after.logical&&before.content==after.content&&before.payload==after.payload&&before.mapped==after.mapped);
    assert(tree->setxattrAt("/file","user.fixture","abc",0,0)==0);
    const std::string expected("user.fixture\0",13);
    for(const auto backend:{"fskit","nfs","smb"}){
        auto ops=backendOperations(backend);
        assert(ops.listxattr("/file",nullptr,0)==int(expected.size()));
        char buffer[64];memset(buffer,0x5a,sizeof buffer);
        assert(ops.listxattr("/file",buffer,1)==-ERANGE&&buffer[0]==0x5a);
        assert(ops.listxattr("/file",buffer,sizeof buffer)==int(expected.size()));
        assert(!memcmp(buffer,expected.data(),expected.size())&&buffer[expected.size()]==0x5a);
    }
    if(failures)return 1;
    std::cout<<"PASS: FSKit explicit ENOATTR, NFS/SMB zero, file/directory, untouched buffers/storage, nonempty bytes, ERANGE, ENOENT and allocation fault\n";
}
