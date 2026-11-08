#include "MemoryFS.hpp"
#include "DebugProfile.hpp"
#include <fuse.h>
#include <fuse_opt.h>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <condition_variable>
#include <climits>
#include <cstring>
#include <cstdlib>
#include <fcntl.h>
#include <future>
#include <iostream>
#include <poll.h>
#include <spawn.h>
#include <stdexcept>
#include <sys/socket.h>
#include <sys/event.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <thread>
#include <unistd.h>
#include <uuid/uuid.h>
extern char **environ;
using ramnest::MemoryFS;
static std::unique_ptr<MemoryFS> tree;
static std::atomic<bool> mounted=false, stopped=false, populated=false, activated=false;
static std::atomic<int> interval=0;
#ifdef RAMNEST_DEBUG_PROFILING
static std::string profileBackend="nfs";
static bool profileCompression=true;
#endif
static const std::string helperIncarnation=[] {uuid_t bytes;char text[37];uuid_generate_random(bytes);uuid_unparse_lower(bytes,text);return std::string(text);}();
static std::string identifier, volume, mountpoint, socketPath, cliPath, storePath, sourcePath;
static constexpr const char* startupVersion="pre-mount-population-v1";
// Independent of the tree/mutation locks: status and owner-death cancellation
// must remain responsive throughout a progress-aware import.
struct GuardedStartup {
    std::mutex mutex;
    std::condition_variable changed;
    bool enabled=false, importing=false, imported=false, requested=false;
    bool abandoned=false, entered=false, returned=false, ownerDead=false;
    pid_t owner=0;
    fuse* connection=nullptr;
    std::chrono::steady_clock::time_point deadline;
    static constexpr auto controlWait=std::chrono::seconds(15);
    void abandon(){abandoned=true;changed.notify_all();}
    void ownerExited(){
        std::lock_guard lock(mutex);ownerDead=true;
        // An exit notification may be delivered across init(). Until durable
        // Core verification has led to activation, close the FUSE loop normally
        // even if init has just published mounted=true. Never leave an orphan
        // automatically mounting after its startup coordinator has gone away.
        if(!activated){abandon();if(connection)fuse_exit(connection);}
    }
    bool beginImport(){
        std::lock_guard lock(mutex);
        if(!enabled)return mounted&&!populated;
        if(abandoned||entered||importing||imported||stopped)return false;
        importing=true;changed.notify_all();return true;
    }
    void finishImport(bool success){
        std::lock_guard lock(mutex);
        if(!enabled)return;
        importing=false;imported=success;
        if(!success)abandon();
        deadline=std::chrono::steady_clock::now()+controlWait;changed.notify_all();
    }
    bool awaitMount(){
        std::unique_lock lock(mutex);
        while(!stopped&&!abandoned&&!ownerDead&&!requested){
            if(importing)changed.wait(lock,[&]{return stopped||abandoned||ownerDead||!importing;});
            // wait_until reacquires mutex before returning: an accepted import,
            // renewed mount budget or mount request may already own the gate.
            // Only the current idle deadline authorizes abandonment.
            else if(changed.wait_until(lock,deadline)==std::cv_status::timeout
                    &&!stopped&&!abandoned&&!ownerDead&&!importing&&!requested
                    &&std::chrono::steady_clock::now()>=deadline)abandon();
        }
        if(stopped||abandoned||ownerDead)return false;
        entered=true;return true;
    }
};
static GuardedStartup startup;
static int ga(const char*p,struct stat*s){return tree->stat(p,s);}
static int rd(const char*p,void*b,fuse_fill_dir_t fill,off_t offset,struct fuse_file_info*f){
    if(offset<0)return -EINVAL;std::shared_ptr<const std::vector<std::string>> snapshot;
    if(f&&f->fh){int e=tree->directorySnapshot(f->fh,snapshot);if(e)return e;}
    else{auto names=std::make_shared<std::vector<std::string>>();int e=tree->entries(p,*names);if(e)return e;snapshot=names;}
    for(size_t i=size_t(offset);i<snapshot->size();i++)if(fill(b,(*snapshot)[i].c_str(),nullptr,off_t(i+1)))break;return 0;
}
static int cr(const char*p,mode_t m,struct fuse_file_info*f){f->direct_io=1;return tree->create(p,S_IFREG|m,&f->fh,f->flags);}
static int mk(const char*p,mode_t m){return tree->create(p,S_IFDIR|m);}
static int mn(const char*p,mode_t m,dev_t){return S_ISREG(m)?tree->create(p,m):-ENOTSUP;}
static int op(const char*p,struct fuse_file_info*f){int e=tree->open(p,f->fh,f->flags);f->direct_io=1;return e;}
static int rel(const char*,struct fuse_file_info*f){return tree->close(f->fh);}
static int readFile(const char*p,char*b,size_t n,off_t o,struct fuse_file_info*f){
#ifdef RAMNEST_DEBUG_PROFILING
    ramnest::profile::Scope scope(ramnest::profile::Metric::callback_read,n);
    int result;try{result=tree->read(p?p:"",b,n,o,f?f->fh:0);}catch(const std::bad_alloc&){result=-ENOMEM;}catch(...){result=-EIO;}
    scope.result(result);return result;
#else
    return tree->read(p?p:"",b,n,o,f?f->fh:0);
#endif
}
static int writeFile(const char*p,const char*b,size_t n,off_t o,struct fuse_file_info*f){
#ifdef RAMNEST_DEBUG_PROFILING
    ramnest::profile::Scope scope(ramnest::profile::Metric::callback_write,n);
    int result;try{result=tree->write(p?p:"",b,n,o,f?f->fh:0);}catch(const std::bad_alloc&){result=-ENOMEM;}catch(...){result=-EIO;}
    scope.result(result);return result;
#else
    try{return tree->write(p?p:"",b,n,o,f?f->fh:0);}catch(const std::bad_alloc&){return -ENOMEM;}
#endif
}
static int tr(const char*p,off_t s){return tree->truncate(p,s);}
static int ftr(const char*p,off_t s,struct fuse_file_info*f){return tree->truncate(p?p:"",s,f?f->fh:0);}
static int fga(const char*p,struct stat*s,struct fuse_file_info*f){return tree->stat(p?p:"",s,f?f->fh:0);}
static int ul(const char*p){return tree->remove(p);}
static int rmd(const char*p){return tree->remove(p,true);}
static int rn(const char*a,const char*b){return tree->rename(a,b);}
static int ln(const char*a,const char*b){return tree->link(a,b);}
static int sl(const char*a,const char*b){return tree->symlink(a,b);}
static int rsl(const char*p,char*b,size_t n){std::string v;int e=tree->readlink(p,v);if(e)return e;if(n){strncpy(b,v.c_str(),n-1);b[n-1]=0;}return 0;}
static int cm(const char*p,mode_t m){return tree->chmod(p,m);}
static int co(const char*p,uid_t u,gid_t g){return tree->chown(p,u,g);}
static int tm(const char*p,const timespec t[2]){return tree->times(p,t);}
static int stfs(const char*,struct statvfs*s){tree->statfs(s);return 0;}
static int sx(const char*p,const char*k,const char*v,size_t n,int f,uint32_t pos){if(n>1024*1024)return -E2BIG;return tree->setxattrAt(p,k,std::string(v,n),f,pos);}
static int gx(const char*p,const char*k,char*b,size_t n,uint32_t pos){std::string v;int e=tree->getxattrAt(p,k,v,pos);if(e)return e;if(!n)return int(v.size());if(n<v.size())return -ERANGE;memcpy(b,v.data(),v.size());return int(v.size());}
static int lx(const char*p,char*b,size_t n){std::string v;int e=tree->listxattr(p,v);if(e)return e;if(!n)return int(v.size());if(n<v.size())return -ERANGE;memcpy(b,v.data(),v.size());return int(v.size());}
// FUSE-T FSKit turns a successful zero-byte list into persistent Darwin EIO.
// Preserve explicit absence instead; never synthesize names or change core metadata.
static int lxFSKit(const char*p,char*b,size_t n){const int result=lx(p,b,n);return result==0?-ENOATTR:result;}
static int rx(const char*p,const char*k){return tree->removexattr(p,k);}
static int flush(const char*,struct fuse_file_info*f){return f?tree->checkHandle(f->fh): -EBADF;}
static int syncFile(const char*,int,struct fuse_file_info*f){return f?tree->checkHandle(f->fh): -EBADF;}
static void* init(fuse_conn_info*){
    std::lock_guard lock(startup.mutex);
    if(startup.enabled){
        startup.connection=fuse_get_context()->fuse;
        if(startup.ownerDead){fuse_exit(startup.connection);return nullptr;}
    }
    mounted=true;return nullptr;
}
static void destroy(void*){std::lock_guard lock(startup.mutex);startup.connection=nullptr;mounted=false;}
static int od(const char*p,struct fuse_file_info*f){return tree->openDirectory(p,f->fh);}
static int rdir(const char*,struct fuse_file_info*f){int e=tree->checkHandle(f->fh,true);return e?e:tree->close(f->fh);}
static int fdir(const char*,int,struct fuse_file_info*f){return tree->checkHandle(f->fh,true);}
static int ac(const char*p,int m){return tree->access(p,m);}
static int bm(const char*,size_t,uint64_t*){return -ENOTSUP;}
static int io(const char*,int,void*,struct fuse_file_info*,unsigned,void*){return -ENOTSUP;}
static int po(const char*,struct fuse_file_info*,struct fuse_pollhandle*ph,unsigned*){if(ph)fuse_pollhandle_destroy(ph);return -ENOTSUP;}
static int lk(const char*,struct fuse_file_info*,int,struct flock*){return -ENOTSUP;}
static int fl(const char*,struct fuse_file_info*,int){return -ENOTSUP;}
static int fa(const char*,int,off_t,off_t,struct fuse_file_info*){return -ENOTSUP;}
static int rnx(const char*a,const char*b,unsigned f){if(f==0)return tree->rename(a,b);if(f==RENAME_EXCL)return tree->renameExclusive(a,b);if(f==RENAME_SWAP)return tree->exchange(a,b);return -ENOTSUP;}
static int svn(const char*){return tree->isFrozen()?-EBUSY:-ENOTSUP;}
static int ex(const char*,const char*,unsigned long){return -ENOTSUP;}
static int gxt(const char*p,timespec*b,timespec*c){return tree->extraTimes(p,b,c,nullptr,false);}
static int sbt(const char*p,const timespec*t){auto v=*t;return tree->extraTimes(p,&v,nullptr,nullptr,true);}
static int sct(const char*p,const timespec*t){auto v=*t;return tree->extraTimes(p,nullptr,nullptr,&v,true);}
static int scr(const char*p,const timespec*t){auto v=*t;return tree->extraTimes(p,nullptr,&v,nullptr,true);}
static int cf(const char*p,uint32_t f){return tree->flags(p,f);}
static int sfx(const char*,struct statfs*s){struct statvfs v;tree->statfs(&v);memset(s,0,sizeof(*s));s->f_bsize=ramnest::pageSize;s->f_iosize=ramnest::pageSize;s->f_blocks=v.f_blocks;s->f_bfree=v.f_bfree;s->f_bavail=v.f_bavail;s->f_files=v.f_files;s->f_ffree=v.f_ffree;strlcpy(s->f_fstypename,"ramnest",sizeof s->f_fstypename);strlcpy(s->f_mntonname,mountpoint.c_str(),sizeof s->f_mntonname);return 0;}
static ramnest::Attributes attributes(const struct setattr_x*a){ramnest::Attributes v;v.valid=uint32_t(a->valid);v.mode=a->mode;v.uid=a->uid;v.gid=a->gid;v.size=a->size;v.access=a->acctime;v.modify=a->modtime;v.birth=a->crtime;v.change=a->chgtime;v.backup=a->bkuptime;v.flags=a->flags;return v;}
static int sax(const char*p,struct setattr_x*a){return tree->setattr(p?p:"",attributes(a));}
static int fsax(const char*p,struct setattr_x*a,struct fuse_file_info*f){return tree->setattr(p?p:"",attributes(a),f?f->fh:0);}
static int child(const std::vector<std::string>&args){
    std::vector<char*>v;for(auto&s:args)v.push_back(const_cast<char*>(s.c_str()));v.push_back(nullptr);pid_t pid;
    posix_spawn_file_actions_t actions;posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions,0,"/dev/null",O_RDONLY,0);
    posix_spawn_file_actions_addopen(&actions,1,"/dev/null",O_WRONLY,0);
    posix_spawn_file_actions_addopen(&actions,2,"/dev/null",O_WRONLY,0);
    posix_spawnattr_t attr;posix_spawnattr_init(&attr);posix_spawnattr_setflags(&attr,POSIX_SPAWN_CLOEXEC_DEFAULT);
    int e=posix_spawn(&pid,v[0],&actions,&attr,v.data(),environ);posix_spawnattr_destroy(&attr);posix_spawn_file_actions_destroy(&actions);if(e)return e;
    int status=0;while(waitpid(pid,&status,0)<0){if(errno!=EINTR)return errno;}return WIFEXITED(status)?WEXITSTATUS(status):1;
}
static std::mutex mutationQueue;
static std::string command(const std::string& input,pid_t peer=0){
    auto split=input.find('\t');auto cmd=input.substr(0,split);auto arg=split==std::string::npos?"":input.substr(split+1);
#ifdef RAMNEST_DEBUG_PROFILING
    if(cmd=="profile-begin"||cmd=="profile-end"||cmd=="profile-snapshot"||cmd=="profile-release"){
        if(cmd=="profile-release"){
            auto delimiter=arg.find('\t');auto run=arg.substr(0,delimiter);
            if(!ramnest::profile::validUUID(run))return "ERR\t22";
            struct stat observed{};const int result=tree->stat("/.ramnest-debug-io-"+run,&observed);
            if(result!=-ENOENT)return "ERR\t16";
        }
        return ramnest::profile::command(cmd,arg,profileBackend,profileCompression,interval,mounted&&activated);
    }
#endif
    if(cmd=="metrics"){auto m=tree->metrics();return "OK\t"+std::to_string(m.logical)+"\t"+std::to_string(m.content)+"\t"+std::to_string(m.payload)+"\t"+std::to_string(m.mapped);}
    if(cmd=="status")return "OK\t"+identifier+"\t"+std::to_string(getpid())+"\t"+(mounted?"mounted":"retained")+"\t"+std::to_string(tree->used())+"\t"+std::to_string(tree->limit())+"\t"+(activated?"active":"guarded");
    if(cmd=="checkpoint-status"){auto [generation,frozen]=tree->checkpointState();return "OK\t"+helperIncarnation+"\t"+std::to_string(generation)+"\t"+(frozen?"frozen":"writable");}
    if(cmd=="capabilities")return "OK\tincremental-v1\tprivate-storage-v2\ttrash-directory-exclusion-v1\tpre-mount-population-v1"
#ifdef RAMNEST_DEBUG_PROFILING
        "\tdebug-io-profile-v2\tdebug-benchmark-reservation-v1"
#endif
        ;
    if(cmd=="startup-status"||cmd=="abort-startup"||cmd=="mount-populated"){
        std::lock_guard lock(startup.mutex);
        if(!arg.empty()||!startup.enabled)return "ERR\t22";
        if(cmd=="startup-status")return std::string("OK\t")+startupVersion+"\t"+(startup.abandoned?"retained":startup.entered?"mounting":startup.importing?"importing":startup.imported?"populated":"waiting");
        if(cmd=="abort-startup"){
            if((startup.entered&&!startup.returned)||mounted||activated)return "ERR\t16";
            startup.abandon();return std::string("OK\t")+startupVersion+"\tretained";
        }
        if(peer!=startup.owner||startup.ownerDead||startup.abandoned||!startup.imported||!populated||startup.entered||startup.requested)return "ERR\t16";
        startup.requested=true;startup.changed.notify_all();
        return std::string("OK\t")+startupVersion+"\tmount-requested";
    }
    std::lock_guard mutationGuard(mutationQueue);
#ifdef RAMNEST_DEBUG_PROFILING
    std::unique_lock<std::mutex> profileCheckpointGuard;
    if(cmd=="export"||cmd=="quiesce"||cmd=="export2"||cmd=="quiesce2"||cmd=="export3"||cmd=="quiesce3"){
        profileCheckpointGuard=std::unique_lock(ramnest::profile::controlMutex);
        if(!ramnest::profile::fixtureRun.empty())return "ERR\t16";
    }
#endif
    if(cmd=="export2"||cmd=="quiesce2"||cmd=="export3"||cmd=="quiesce3"){
        auto delimiter=arg.find('\t');auto stage=arg.substr(0,delimiter);
        std::string previous;uint64_t token=0;
        if(delimiter!=std::string::npos){auto rest=arg.substr(delimiter+1);auto tokenAt=rest.find('\t');if(tokenAt==std::string::npos)return "ERR\t22";previous=rest.substr(0,tokenAt);try{token=std::stoull(rest.substr(tokenAt+1));}catch(...){return "ERR\t22";}}
        auto prefix=volume+"/stage-";
        if(!stage.starts_with(prefix)||stage.find('/',prefix.size())!=std::string::npos||stage.find("..")!=std::string::npos)return "ERR\t1";
        if(!previous.empty()&&(!previous.starts_with(volume+"/revisions/")||previous.find("..")!=std::string::npos||!previous.ends_with("/data")))return "ERR\t1";
        int e=tree->exportTree(stage,cmd=="quiesce2"||cmd=="quiesce3",previous,token,cmd=="export3"||cmd=="quiesce3");if(e)return "ERR\t"+std::to_string(-e);
        auto stats=tree->lastExportStats();return "OK\t"+std::to_string(stats.generation)+"\t"+(stats.reused?"reused":"exported")+"\t"+std::to_string(stats.written)+"\t"+std::to_string(stats.clonedFiles)+"\t"+helperIncarnation+((cmd=="export3"||cmd=="quiesce3")?"\t"+stats.modeMapDigest:"");
    }
    if(cmd=="populate"||cmd=="populate2"){
        if(cmd=="populate2"&&(arg.size()!=64||!std::all_of(arg.begin(),arg.end(),[](unsigned char c){return (c>='0'&&c<='9')||(c>='a'&&c<='f');})))return "ERR\t22";
        if(cmd=="populate"&&!arg.empty())return "ERR\t22";
        if(startup.enabled&&peer!=startup.owner)return "ERR\t1";
        if(!startup.beginImport())return "ERR\t16";
        int e;
        try{e=tree->populate(sourcePath,cmd=="populate2"?arg:"");}
        catch(...){startup.finishImport(false);throw;}
        if(!e)populated=true;
        startup.finishImport(e==0);
        return e?"ERR\t"+std::to_string(-e):"OK";
    }
    if(cmd=="activate"){
        std::lock_guard lock(startup.mutex);
        if(!mounted||!populated||(startup.enabled&&(startup.ownerDead||startup.abandoned||!startup.entered)))return "ERR\t16";
        activated=true;tree->freeze(false);return "OK";
    }
    if(cmd=="resize"){try{auto n=std::stoull(arg);int e=tree->resize(n);return e?"ERR\t"+std::to_string(-e):"OK";}catch(...){return "ERR\t22";}}
    if(cmd=="period"){try{
        const int next=std::stoi(arg);
#ifdef RAMNEST_DEBUG_PROFILING
        std::lock_guard lock(ramnest::profile::controlMutex);
        if(next>0&&!ramnest::profile::fixtureRun.empty())return "ERR\t16";
#endif
        interval=next;return "OK";
    }catch(...){return "ERR\t22";}}
    // Temporary eject must stop writers without exporting volatile payloads.
    if(cmd=="freeze"){if(!arg.empty())return "ERR\t22";if(!activated)return "ERR\t16";tree->freeze(true);return "OK";}
    if(cmd=="thaw"){if(!activated)return "ERR\t16";tree->freeze(false);return "OK";}
    if(cmd=="retire"){
        std::lock_guard lock(startup.mutex);
        if(mounted||(startup.enabled&&startup.entered&&!startup.returned))return "ERR\t16";
        startup.abandon();stopped=true;startup.changed.notify_all();return "OK";
    }
    if(cmd=="export"||cmd=="quiesce"){
        // Export destinations are direct, new children of this volume's private directory.
        auto prefix=volume+"/stage-";if(!arg.starts_with(prefix)||arg.find('/',prefix.size())!=std::string::npos||arg.find("..")!=std::string::npos)return "ERR\t1";
        int e=tree->exportTree(arg,cmd=="quiesce");return e?"ERR\t"+std::to_string(-e):"OK";
    }
    return "ERR\t22";
}
static constexpr size_t controlFrameLimit=8192;
static bool progressOperation(const std::string& input){
    auto op=input.substr(0,input.find('\t'));
    return op=="populate"||op=="populate2"||op=="export"||op=="quiesce"||op=="export2"||op=="quiesce2"||op=="export3"||op=="quiesce3";
}
static bool sendFrame(int fd,const std::string& frame){
    // A slow/disconnected reader cannot stop the worker or raise SIGPIPE.
    auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(2);
    size_t sent=0;
    while(sent<frame.size()){
        if(std::chrono::steady_clock::now()>=deadline)return false;
        auto n=send(fd,frame.data()+sent,frame.size()-sent,MSG_DONTWAIT);
        if(n>0){sent+=size_t(n);continue;}
        if(n<0&&errno==EINTR)continue;
        if(n<0&&(errno==EAGAIN||errno==EWOULDBLOCK)){
            pollfd p{fd,POLLOUT,0};
            auto left=std::chrono::duration_cast<std::chrono::milliseconds>(deadline-std::chrono::steady_clock::now()).count();
            if(left<=0)return false;
            int result=poll(&p,1,int(left));
            if(result<0&&errno==EINTR)continue;
            if(result>0&&(p.revents&POLLOUT))continue;
        }
        return false;
    }
    return true;
}
static std::atomic<bool> controlMutationBusy{false};
static void serveControl(int fd){
    fcntl(fd,F_SETFD,FD_CLOEXEC);
    // A peer that closed while queued can make this option fail with EINVAL.
    // Do not write to that socket with SIGPIPE potentially still enabled.
    int noSignal=1;if(setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&noSignal,sizeof noSignal))return;
    uid_t uid;gid_t gid;if(getpeereid(fd,&uid,&gid)||uid!=getuid())return;
    const auto inputDeadline=std::chrono::steady_clock::now()+std::chrono::seconds(2);
    try{
        std::string data;char c;
        for(;;){
            auto remaining=std::chrono::duration_cast<std::chrono::milliseconds>(inputDeadline-std::chrono::steady_clock::now()).count();
            if(remaining<=0)return;
            pollfd input{fd,POLLIN,0};int ready=poll(&input,1,int(remaining));if(ready<0&&errno==EINTR)continue;if(ready<=0)return;
            auto n=::recv(fd,&c,1,MSG_DONTWAIT);
            if(n<0&&errno==EINTR)continue;
            if(n!=1)return; // Never execute an incomplete request.
            if(c=='\n')break;
            if(data.size()==controlFrameLimit){sendFrame(fd,"ERR\t22\n");return;}
            data+=c;
        }
        auto verb=data.substr(0,data.find('\t'));
        // Startup state has its own lock. In particular, mount-populated must
        // not race the import worker releasing its reservation after sending OK.
        const bool separateQueue=
#ifdef RAMNEST_DEBUG_PROFILING
            verb=="profile-begin"||verb=="profile-end"||verb=="profile-snapshot"||
#endif
            verb=="status"||verb=="metrics"||verb=="capabilities"||verb=="checkpoint-status"||verb=="startup-status"||verb=="abort-startup"||verb=="mount-populated";
        pid_t peer=0;socklen_t peerSize=sizeof peer;
        if(startup.enabled&&getsockopt(fd,SOL_LOCAL,LOCAL_PEERPID,&peer,&peerSize))return;
        struct Reservation {bool held=false;~Reservation(){if(held)controlMutationBusy=false;}} reservation;
        if(!separateQueue){
            if(controlMutationBusy.exchange(true)){sendFrame(fd,"ERR\t16\n");return;}
            reservation.held=true;
        }
        if(!progressOperation(data)){sendFrame(fd,command(data,peer)+"\n");return;}
        auto observed=tree->operationProgress();
        auto baseline=observed;
        auto job=std::async(std::launch::async,[&data,peer]{return command(data,peer);});
        bool connected=true;
        while(job.wait_for(std::chrono::milliseconds(100))!=std::future_status::ready){
            auto current=tree->operationProgress();
            if(connected&&current>observed){
                connected=sendFrame(fd,"PROGRESS\t"+std::to_string(current-baseline)+"\n");
                observed=current;
            }
        }
        // Always join/get the job, including after failed writes. The control loop
        // accepts no next command until this data-preserving operation finishes.
        auto result=job.get();
        if(connected)sendFrame(fd,result+"\n");
    }catch(...){sendFrame(fd,"ERR\t12\n");}
}
static void control(int server){
    // Four bounded authenticated connection workers. Mutations retain one queue;
    // read-only status/metrics never wait for a long export or a slow input peer.
    std::array<std::future<void>,4> workers;
    while(!stopped){
        auto available=workers.end();
        for(auto i=workers.begin();i!=workers.end();++i)if(!i->valid()||i->wait_for(std::chrono::milliseconds(0))==std::future_status::ready){if(i->valid())i->get();available=i;break;}
        if(available==workers.end()){std::this_thread::sleep_for(std::chrono::milliseconds(10));continue;}
        pollfd p{server,POLLIN,0};if(poll(&p,1,100)<=0)continue;
        int fd=accept(server,nullptr,nullptr);if(fd<0)continue;
        *available=std::async(std::launch::async,[fd]{serveControl(fd);close(fd);});
    }
    for(auto& worker:workers)if(worker.valid())worker.get();
    close(server);unlink(socketPath.c_str());
}
// No C++ exception may cross libfuse's C callback ABI.
template<auto Function> struct CallbackBoundary;
template<typename R,typename... Args,R(*Function)(Args...)>struct CallbackBoundary<Function>{
    static R call(Args... args)noexcept{try{return Function(args...);}catch(const std::bad_alloc&){if constexpr(std::is_same_v<R,int>)return -ENOMEM;else if constexpr(std::is_pointer_v<R>)return nullptr;}catch(...){if constexpr(std::is_same_v<R,int>)return -EIO;else if constexpr(std::is_pointer_v<R>)return nullptr;}}
};
// Historical flag name: this only retains the renamex wire-decoder workaround.
// It does not select a backend; mountArguments selects it per session. Keep the
// conservative production omission until renamex has separate FSKit evidence.
static fuse_operations operations(bool productionNFSBridge=true){
    fuse_operations ops{};ops.getattr=&CallbackBoundary<ga>::call;ops.fgetattr=&CallbackBoundary<fga>::call;ops.readdir=&CallbackBoundary<rd>::call;ops.create=&CallbackBoundary<cr>::call;ops.mknod=&CallbackBoundary<mn>::call;ops.mkdir=&CallbackBoundary<mk>::call;ops.open=&CallbackBoundary<op>::call;ops.release=&CallbackBoundary<rel>::call;ops.read=&CallbackBoundary<readFile>::call;ops.write=&CallbackBoundary<writeFile>::call;ops.truncate=&CallbackBoundary<tr>::call;ops.ftruncate=&CallbackBoundary<ftr>::call;ops.unlink=&CallbackBoundary<ul>::call;ops.rmdir=&CallbackBoundary<rmd>::call;ops.rename=&CallbackBoundary<rn>::call;ops.link=&CallbackBoundary<ln>::call;ops.symlink=&CallbackBoundary<sl>::call;ops.readlink=&CallbackBoundary<rsl>::call;ops.chmod=&CallbackBoundary<cm>::call;ops.chown=&CallbackBoundary<co>::call;ops.utimens=&CallbackBoundary<tm>::call;ops.statfs=&CallbackBoundary<stfs>::call;ops.setxattr=&CallbackBoundary<sx>::call;ops.getxattr=&CallbackBoundary<gx>::call;ops.listxattr=&CallbackBoundary<lx>::call;ops.removexattr=&CallbackBoundary<rx>::call;ops.flush=&CallbackBoundary<flush>::call;ops.fsync=&CallbackBoundary<syncFile>::call;ops.init=&CallbackBoundary<init>::call;ops.destroy=&CallbackBoundary<destroy>::call;
    ops.opendir=&CallbackBoundary<od>::call;ops.releasedir=&CallbackBoundary<rdir>::call;ops.fsyncdir=&CallbackBoundary<fdir>::call;ops.access=&CallbackBoundary<ac>::call;
    ops.bmap=&CallbackBoundary<bm>::call;ops.ioctl=&CallbackBoundary<io>::call;ops.poll=&CallbackBoundary<po>::call;ops.lock=&CallbackBoundary<lk>::call;ops.flock=&CallbackBoundary<fl>::call;ops.fallocate=&CallbackBoundary<fa>::call;
    if(!productionNFSBridge)ops.renamex=&CallbackBoundary<rnx>::call;ops.statfs_x=&CallbackBoundary<sfx>::call;ops.setvolname=&CallbackBoundary<svn>::call;ops.exchange=&CallbackBoundary<ex>::call;ops.getxtimes=&CallbackBoundary<gxt>::call;ops.setbkuptime=&CallbackBoundary<sbt>::call;ops.setchgtime=&CallbackBoundary<sct>::call;ops.setcrtime=&CallbackBoundary<scr>::call;ops.chflags=&CallbackBoundary<cf>::call;ops.setattr_x=&CallbackBoundary<sax>::call;ops.fsetattr_x=&CallbackBoundary<fsax>::call;
    ops.flag_nullpath_ok=1;ops.flag_utime_omit_ok=1;
    return ops;
}
static fuse_operations backendOperations(const std::string& backend){
    auto ops=operations();
    if(backend=="fskit")ops.listxattr=&CallbackBoundary<lxFSKit>::call;
    return ops;
}
static std::string selectedBackend(const std::map<std::string,std::string>& options){
    const auto found=options.find("--backend");
    const auto backend=found==options.end()?"nfs":found->second;
    if(backend!="nfs"&&backend!="fskit"&&backend!="smb")throw std::invalid_argument("Invalid --backend: expected nfs, fskit or smb");
    return backend;
}
static std::vector<std::string> mountArguments(const std::map<std::string,std::string>& options){
    const auto backend=selectedBackend(options);
    const auto& path=options.at("--mount");
    // Ignore trailing separators only for the label; pass the original path to FUSE.
    auto end=path.find_last_not_of('/');
    auto separator=path.rfind('/',end);
    auto start=separator==std::string::npos?0:separator+1;
    auto name=end==std::string::npos?"/":path.substr(start,end-start+1);
    char* raw=nullptr;
    // Use libfuse's escaping for commas and backslashes in the -o option list.
    if(fuse_opt_add_opt_escaped(&raw,("volname="+name).c_str())<0)throw std::bad_alloc();
    std::unique_ptr<char,decltype(&std::free)> escaped(raw,&std::free);
    // Select per mount, independently of FUSE-T's global/default backend.
    std::string opts=escaped.get();opts+=",backend="+backend+",noattrcache,namedattr,use_ino";
    if(backend=="smb")opts+=",listen_addr=127.0.0.1:0,nobonjour";
    auto nobrowse=options.find("--nobrowse");if(nobrowse!=options.end()&&nobrowse->second=="true")opts+=",nobrowse";
    return {"ramnest-helper","-f","-o",opts,path};
}
static std::map<std::string,std::string> parseHelperOptions(int argc,char**argv,bool& detach){
    std::map<std::string,std::string> options;
    for(int i=1;i<argc;i++){
        const std::string key=argv[i];
        if(key=="--daemonize"){detach=true;continue;}
        const bool startupKey=key=="--guarded-startup"||key=="--startup-owner";
        if((key.starts_with("--backend")&&key!="--backend")||
           (key.starts_with("--guarded-startup")&&key!="--guarded-startup")||
           (key.starts_with("--startup-owner")&&key!="--startup-owner")||
           i+1>=argc||((key=="--backend"||startupKey)&&options.contains(key)))
            throw std::invalid_argument("Malformed helper option");
        options[key]=argv[++i];
    }
    (void)selectedBackend(options); // Validate before daemonization or any state changes.
    if(options.contains("--guarded-startup")||options.contains("--startup-owner")){
        if(!options.contains("--guarded-startup")||options.at("--guarded-startup")!=startupVersion||!options.contains("--startup-owner"))throw std::invalid_argument("Invalid guarded startup version");
        const auto& owner=options.at("--startup-owner");
        if(owner.empty()||!std::all_of(owner.begin(),owner.end(),[](unsigned char c){return c>='0'&&c<='9';}))throw std::invalid_argument("Invalid startup owner");
        try{auto pid=std::stoll(owner);if(pid<=1||pid>INT_MAX)throw std::invalid_argument("Invalid startup owner");}
        catch(...){throw std::invalid_argument("Invalid startup owner");}
    }
    return options;
}
int main(int argc,char**argv){
    if(argc==2&&std::string(argv[1])=="--storage-capabilities"){std::cout<<"private-storage-v2"<<std::endl;return 0;}
    if(argc==2&&std::string(argv[1])=="--startup-capabilities"){std::cout<<startupVersion<<std::endl;return 0;}
    std::map<std::string,std::string>a;bool detach=false;
    try{a=parseHelperOptions(argc,argv,detach);}catch(const std::invalid_argument&){return 64;}
    if(detach){pid_t p=fork();if(p<0)return 1;if(p>0)return 0;setsid();p=fork();if(p<0)_exit(1);if(p>0)_exit(0);chdir("/");for(int descriptor=3,maximum=getdtablesize();descriptor<maximum;descriptor++)close(descriptor);int fd=open("/dev/null",O_RDWR);for(int i=0;i<3;i++)dup2(fd,i);if(fd>2)close(fd);}
    umask(0077);signal(SIGPIPE,SIG_IGN);identifier=a["--id"];volume=a["--volume"];mountpoint=a["--mount"];socketPath=a["--socket"];cliPath=a["--cli"];storePath=a["--store"];
    if(identifier.empty()||socketPath.size()>=sizeof(sockaddr_un::sun_path)||mountpoint.empty())return 64;
    std::vector<std::string>args;
    try{args=mountArguments(a);tree=std::make_unique<MemoryFS>(std::stoull(a["--size"]),a["--compression"]!="false");}catch(...){return 64;}
#ifdef RAMNEST_DEBUG_PROFILING
    profileBackend=selectedBackend(a);profileCompression=a["--compression"]!="false";
#endif
    sourcePath=a["--source"];tree->freeze(true);
    startup.enabled=a.contains("--guarded-startup");
    // A kernel process-exit subscription pins the owner incarnation (no polling
    // or PID-reuse liveness inference). Register before exposing the socket.
    int ownerEvents=-1;
    if(startup.enabled){
        startup.owner=pid_t(std::stoll(a.at("--startup-owner")));
        startup.deadline=std::chrono::steady_clock::now()+GuardedStartup::controlWait;
        ownerEvents=kqueue();if(ownerEvents<0)return 1;fcntl(ownerEvents,F_SETFD,FD_CLOEXEC);
        struct kevent events[2];EV_SET(&events[0],startup.owner,EVFILT_PROC,EV_ADD|EV_ENABLE|EV_ONESHOT,NOTE_EXIT,0,nullptr);
        EV_SET(&events[1],1,EVFILT_USER,EV_ADD|EV_CLEAR,0,0,nullptr);
        if(kevent(ownerEvents,events,2,nullptr,0,nullptr)<0){close(ownerEvents);return 1;}
    }
    int server=socket(AF_UNIX,SOCK_STREAM,0);if(server<0)return 1;fcntl(server,F_SETFD,FD_CLOEXEC);sockaddr_un addr{};addr.sun_family=AF_UNIX;strlcpy(addr.sun_path,socketPath.c_str(),sizeof addr.sun_path);
    // Never unlink a live predecessor's socket. Core allocates a fresh path per session.
    if(bind(server,reinterpret_cast<sockaddr*>(&addr),sizeof addr)||listen(server,8)){close(server);return 1;}chmod(socketPath.c_str(),0600);
    std::thread controller(control,server);std::thread periodic([]{auto last=std::chrono::steady_clock::now();while(!stopped){std::this_thread::sleep_for(std::chrono::seconds(1));auto n=interval.load();if(mounted&&n>0&&std::chrono::steady_clock::now()-last>=std::chrono::minutes(n)){
#ifdef RAMNEST_DEBUG_PROFILING
        if(!ramnest::profile::claimPeriodic(interval))continue;
#endif
        child({cliPath,"--store",storePath,"save",identifier});last=std::chrono::steady_clock::now();
#ifdef RAMNEST_DEBUG_PROFILING
        ramnest::profile::finishPeriodic();
#endif
    }}});
    std::thread ownerWatcher;
    if(startup.enabled)ownerWatcher=std::thread([ownerEvents]{
        struct kevent event;int count;do{count=kevent(ownerEvents,nullptr,0,&event,1,nullptr);}while(count<0&&errno==EINTR);
        if(count!=1||event.filter!=EVFILT_USER){
            startup.ownerExited();
        }
    });
    auto ops=backendOperations(selectedBackend(a));
    std::vector<char*>av;for(auto&s:args)av.push_back(s.data());
    const bool enterMount=!startup.enabled||startup.awaitMount();
    int result=0;
    if(enterMount){
        result=fuse_main(int(av.size()),av.data(),&ops,nullptr);mounted=false;
        std::lock_guard lock(startup.mutex);startup.connection=nullptr;startup.returned=true;
    }else{
        // A timed-out, failed or abandoned import can NEVER mount later. Keep
        // the frozen tree and authenticated control until normal owned retire.
        std::unique_lock lock(startup.mutex);startup.changed.wait(lock,[]{return stopped.load();});
    }
    // fuse destroy does not own the tree. Keep it alive until the coordinator has
    // durably committed AND restored it. Failed restores are retried, never discarded.
    while(enterMount&&!stopped){int status=child({cliPath,"--store",storePath,"internal-finalize",identifier});if(status==0){stopped=true;break;}for(int i=0;i<30&&!stopped;i++)std::this_thread::sleep_for(std::chrono::seconds(1));}
    stopped=true;controller.join();periodic.join();
    if(ownerWatcher.joinable()){
        struct kevent event;EV_SET(&event,1,EVFILT_USER,0,NOTE_TRIGGER,0,nullptr);kevent(ownerEvents,&event,1,nullptr,0,nullptr);
        ownerWatcher.join();close(ownerEvents);
    }
    return result;
}
