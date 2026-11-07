#define main ramnest_helper_entry
#include "Helper.cpp"
#undef main
#include <cassert>
#include <sys/xattr.h>
static int throwsAllocation(){throw std::bad_alloc();}
static int throwsIO(){throw std::runtime_error("failure");}
static int fillOne(void*buffer,const char*name,const struct stat*,off_t offset){auto*v=static_cast<std::vector<std::string>*>(buffer);v->push_back(name);assert(offset>0);return v->size()>=2?1:0;}
int main(){
    tree=std::make_unique<MemoryFS>(16*1024*1024);assert(!operations().renamex);auto ops=operations(false);assert(!ops.read_buf&&!ops.write_buf);assert(CallbackBoundary<throwsAllocation>::call()==-ENOMEM);assert(CallbackBoundary<throwsIO>::call()==-EIO);
    fuse_conn_info connection{};assert(ops.init(&connection)==nullptr&&mounted);
    auto fs=fuse_fs_new(&ops,sizeof ops,nullptr);assert(fs);fuse_file_info info{};info.flags=O_RDWR;
    assert(fuse_fs_create(fs,"/sentinel",0600,&info)==0);
    assert(fuse_fs_write(fs,"/sentinel","unsaved",7,0,&info)==7);char buffer[32]{};assert(fuse_fs_read(fs,"/sentinel",buffer,7,0,&info)==7&&!memcmp(buffer,"unsaved",7));
    assert(ops.setxattr("/sentinel","user.test","abc",3,XATTR_CREATE,0)==0);assert(ops.setxattr("/sentinel","user.test","abc",3,XATTR_CREATE,0)==-EEXIST);assert(ops.setxattr("/sentinel","user.absent","a",1,XATTR_REPLACE,0)==-ENOATTR);assert(ops.getxattr("/sentinel","user.test",buffer,2,0)==-ERANGE);assert(ops.getxattr("/sentinel","user.test",nullptr,0,0)==3);assert(ops.listxattr("/sentinel",buffer,1)==-ERANGE);
    assert(ops.setxattr("/sentinel","com.apple.ResourceFork","abc",3,0,0)==0);assert(ops.setxattr("/sentinel","com.apple.ResourceFork","z",1,0,5)==0);assert(ops.getxattr("/sentinel","com.apple.ResourceFork",buffer,sizeof buffer,3)==3&&buffer[0]==0&&buffer[1]==0&&buffer[2]=='z');assert(ops.setxattr("/sentinel","user.test","x",1,0,1)==-EINVAL);
    setattr_x attr{};attr.valid=1<<3;attr.size=3;assert(fuse_fs_fsetattr_x(fs,"/sentinel",&attr,&info)==0);assert(ops.unlink("/sentinel")==0);attr.size=1;assert(fuse_fs_fsetattr_x(fs,nullptr,&attr,&info)==0);struct stat st{};assert(ops.fgetattr(nullptr,&st,&info)==0&&st.st_size==1);assert(ops.release(nullptr,&info)==0);assert(ops.read(nullptr,buffer,1,0,&info)==-EBADF);
    assert(ops.mkdir("/dir",0755)==0);assert(ops.mknod("/device",S_IFCHR|0600,0)==-ENOTSUP);fuse_file_info directory{};assert(ops.opendir("/",&directory)==0);std::vector<std::string> names;assert(ops.readdir(nullptr,&names,fillOne,0,&directory)==0&&names.size()==2);names.clear();assert(ops.readdir(nullptr,&names,fillOne,2,&directory)==0&&!names.empty()&&names[0]=="dir");assert(ops.fsyncdir(nullptr,0,&directory)==0);assert(ops.releasedir(nullptr,&directory)==0);
    fuse_file_info a{};a.flags=O_RDWR|O_APPEND;assert(ops.create("/a",0600,&a)==0);assert(ops.write("/a","one",3,99,&a)==3);assert(ops.write("/a","two",3,0,&a)==3);assert(ops.read("/a",buffer,6,0,&a)==6&&!memcmp(buffer,"onetwo",6));assert(ops.flush("/a",&a)==0&&ops.fsync("/a",0,&a)==0);
    assert(ops.link("/a","/alias")==0);assert(ops.getattr("/a",&st)==0&&st.st_nlink==2);assert(ops.chmod("/a",0640)==0);assert(ops.chown("/a",getuid(),getgid())==0&&ops.chown("/a",getuid()+1,getgid())==-EPERM);assert(ops.access("/a",R_OK|W_OK)==0);assert(ops.access("/a",X_OK)==-EACCES);
    timespec times[2]={{0,UTIME_OMIT},{0,UTIME_NOW}};assert(ops.utimens("/a",times)==0);timespec birth{1234,56},backup{4567,89},change{2222,33},gotBirth{},gotBackup{};assert(ops.setcrtime("/a",&birth)==0&&ops.setbkuptime("/a",&backup)==0&&ops.setchgtime("/a",&change)==0);assert(ops.getxtimes("/a",&gotBackup,&gotBirth)==0&&gotBirth.tv_sec==1234&&gotBackup.tv_sec==4567);
    assert(ops.symlink("../../outside","/symlink")==0&&ops.readlink("/symlink",buffer,sizeof buffer)==0&&!strcmp(buffer,"../../outside"));
    assert(ops.mknod("/b",S_IFREG|0600,0)==0);assert(ops.renamex("/a","/b",RENAME_EXCL)==-EEXIST);auto oldInode=st.st_ino;assert(ops.renamex("/a","/b",RENAME_SWAP)==0);assert(ops.getattr("/b",&st)==0&&st.st_ino==oldInode);assert(ops.getattr("/alias",&st)==0&&st.st_ino==oldInode);assert(ops.rename("/b","/renamed")==0);assert(ops.release(nullptr,&a)==0);
    struct statvfs vfs{};assert(ops.statfs("/",&vfs)==0&&vfs.f_blocks*ramnest::pageSize==16*1024*1024);struct statfs extended{};assert(ops.statfs_x("/",&extended)==0);
    assert(ops.bmap("/a",4096,nullptr)==-ENOTSUP);assert(ops.ioctl("/a",0,nullptr,nullptr,0,nullptr)==-ENOTSUP);assert(ops.poll("/a",nullptr,nullptr,nullptr)==-ENOTSUP);assert(ops.lock("/a",nullptr,0,nullptr)==-ENOTSUP);assert(ops.flock("/a",nullptr,0)==-ENOTSUP);assert(ops.fallocate("/a",0,0,1,nullptr)==-ENOTSUP);assert(ops.setvolname("New")==-ENOTSUP);
    assert(ops.create("/quota",0600,&info)==0);assert(ops.write("/quota","keep",4,0,&info)==4);int result=0,count=0;for(;count<50000;count++){auto name="/long-link-"+std::to_string(count)+std::string(180,'x');result=ops.link("/quota",name.c_str());if(result)break;}assert(result==-ENOSPC);assert(ops.opendir("/",&directory)==-EMFILE);assert(ops.read("/quota",buffer,4,0,&info)==4&&!memcmp(buffer,"keep",4));
    assert(ops.chflags("/quota",UF_IMMUTABLE)==-ENOTSUP);assert(ops.chflags("/quota",UF_APPEND)==-ENOTSUP);assert(ops.exchange("/quota","/dir",0)==-ENOTSUP);
    tree->freeze(true);assert(ops.mkdir("/new",0700)==-EBUSY);assert(ops.chmod("/quota",0600)==-EBUSY);assert(ops.chown("/quota",getuid(),getgid())==-EBUSY);assert(ops.unlink("/quota")==-EBUSY);assert(ops.rename("/quota","/other")==-EBUSY);assert(ops.setxattr("/quota","user.x","x",1,0,0)==-EBUSY);assert(ops.chflags("/quota",0)==-EBUSY);assert(ops.setvolname("New")==-EBUSY);
    fuse_fs_destroy(fs);std::cout<<"PASS callbacks: real libfuse read/write and extended-setattr dispatch, unlinked ftruncate, exception boundaries, xattr flags/offsets/ERANGE, directory offsets, metadata quota sentinel, freeze, honest unsupported flags/exchange\n";
    return 0;
}
