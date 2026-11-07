// Preload timed-wait declarations before the inclusion-only observation macro.
// Helper.cpp itself is unchanged; this seam observes a REAL CV wait/reacquire.
#include "MemoryFS.hpp"
#include <condition_variable>
#include <future>
#include <thread>
#include <cassert>
struct StartupWaitBoundaryForTest {
    std::mutex mutex;
    std::condition_variable changed;
    bool armed=false, waiting=false, producerReady=false, returned=false;
    std::cv_status result=std::cv_status::no_timeout;
    std::chrono::steady_clock::time_point originalDeadline;
};
static StartupWaitBoundaryForTest startupWaitBoundary;
static auto startupWaitDeadlineForTest(std::chrono::steady_clock::time_point deadline){
    auto& boundary=startupWaitBoundary;
    std::unique_lock lock(boundary.mutex);
    if(boundary.armed){
        boundary.armed=false;boundary.waiting=true;boundary.originalDeadline=deadline;boundary.changed.notify_all();
        // awaitMount still owns startup.mutex here. The producer acknowledges
        // its turn before trying that mutex, which only the real wait releases.
        assert(boundary.changed.wait_for(lock,std::chrono::seconds(2),[&]{return boundary.producerReady;}));
    }
    return deadline; // Capture the original deadline, not a producer's renewal.
}
struct StartupWaitResultForTest {};
static std::cv_status operator+(std::cv_status result,StartupWaitResultForTest){
    auto& boundary=startupWaitBoundary;
    std::lock_guard lock(boundary.mutex);
    if(boundary.waiting&&!boundary.returned){
        boundary.result=result;boundary.returned=true;boundary.changed.notify_all();
    }
    return result; // Never synthesize timeout or alter the production decision.
}
#define wait_until(lock, deadline) wait_until(lock, startupWaitDeadlineForTest(deadline)) + StartupWaitResultForTest{}
#define main ramnest_helper_entry
#include "Helper.cpp"
#undef main
#undef wait_until
#include <algorithm>
#include <cassert>
#include <cerrno>
#include <filesystem>
#include <fstream>
#include <sys/xattr.h>
#include <condition_variable>
#include <sstream>

