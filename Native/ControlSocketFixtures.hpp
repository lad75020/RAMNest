// Included only by ControlTests.cpp: generated data and injected I/O delays,
// exercising the production control()/serveControl()/command() socket boundary.
static bool fixtureInterrupted=false, fixtureStall=false, fixtureZero=false;
static void fixtureDelay(){
    if(fixtureStall){fixtureStall=false;std::this_thread::sleep_for(std::chrono::milliseconds(1800));}
    std::this_thread::sleep_for(std::chrono::milliseconds(200));
}
static ssize_t fixtureReader(int fd,void* bytes,size_t count){
    if(!fixtureInterrupted){fixtureInterrupted=true;errno=EINTR;return -1;}
    fixtureDelay();return ::read(fd,bytes,count);
}
static ssize_t fixtureWriter(int fd,const void* bytes,size_t count,off_t offset){
    if(!fixtureInterrupted){fixtureInterrupted=true;errno=EINTR;return -1;}
    fixtureDelay();if(fixtureZero)return 0;return ::pwrite(fd,bytes,count,offset);
}
static std::string fixtureBytes(const fs::path& path){
    std::ifstream input(path,std::ios::binary);assert(input);
    return std::string(std::istreambuf_iterator<char>(input),{});
}
static int socketFixture(const std::string& mode,const std::string& socket,const fs::path& root,int connected=-1){
    // Deliberately use the default signal disposition: serveControl must set
    // SO_NOSIGPIPE itself, including when the client leaves before final OK.
    signal(SIGPIPE,SIG_DFL);
    fs::create_directories(root);
    const auto source=root/"source", destination=root/"stage-result";
    fs::create_directory(source);
    std::string payload(10*ramnest::pageSize,'A');
    for(size_t i=0;i<payload.size();i+=97)payload[i]=char('a'+i%26);
    {std::ofstream output(source/"original-é.bin",std::ios::binary);output<<payload;}
    fs::create_directory(source/"empty");
    assert(::link((source/"original-é.bin").c_str(),(source/"hardlink").c_str())==0);
    assert(::symlink("original-é.bin",(source/"symlink").c_str())==0);
    struct stat original{};assert(::lstat((source/"original-é.bin").c_str(),&original)==0);
    tree=std::make_unique<MemoryFS>(16*1024*1024);
    identifier="12345678-1234-1234-1234-123456789ABC";
    sourcePath=source.string();volume=root.string();socketPath=socket;
    stopped=false;activated=false;populated=false;
    bool population=mode.find("populate")!=std::string::npos;
    if(mode.find("populate2")!=std::string::npos){
        MemoryFS exporter(16*1024*1024);assert(exporter.importTree(sourcePath)==0);
        const auto data=root/"data";assert(exporter.exportTree(data,false,"",0,true)==0);
        fs::rename(data.string()+".modes",root/"modes.bin");sourcePath=data.string();
    }
    fixtureStall=mode.starts_with("stall");fixtureZero=mode=="error-export";
    if(population){tree->freeze(true);tree->setImportReaderForTest(fixtureReader);mounted=true;}
    else{
        assert(tree->importTree(sourcePath)==0);populated=true;activated=true;mounted=false;
        tree->setExportWriterForTest(fixtureWriter);
    }
    auto baseline=tree->operationProgress();
    if(connected>=0){serveControl(connected);close(connected);}
    else{
    int server=::socket(AF_UNIX,SOCK_STREAM,0);assert(server>=0);
    fcntl(server,F_SETFD,FD_CLOEXEC);
    sockaddr_un address{};address.sun_family=AF_UNIX;
    assert(socket.size()<sizeof address.sun_path);
    strlcpy(address.sun_path,socket.c_str(),sizeof address.sun_path);
    int bound=bind(server,reinterpret_cast<sockaddr*>(&address),sizeof address);
    if(bound)std::cerr<<"fixture bind: "<<strerror(errno)<<"\n";
    assert(bound==0);
    assert(listen(server,8)==0);
    std::thread controller(control,server);
    if(population){
        while(!populated)std::this_thread::sleep_for(std::chrono::milliseconds(5));
        mounted=false; // Permit test-only retire once real population completes.
    }
    controller.join(); // Test driver sends retire; no worker cancellation.
    }
    std::string readback(payload.size(),'\0');
    assert(tree->read("/original-é.bin",readback.data(),readback.size(),0)==int(readback.size()));
    assert(readback==payload&&fixtureBytes(source/"original-é.bin")==payload);
    struct stat after{};assert(::lstat((source/"original-é.bin").c_str(),&after)==0);
    assert(after.st_ino==original.st_ino&&after.st_size==original.st_size&&after.st_mode==original.st_mode);
    assert(after.st_mtimespec.tv_sec==original.st_mtimespec.tv_sec&&after.st_mtimespec.tv_nsec==original.st_mtimespec.tv_nsec);
    if(mode=="incomplete-export"){
        assert(!fs::exists(destination)&&tree->operationProgress()==baseline);
    }else if(!population&&!fixtureZero){
        assert(fixtureBytes(destination/"original-é.bin")==payload);
        struct stat a{},b{};assert(::lstat((destination/"original-é.bin").c_str(),&a)==0);
        assert(::lstat((destination/"hardlink").c_str(),&b)==0&&a.st_ino==b.st_ino);
        assert(fs::read_symlink(destination/"symlink")=="original-é.bin");
        assert(fs::is_directory(destination/"empty"));
    }
    if(population||mode.find("quiesce")!=std::string::npos)assert(tree->isFrozen());
    else assert(!tree->isFrozen());
    std::cout<<"PASS production Unix control "<<mode<<": tree/source retained, "
             <<tree->operationProgress()-baseline<<" work units; fixture "<<root<<"\n";
    return 0;
}