namespace fs = std::filesystem;
struct ParsedMountArguments {
    std::vector<std::string> options, mountpoints;
};
static int collectMountArgument(void* data,const char* arg,int key,fuse_args*) {
    auto& parsed=*static_cast<ParsedMountArguments*>(data);
    assert(key==FUSE_OPT_KEY_OPT||key==FUSE_OPT_KEY_NONOPT);
    (key==FUSE_OPT_KEY_NONOPT?parsed.mountpoints:parsed.options).emplace_back(arg);
    return 0;
}
static void testMountArguments(const std::string& base) {
    const std::vector<std::string> names={
        "original-folder", "Folder with spaces", "Été 日本語 🐿️", "Cafe\u0301",
        "Research & Development", "comma,name", "back\\slash", "ends-in-backslash\\",
        "comma\\,backslash", "double\\\\slash", " leading and trailing ",
        "Été & work, draft\\copy", "folder,nobrowse,volname=other\\,use_ino",
        "folder,backend=nfs", "folder,backend=smb", "folder,backend=fskit\\,backend=nfs", "folder,listen_addr=0.0.0.0:445",
        "folder,bonjour,listen_addr=0.0.0.0:0", "folder,nobonjour\\,backend=smb"
    };
    size_t cases=0;
    for(const std::string backend:{"", "nfs", "fskit", "smb"})for(const auto& name:names)for(const auto* trailing:{"","/","///"})for(bool nobrowse:{false,true}) {
        const auto path=base+"/"+name+trailing;
        std::map<std::string,std::string> input={
            {"--mount",path},{"--nobrowse",nobrowse?"true":"false"},
            {"--id","12345678-1234-1234-1234-123456789ABC"},{"--name","Different display alias"},
            {"--socket",base+"/session-one.sock"},{"--volume",base+"/uuid-volume"},
            {"--source",base+"/snapshot-data"},{"--store",base+"/store"}
        };
        if(!backend.empty())input["--backend"]=backend;
        const auto selected=backend.empty()?"nfs":backend;
        const auto before=input;
        auto args=mountArguments(input);
        assert(input==before); // Option construction cannot rewrite path or session identity.
        assert(args.size()==5&&args[0]=="ramnest-helper"&&args[1]=="-f"&&args[2]=="-o"&&args[4]==path);
        // App aliases and UUID/socket changes must have no effect on FUSE arguments.
        input["--name"]="Renamed app alias, & \\ Unicode 日本語";
        assert(mountArguments(input)==args);
        input.erase("--name");assert(mountArguments(input)==args);
        input["--id"]="ABCDEF01-ABCD-ABCD-ABCD-ABCDEF012345";
        input["--socket"]=base+"/session-two.sock";
        assert(mountArguments(input)==args);
        if(!nobrowse){input.erase("--nobrowse");assert(mountArguments(input)==args);}
        std::vector<char*> argv;for(auto& arg:args)argv.push_back(arg.data());argv.push_back(nullptr);
        fuse_args parsedArgs=FUSE_ARGS_INIT(int(args.size()),argv.data());
        ParsedMountArguments parsed;
        // Exercise the installed libfuse parser, not a hand-written unescaper.
        assert(fuse_opt_parse(&parsedArgs,&parsed,nullptr,collectMountArgument)==0);
        const std::vector<std::string> expected={"-f","volname="+name,"backend="+selected,"noattrcache","namedattr","use_ino"};
        auto expectedOptions=expected;
        if(selected=="smb"){expectedOptions.push_back("listen_addr=127.0.0.1:0");expectedOptions.push_back("nobonjour");}
        if(nobrowse)expectedOptions.push_back("nobrowse");
        if(parsed.options!=expectedOptions)std::cerr<<"FAIL exact installed-libfuse options for backend "<<selected<<" (missing argument means NFS)\n";
        assert(parsed.options==expectedOptions); // Exact name bytes and no injected options.
        assert(std::count(parsed.options.begin(),parsed.options.end(),"backend="+selected)==1);
        assert(std::count_if(parsed.options.begin(),parsed.options.end(),[](const auto& option){return option.starts_with("backend=");})==1);
        assert(parsed.mountpoints==std::vector<std::string>{path});
        fuse_opt_free_args(&parsedArgs);
        ++cases;
    }
    for(const std::string invalid:{"", "fsdisk", "smb3", "NFS", "unknown", "nfs,backend=smb", "smb,listen_addr=0.0.0.0:445", "smb,bonjour", " fskit", "fskit "}) {
        bool rejected=false;
        try{(void)mountArguments({{"--mount",base+"/original"},{"--backend",invalid}});}catch(const std::invalid_argument&){rejected=true;}
        assert(rejected);
    }
    std::cout<<"PASS helper mount options: "<<cases<<" installed-libfuse roundtrips; NFS default or one explicit nfs/fskit/smb; SMB loopback and nobonjour; malformed backends rejected; original path, punctuation, Unicode, trailing separators, alias and session independence\n";
}
static void testBackendCLIParsing() {
    auto parse=[](std::vector<std::string> args){
        std::vector<char*> argv;for(auto& arg:args)argv.push_back(arg.data());
        bool detach=false;return parseHelperOptions(int(argv.size()),argv.data(),detach);
    };
    assert(selectedBackend(parse({"helper"}))=="nfs");
    for(const std::string backend:{"nfs","fskit","smb"})
        assert(selectedBackend(parse({"helper","--daemonize","--backend",backend}))==backend);
    const std::vector<std::vector<std::string>> invalid={
        {"--backend"}, {"--backend", ""}, {"--backend", "fsdisk"}, {"--backend", "smb3"},
        {"--backend", "smb,bonjour"}, {"--backend", "smb,listen_addr=0.0.0.0:445"},
        {"--backend", "--daemonize"}, {"--backend", "nfs", "--backend", "smb"},
        {"--backend", "smb", "--backend", "smb"}, {"--backend=nfs", "ignored"}
    };
    for(auto tail:invalid){
        tail.insert(tail.begin(),"helper");bool rejected=false;
        try{(void)parse(tail);}catch(const std::invalid_argument&){rejected=true;}
        assert(rejected);
        // The actual entrypoint must reject before daemonizing or creating state.
        std::vector<char*> argv;for(auto& arg:tail)argv.push_back(arg.data());
        assert(ramnest_helper_entry(int(argv.size()),argv.data())==64);
    }
    std::cout<<"PASS helper CLI parsing: three backends, missing -> NFS; 10 malformed/duplicate forms rejected before side effects\n";
}
static int payloadWrites = 0;
static ssize_t countedWriter(int fd,const void* data,size_t size,off_t offset) {
    ++payloadWrites;
    return pwrite(fd,data,size,offset);
}
static std::map<std::string,std::string> diskFiles(const fs::path& root) {
    std::map<std::string,std::string> files;
    for (const auto& entry:fs::recursive_directory_iterator(root)) {
        if (entry.is_directory()) files[entry.path().lexically_relative(root).string()+"/"]="";
        else {
            assert(entry.is_regular_file());
            std::ifstream input(entry.path(),std::ios::binary);
            files[entry.path().lexically_relative(root).string()]=std::string(std::istreambuf_iterator<char>(input),{});
        }
    }
    return files;
}
#include "ControlSocketFixtures.hpp"
static std::mutex pausedMutex;
static std::condition_variable pausedCondition;
static bool exportPaused=false,resumeExport=false;
static ssize_t pausedWrite(int fd,const void*data,size_t size,off_t offset){
    std::unique_lock lock(pausedMutex);exportPaused=true;pausedCondition.notify_all();if(!pausedCondition.wait_for(lock,std::chrono::seconds(10),[]{return resumeExport;})){errno=ETIMEDOUT;return -1;}lock.unlock();return pwrite(fd,data,size,offset);
}
static void statusQueueRegression(const fs::path& fixture){
    volume=fixture.string();tree=std::make_unique<MemoryFS>(16*1024*1024);assert(tree->create("/file",S_IFREG|0600)==0&&tree->write("/file","kept",4,0)==4);tree->setExportWriterForTest(pausedWrite);
    int exportPair[2],statusPair[2];assert(socketpair(AF_UNIX,SOCK_STREAM,0,exportPair)==0&&socketpair(AF_UNIX,SOCK_STREAM,0,statusPair)==0);
    std::thread exporter([&]{serveControl(exportPair[1]);close(exportPair[1]);});
    auto request="export\t"+(fixture/"stage-status").string()+"\n";assert(send(exportPair[0],request.data(),request.size(),0)==ssize_t(request.size()));
    {std::unique_lock lock(pausedMutex);assert(pausedCondition.wait_for(lock,std::chrono::seconds(5),[]{return exportPaused;}));}
    std::thread reader([&]{serveControl(statusPair[1]);close(statusPair[1]);});
    auto start=std::chrono::steady_clock::now();assert(send(statusPair[0],"status\n",7,0)==7);pollfd ready{statusPair[0],POLLIN,0};assert(poll(&ready,1,500)==1);char response[1024];auto size=recv(statusPair[0],response,sizeof response,0);assert(size>0&&std::string(response,size).starts_with("OK\t"));
    auto ms=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();reader.join();close(statusPair[0]);
    {std::lock_guard lock(pausedMutex);resumeExport=true;}pausedCondition.notify_all();exporter.join();close(exportPair[0]);
    int partial[2];assert(socketpair(AF_UNIX,SOCK_STREAM,0,partial)==0);std::thread input([&]{serveControl(partial[1]);close(partial[1]);});
    start=std::chrono::steady_clock::now();assert(send(partial[0],"stat",4,0)==4);ready={partial[0],POLLIN,0};assert(poll(&ready,1,3000)==1&&recv(partial[0],response,sizeof response,0)==0);input.join();close(partial[0]);
    auto elapsed=std::chrono::duration<double>(std::chrono::steady_clock::now()-start).count();assert(elapsed>=1.8&&elapsed<3.0);
    std::cout<<"PASS item10 authenticated socketpair status_during_paused_export_ms="<<ms<<" incomplete_frame_deadline_seconds="<<elapsed<<"; mutation serialization retained\n";
}
static void resetStartup(bool enabled){
    std::lock_guard lock(startup.mutex);
    startup.enabled=enabled;startup.importing=false;startup.imported=false;startup.requested=false;
    startup.abandoned=false;startup.entered=false;startup.returned=false;startup.ownerDead=false;
    startup.owner=getpid();startup.connection=nullptr;
    startup.deadline=std::chrono::steady_clock::now()+GuardedStartup::controlWait;
    mounted=false;populated=false;activated=false;stopped=false;
}
static void testGuardedStartupCLI(){
    for(const auto& [option,expected]:std::vector<std::pair<std::string,std::string>>{
        {"--storage-capabilities","private-storage-v2\n"},{"--startup-capabilities",std::string(startupVersion)+"\n"}}){
        std::ostringstream output;auto previous=std::cout.rdbuf(output.rdbuf());
        std::string name="helper",query=option;char* args[]={name.data(),query.data()};
        assert(ramnest_helper_entry(2,args)==0);std::cout.rdbuf(previous);assert(output.str()==expected);
    }
    auto parse=[](std::vector<std::string> args){std::vector<char*> argv;for(auto& s:args)argv.push_back(s.data());bool detach=false;return parseHelperOptions(int(argv.size()),argv.data(),detach);};
    auto valid=std::vector<std::string>{"helper","--guarded-startup",startupVersion,"--startup-owner",std::to_string(getpid())};
    assert(parse(valid).at("--guarded-startup")==startupVersion);
    for(auto invalid:std::vector<std::vector<std::string>>{
        {"helper","--guarded-startup",startupVersion}, {"helper","--startup-owner","2"},
        {"helper","--guarded-startup","v0","--startup-owner","2"},
        {"helper","--guarded-startup",startupVersion,"--startup-owner","0"},
        {"helper","--guarded-startup",startupVersion,"--startup-owner","2junk"},
        {"helper","--guarded-startup=pre-mount-population-v1","ignored"},
        {"helper","--startup-owner=42","ignored"},
        {"helper","--guarded-startup",startupVersion,"--startup-owner","99999999999999999999"}}){
        bool rejected=false;try{(void)parse(invalid);}catch(const std::invalid_argument&){rejected=true;}assert(rejected);
    }
    auto duplicate=valid;duplicate.insert(duplicate.end(),{"--guarded-startup",startupVersion});
    bool rejected=false;try{(void)parse(duplicate);}catch(const std::invalid_argument&){rejected=true;}assert(rejected);
    std::cout<<"PASS guarded-startup CLI: independent exact offline capabilities; missing/bad/duplicate flags and unbound owner rejected\n";
}
static void testGuardedStartupOrder(const fs::path& fixture){
    for(mode_t mode:{0700,0755})for(bool hardlink:{false,true}){
        auto revision=fixture/("startup-"+std::to_string(mode)+(hardlink?"-hardlink":"-independent"));fs::create_directory(revision);
        MemoryFS exporter(16*1024*1024,false);
        assert(exporter.create("/normal",S_IFDIR|0755)==0);
        assert(exporter.create("/normal/payload",S_IFREG|0640)==0);
        assert(exporter.write("/normal/payload","startup bytes",13,0)==13);
        if(hardlink)assert(exporter.link("/normal/payload","/alias")==0);
        else assert(exporter.create("/alias",S_IFREG|0640)==0&&exporter.write("/alias","startup bytes",13,0)==13);
        assert(exporter.setxattr("/normal/payload","user.startup","exact",0)==0);
        assert(exporter.setxattr("/alias","user.startup","exact",0)==0);
        assert(exporter.create("/.Trashes",S_IFDIR|0311)==0&&exporter.create("/.Trashes/opaque",S_IFDIR|0000)==0);
        assert(exporter.chmod("/",mode)==0);
        assert(exporter.exportTree(revision/"data",false,"",0,true)==0);
        auto digest=exporter.lastExportStats().modeMapDigest;
        fs::rename((revision/"data").string()+".modes",revision/"modes.bin");
        sourcePath=(revision/"data").string();tree=std::make_unique<MemoryFS>(16*1024*1024,false);tree->freeze(true);
        resetStartup(false);
        assert(command("populate2\t"+digest)=="ERR\t16"); // Legacy unmounted prohibition.
        mounted=true;assert(command("populate2\t"+digest)=="OK"&&tree->isFrozen());
        // Fresh negotiated helper: the production gate cannot enter FUSE until
        // real command import + the authenticated owner's explicit mount ACK.
        tree=std::make_unique<MemoryFS>(16*1024*1024,false);tree->freeze(true);resetStartup(true);
        auto gate=std::async(std::launch::async,[]{return startup.awaitMount();});
        assert(command("startup-status")==std::string("OK\t")+startupVersion+"\twaiting");
        assert(command("mount-populated",getpid())=="ERR\t16"&&command("activate")=="ERR\t16");
        assert(command("populate2\t"+digest,getpid()+1)=="ERR\t1");
        assert(command("populate2\t"+digest,getpid())=="OK");
        assert(!mounted&&!activated&&populated&&tree->isFrozen());
        assert(gate.wait_for(std::chrono::milliseconds(0))==std::future_status::timeout);
        assert(command("startup-status")==std::string("OK\t")+startupVersion+"\tpopulated");
        assert(command("mount-populated",getpid()+1)=="ERR\t16");
        assert(command("mount-populated",getpid())==std::string("OK\t")+startupVersion+"\tmount-requested");
        assert(gate.get());
        // First production callbacks after the gate see complete metadata,
        // namespace, inode partition and bytes, never the default empty 0755 root.
        struct stat root{},alias{},payload{};assert(ga("/",&root)==0&&(root.st_mode&07777)==mode);
        assert(ga("/alias",&alias)==0&&ga("/normal/payload",&payload)==0);
        assert((alias.st_ino==payload.st_ino)==hardlink&&alias.st_nlink==(hardlink?2:1));
        std::vector<std::string> names;assert(tree->entries("/",names)==0);
        assert(std::find(names.begin(),names.end(),"alias")!=names.end()&&std::find(names.begin(),names.end(),"normal")!=names.end());
        char bytes[13];assert(readFile("/alias",bytes,sizeof bytes,0,nullptr)==13&&std::string(bytes,13)=="startup bytes");
        std::string value;assert(tree->getxattr("/alias","user.startup",value)==0&&value=="exact");
        assert(ga("/.Trashes",&root)==-ENOENT&&command("activate")=="ERR\t16");
        assert(command("retire")=="ERR\t16"&&command("abort-startup")=="ERR\t16");
        mounted=true;assert(command("activate")=="OK"&&!tree->isFrozen());
        mounted=false;{std::lock_guard lock(startup.mutex);startup.returned=true;}
        assert(command("retire")=="OK");
    }
    // Failed digest/import, abandoned owner and expired control startup seal the
    // gate. All cases retain frozen tree/source until explicit normal retire.
    for(const std::string reason:{"digest","owner","timeout","abort"}){
        tree=std::make_unique<MemoryFS>(16*1024*1024,false);tree->freeze(true);resetStartup(true);
        if(reason=="digest")assert(command("populate2\t"+std::string(64,'0'),getpid())!="OK");
        if(reason=="owner")startup.ownerExited();
        if(reason=="timeout"){std::lock_guard lock(startup.mutex);startup.deadline=std::chrono::steady_clock::now();}
        if(reason=="abort")assert(command("abort-startup")==std::string("OK\t")+startupVersion+"\tretained");
        assert(!startup.awaitMount());
        assert(!mounted&&!activated&&tree->isFrozen()&&fs::exists(sourcePath));
        assert(command("mount-populated",getpid())=="ERR\t16"&&command("activate")=="ERR\t16");
        assert(command("retire")=="OK");
    }
    resetStartup(false);
    std::cout<<"PASS guarded startup order: private-v2 exact digest before first callbacks; root0700/0755, hardlinks/bytes/xattrs/Trash, legacy order, no early activation, bad import/owner/timeout/abort sealed + normal retire\n";
}
static std::mutex importPauseMutex;
static std::condition_variable importPauseChanged;
static bool importPaused=false,importResumed=false;
static ssize_t startupPausedReader(int fd,void* bytes,size_t count){
    std::unique_lock lock(importPauseMutex);
    importPaused=true;importPauseChanged.notify_all();
    if(!importPauseChanged.wait_for(lock,std::chrono::seconds(5),[]{return importResumed;})){errno=ETIMEDOUT;return -1;}
    lock.unlock();return ::read(fd,bytes,count);
}
static void testGuardedStartupStatusDuringImport(const fs::path& fixture){
    auto source=fixture/"startup-progress";fs::create_directory(source);fs::create_directory(source/"normal");
    {std::ofstream output(source/"normal/payload");output<<"real import work";}
    sourcePath=source.string();tree=std::make_unique<MemoryFS>(16*1024*1024,false);tree->freeze(true);
    resetStartup(true);tree->setImportReaderForTest(startupPausedReader);
    int importer[2],reader[2];assert(socketpair(AF_UNIX,SOCK_STREAM,0,importer)==0&&socketpair(AF_UNIX,SOCK_STREAM,0,reader)==0);
    auto importing=std::async(std::launch::async,[&]{serveControl(importer[1]);close(importer[1]);});
    assert(send(importer[0],"populate\n",9,0)==9);
    {std::unique_lock lock(importPauseMutex);assert(importPauseChanged.wait_for(lock,std::chrono::seconds(5),[]{return importPaused;}));}
    // Expiring the control-startup budget while import is underway must not
    // turn it into a hard-coded data-import deadline.
    {std::lock_guard lock(startup.mutex);startup.deadline=std::chrono::steady_clock::now();}
    auto gate=std::async(std::launch::async,[]{return startup.awaitMount();});
    assert(command("startup-status")==std::string("OK\t")+startupVersion+"\timporting");
    assert(!activated&&command("mount-populated",getpid())=="ERR\t16");
    auto reading=std::async(std::launch::async,[&]{serveControl(reader[1]);close(reader[1]);});
    assert(send(reader[0],"status\n",7,0)==7);pollfd ready{reader[0],POLLIN,0};assert(poll(&ready,1,500)==1);
    char bytes[1024];auto n=recv(reader[0],bytes,sizeof bytes,0);assert(n>0);
    auto status=std::string(bytes,n);assert(status.find("\tretained\t")!=std::string::npos&&status.ends_with("\tguarded\n"));
    reading.get();close(reader[0]);
    ready={importer[0],POLLIN,0};assert(poll(&ready,1,1000)==1);
    n=recv(importer[0],bytes,sizeof bytes,0);assert(n>0&&std::string(bytes,n).starts_with("PROGRESS\t"));
    assert(gate.wait_for(std::chrono::milliseconds(0))==std::future_status::timeout);
    // Abandoning an in-progress import seals future mount immediately without
    // interrupting its preservation work or blocking read-only control.
    startup.ownerExited();assert(!gate.get());
    {std::lock_guard lock(importPauseMutex);importResumed=true;}importPauseChanged.notify_all();
    importing.get();std::string final;
    while((n=recv(importer[0],bytes,sizeof bytes,0))>0)final.append(bytes,size_t(n));close(importer[0]);
    assert(final.ends_with("OK\n")&&populated&&!mounted&&!activated&&tree->isFrozen());
    assert(command("mount-populated",getpid())=="ERR\t16");
    assert(command("retire")=="OK");resetStartup(false);
    std::cout<<"PASS guarded startup import: authenticated socket progress, responsive retained/guarded status, owner abandonment retains completed frozen data and never mounts\n";
}
static void testGuardedStartupTimeoutReacquire(){
    // Each producer owns the actual gate mutex across the original deadline.
    // It installs the protected state at the same linearization point as
    // beginImport / finishImport / mount-populated. No timeout is mocked and no
    // alternate implementation of awaitMount's decision is tested.
    for(const std::string state:{"importing","renewed-deadline","requested","idle-expired","owner-exit","stopped","abandoned"}){
        std::cerr<<"CHECK startup-timeout-reacquire/"<<state<<std::endl;
        tree=std::make_unique<MemoryFS>(16*1024*1024,false);tree->freeze(true);resetStartup(true);
        {
            std::lock_guard lock(startupWaitBoundary.mutex);
            startupWaitBoundary.armed=true;startupWaitBoundary.waiting=false;
            startupWaitBoundary.producerReady=false;startupWaitBoundary.returned=false;
            startupWaitBoundary.result=std::cv_status::no_timeout;
        }
        // Fixture-only shortening: production controlWait stays exactly 15s.
        {std::lock_guard lock(startup.mutex);startup.deadline=std::chrono::steady_clock::now()+std::chrono::milliseconds(250);}
        auto producer=std::async(std::launch::async,[&]{
            std::chrono::steady_clock::time_point original;
            {
                std::unique_lock lock(startupWaitBoundary.mutex);
                assert(startupWaitBoundary.changed.wait_for(lock,std::chrono::seconds(2),[]{return startupWaitBoundary.waiting;}));
                original=startupWaitBoundary.originalDeadline;
                startupWaitBoundary.producerReady=true;startupWaitBoundary.changed.notify_all();
            }
            std::unique_lock lock(startup.mutex);
            assert(!startup.abandoned&&!startup.entered);
            if(state=="importing")startup.importing=true;
            if(state=="renewed-deadline"){
                startup.imported=true;populated=true;
                startup.deadline=std::chrono::steady_clock::now()+GuardedStartup::controlWait;
            }
            if(state=="requested"||state=="owner-exit"||state=="stopped"||state=="abandoned"){
                startup.imported=true;populated=true;startup.requested=true;
            }
            if(state=="owner-exit"){startup.ownerDead=true;startup.abandon();}
            if(state=="stopped")stopped=true;
            if(state=="abandoned")startup.abandon();
            startup.changed.notify_all();
            // Hold the gate lock until the original timed wait has expired.
            // A notified waiter cannot reacquire early and return no_timeout.
            std::mutex holdMutex;std::condition_variable holdChanged;
            std::unique_lock hold(holdMutex);
            holdChanged.wait_until(hold,original+std::chrono::milliseconds(1),[]{return false;});
        });
        auto gate=std::async(std::launch::async,[]{return startup.awaitMount();});
        producer.get();
        {
            std::unique_lock lock(startupWaitBoundary.mutex);
            assert(startupWaitBoundary.changed.wait_for(lock,std::chrono::seconds(2),[]{return startupWaitBoundary.returned;}));
            assert(startupWaitBoundary.result==std::cv_status::timeout);
        }
        // The observation above happens under startup.mutex. Acquiring it here
        // is a barrier after the actual timeout decision (or next real wait).
        if(state=="importing"||state=="renewed-deadline"){
            {
                std::lock_guard lock(startup.mutex);
                assert(!startup.abandoned&&!startup.entered&&!startup.requested);
                if(state=="importing")assert(startup.importing&&std::chrono::steady_clock::now()>=startup.deadline);
                else assert(!startup.importing&&startup.imported&&std::chrono::steady_clock::now()<startup.deadline);
            }
            assert(gate.wait_for(std::chrono::milliseconds(0))==std::future_status::timeout);
            if(state=="importing"){
                startup.finishImport(true);populated=true;
                {std::lock_guard lock(startup.mutex);assert(startup.deadline>std::chrono::steady_clock::now()&&GuardedStartup::controlWait==std::chrono::seconds(15));}
                assert(command("mount-populated",getpid())==std::string("OK\t")+startupVersion+"\tmount-requested");
                assert(gate.get());
            }else{startup.ownerExited();assert(!gate.get());}
        }else if(state=="requested"){
            assert(gate.get());std::lock_guard lock(startup.mutex);assert(startup.entered&&!startup.abandoned);
        }else{
            assert(!gate.get());std::lock_guard lock(startup.mutex);assert(!startup.entered);
            if(state=="idle-expired")assert(startup.abandoned);
            if(state=="owner-exit")assert(startup.ownerDead&&startup.abandoned);
            if(state=="stopped")assert(stopped);
            if(state=="abandoned")assert(startup.abandoned);
        }
        assert(!mounted&&!activated&&tree->isFrozen());
        std::cout<<"PASS startup-timeout-reacquire/"<<state<<std::endl;
        {std::lock_guard lock(startupWaitBoundary.mutex);startupWaitBoundary.waiting=false;}
    }
    resetStartup(false);
}
int main(int argc,char** argv) {
    if(argc==5&&std::string(argv[1])=="--socket-fixture")return socketFixture(argv[2],argv[3],argv[4]);
    if(argc==5&&std::string(argv[1])=="--connected-fixture")return socketFixture(argv[2],"",argv[4],std::stoi(argv[3]));
    auto base=getenv("RAMNEST_TEST_ROOT");assert(base);
    const bool startupOnly=argc==2&&std::string(argv[1])=="--startup-regressions";
    if(!startupOnly){testBackendCLIParsing();testMountArguments(base);}
    fs::create_directories(base);
    std::string pattern=std::string(base)+"/ramnest-freeze-XXXXXX";
    char* directory=mkdtemp(pattern.data());assert(directory);
    fs::path fixture=fs::canonical(directory), freezeOnly=fixture/"freeze-only", optIn=fixture/"opt-in";
    testGuardedStartupCLI();testGuardedStartupOrder(fixture);testGuardedStartupStatusDuringImport(fixture);testGuardedStartupTimeoutReacquire();
    if(startupOnly)return 0;
    fs::create_directory(freezeOnly);
    { std::ofstream seed(freezeOnly/"original");seed<<"unchanged original"; }
    volume=freezeOnly.string();
    tree=std::make_unique<MemoryFS>(16*1024*1024);
    tree->setExportWriterForTest(countedWriter);
    std::string sentinel="RAM-only-private-"+std::to_string(arc4random());
    uint64_t handle=0;
    assert(tree->create("/private",S_IFREG|0600,&handle,O_RDWR)==0);
    assert(tree->write("/private",sentinel.data(),sentinel.size(),0,handle)==int(sentinel.size()));
    auto before=diskFiles(freezeOnly);auto metrics=tree->metrics();
    // Invoke the real production helper command dispatcher, without mounting.
    assert(command("freeze")=="ERR\t16"); // Never activate an unpopulated tree.
    activated=true;
    assert(command("freeze\t"+(freezeOnly/"stage-must-not-exist").string())=="ERR\t22");
    assert(command("freeze")=="OK"&&tree->isFrozen());
    assert(command("freeze")=="OK"&&tree->isFrozen());
    assert(payloadWrites==0&&diskFiles(freezeOnly)==before);
    std::string readback(sentinel.size(),'\0');
    assert(tree->read("/private",readback.data(),readback.size(),0,handle)==int(readback.size())&&readback==sentinel);
    assert(tree->write("/private","x",1,0,handle)==-EBUSY);
    assert(tree->create("/new",S_IFREG|0600)==-EBUSY);
    assert(tree->remove("/private")==-EBUSY);
    assert(tree->metrics().mapped==metrics.mapped&&tree->metrics().logical==metrics.logical);
    // Eject failure must be able to thaw the same unsaved data, still with no I/O.
    assert(command("thaw")=="OK"&&!tree->isFrozen());
    assert(tree->write("/private",sentinel.data(),sentinel.size(),0,handle)==int(sentinel.size()));
    assert(command("freeze")=="OK"&&payloadWrites==0&&diskFiles(freezeOnly)==before);
    // Explicit live export remains an opt-in operation to a separate destination.
    fs::create_directory(optIn);volume=optIn.string();
    assert(command("thaw")=="OK");
    assert(command("export\t"+(optIn/"stage-rescue").string())=="OK"&&!tree->isFrozen());
    assert(payloadWrites>0&&diskFiles(optIn).at("stage-rescue/private")==sentinel);
    assert(command("quiesce\t"+(optIn/"stage-sync").string())=="OK"&&tree->isFrozen());
    assert(diskFiles(optIn).at("stage-sync/private")==sentinel);
    assert(diskFiles(freezeOnly)==before); // No files removed to hide persistence.
    assert(tree->close(handle)==0);
    statusQueueRegression(fixture);
    std::cout<<"PASS helper control: freeze-only/no payload writes/no new stages, read/freeze/thaw lifetime, explicit export and synced quiesce preserved; retained fixture "<<fixture<<"\n";
}
