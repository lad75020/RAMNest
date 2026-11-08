#define main ramnest_helper_entry
#include "Helper.cpp"
#undef main
#include <cassert>
#include <filesystem>
#include <fstream>
#include <sstream>
namespace fs=std::filesystem;
static void parseTests(){
    auto parse=[](std::vector<std::string> args){std::vector<char*> argv;for(auto& s:args)argv.push_back(s.data());bool detach=false;return parseHelperOptions(int(argv.size()),argv.data(),detach);};
    assert(!parse({"helper"}).contains("--file-verification"));
    for(auto policy:{"sha256","sizeAndModTime"})assert(parse({"helper","--file-verification",policy}).at("--file-verification")==policy);
    for(auto tail:std::vector<std::vector<std::string>>{{"--file-verification"},{"--file-verification",""},{"--file-verification","unknown"},{"--file-verification","null"},{"--file-verification","SHA256"},{"--file-verification=sha256","x"},{"--file-verification","sha256","--file-verification","sizeAndModTime"}}){
        tail.insert(tail.begin(),"helper");bool rejected=false;try{(void)parse(tail);}catch(const std::invalid_argument&){rejected=true;}assert(rejected);
        std::vector<char*> argv;for(auto& s:tail)argv.push_back(s.data());assert(ramnest_helper_entry(int(argv.size()),argv.data())==64);
    }
    std::vector<std::string> args{"helper","--verification-capabilities"};std::vector<char*> argv;for(auto& s:args)argv.push_back(s.data());
    std::ostringstream output;auto prior=std::cout.rdbuf(output.rdbuf());assert(!ramnest_helper_entry(int(argv.size()),argv.data()));std::cout.rdbuf(prior);assert(output.str()=="file-verification-v1\n");
}
static void mutate(const fs::path& path,bool size,bool time){
    int fd=::open(path.c_str(),O_RDWR|O_NOFOLLOW);assert(fd>=0);struct stat st{};assert(!::fstat(fd,&st));char byte='X';assert(::pwrite(fd,&byte,1,0)==1);
    if(size)assert(!::ftruncate(fd,st.st_size+1));
    timespec ts[2]={st.st_atimespec,st.st_mtimespec};if(time)ts[1].tv_sec++;assert(!::futimens(fd,ts));assert(!::close(fd));
}
static void transport(FileVerification policy){
    tree=std::make_unique<MemoryFS>(16<<20,true,policy);const auto before=tree->checkpointState();
    for(const auto request:{"verification-policy\n","verification-policy\tsha256\n"}){
        int sockets[2];assert(!socketpair(AF_UNIX,SOCK_STREAM,0,sockets));
        controlMutationBusy=true; // Read-only negotiation bypasses a busy mutation.
        std::thread server([&]{serveControl(sockets[1]);::close(sockets[1]);});
        assert(::write(sockets[0],request,strlen(request))==ssize_t(strlen(request)));
        std::string response;char c;while(::read(sockets[0],&c,1)==1){response+=c;if(c=='\n')break;}
        assert(!::close(sockets[0]));server.join();controlMutationBusy=false;
        const std::string expected=strchr(request,'\t')?"ERR\t22\n":std::string("OK\tfile-verification-v1\t")+(policy==FileVerification::sha256?"sha256\n":"sizeAndModTime\n");
        assert(response==expected&&tree->checkpointState()==before);
    }
}
static void pageStructure(){
    std::vector<char> bytes(ramnest::pageSize,'A'),decoded(ramnest::pageSize);
    ramnest::MappedPage strong;assert(strong.verificationPolicy()==FileVerification::sha256);assert(!strong.encode(bytes.data(),false));
    strong.bytes[0]^=1;assert(strong.decode(decoded.data())==-EIO);strong.bytes[0]^=1;
    for(bool compression:{false,true}){
        ramnest::MappedPage page(FileVerification::sizeAndModTime);assert(!page.encode(bytes.data(),compression));
        assert((page.strongChecksum==std::array<unsigned char,32>{}));
        auto capture=page;assert(capture.verificationPolicy()==FileVerification::sizeAndModTime&&capture.storage==page.storage);
        assert(!capture.decode(decoded.data())&&decoded==bytes);
        assert(capture.readSlice(decoded.data(),ramnest::pageSize,1)==-EIO);
        capture.payload=0;assert(capture.decode(decoded.data())==-EIO);
        capture=page;capture.mapped=ramnest::pageSize+1;assert(capture.decode(decoded.data())==-EIO);
        if(compression){assert(page.compressed);capture=page;capture.payload=1;assert(capture.decode(decoded.data())==-EIO);}
    }
}
static void lifecycle(const fs::path& directory,FileVerification policy,bool compression){
    fs::create_directory(directory);MemoryFS fs(16<<20,compression,policy);
    auto hooks=std::make_shared<ramnest::IoTestHooks>();fs.setIoHooksForTest(hooks);const bool strong=policy==FileVerification::sha256;
    std::vector<char> bytes(2*ramnest::pageSize,'A'),out(bytes.size());
    auto checkHash=[&](uint64_t before){assert(strong?hooks->shaBytes>before:hooks->shaBytes==0);assert(fs.accountingOracleForTest());};
    assert(!fs.create("/f",S_IFREG|0600));assert(fs.write("/f",bytes.data(),bytes.size(),0)==int(bytes.size()));checkHash(0);
    auto before=hooks->shaBytes.load();assert(fs.read("/f",out.data(),out.size(),0)==int(out.size())&&out==bytes);checkHash(before);
    before=hooks->shaBytes.load();assert(fs.write("/f","B",1,7)==1);checkHash(before);
    before=hooks->shaBytes.load();assert(fs.write("/f",bytes.data(),ramnest::pageSize,0)==int(ramnest::pageSize));checkHash(before);
    before=hooks->shaBytes.load();assert(!fs.truncate("/f",ramnest::pageSize+17));assert(!fs.truncate("/f",bytes.size()));checkHash(before);
    std::fill(bytes.begin()+ramnest::pageSize+17,bytes.end(),0);
    // A captured reader keeps the page's policy while an overwrite replaces it.
    hooks->arm(ramnest::IoTestHooks::Point::readCaptured);char captured=0;
    std::thread reader([&]{assert(fs.read("/f",&captured,1,0)==1);});assert(hooks->wait(1));
    assert(fs.write("/f","C",1,0)==1);hooks->release(1);reader.join();assert(captured=='A');bytes[0]='C';
    // Force an overlapping staged write to retry against fresh immutable pages.
    hooks->arm(ramnest::IoTestHooks::Point::writeStaged);
    std::thread writer([&]{assert(fs.write("/f","D",1,1)==1);});assert(hooks->wait(2));
    assert(fs.write("/f","E",1,2)==1);hooks->release(2);writer.join();assert(hooks->retries>0);bytes[1]='D';bytes[2]='E';
    assert(fs.read("/f",out.data(),out.size(),0)==int(out.size())&&out==bytes);
    auto first=directory/"first";before=hooks->shaBytes.load();assert(!fs.exportTree(first.string()));checkHash(before);auto initial=fs.lastExportStats();assert(!initial.reused);
    MemoryFS loaded(16<<20,compression,policy);loaded.setIoHooksForTest(hooks);before=hooks->shaBytes.load();assert(!loaded.importTree(first.string()));checkHash(before);
    assert(loaded.accountingOracleForTest());assert(loaded.read("/f",out.data(),out.size(),0)==int(out.size())&&out==bytes);
    before=hooks->shaBytes.load();assert(!fs.exportTree((directory/"noop").string(),false,first.string(),initial.generation));assert(fs.lastExportStats().reused);checkHash(before);
    // New namespace forces export while the unchanged file takes the APFS clone path.
    assert(!fs.create("/new",S_IFREG|0600));before=hooks->shaBytes.load();auto next=directory/"cloned";
    assert(!fs.exportTree(next.string(),false,first.string(),initial.generation));auto cloned=fs.lastExportStats();assert(!cloned.reused&&cloned.clonedFiles==1);checkHash(before);
    assert(!fs.exportTree((directory/"cloned-noop").string(),false,next.string(),cloned.generation));assert(fs.lastExportStats().reused);
    before=hooks->shaBytes.load();std::vector<char> zeros(ramnest::pageSize,0);
    assert(fs.write("/f",zeros.data(),zeros.size(),0)==int(zeros.size()));checkHash(before);
    if(!strong)assert(hooks->shaBytes==0);
    std::cout<<"PASS lifecycle "<<(strong?"sha256":"sizeAndModTime")<<" compression="<<compression<<" shaBytes="<<hooks->shaBytes<<" clones="<<cloned.clonedFiles<<" retries="<<hooks->retries<<"\n";
}
int main(){
    parseTests();auto base=getenv("RAMNEST_TEST_ROOT");assert(base);fs::create_directories(base);std::string pattern=std::string(base)+"/verification-XXXXXX";assert(mkdtemp(pattern.data()));fs::path root(pattern);
    unsigned serial=0;
    for(auto policy:{FileVerification::sha256,FileVerification::sizeAndModTime})for(bool compression:{false,true}){
        const bool strong=policy==FileVerification::sha256;
        transport(policy);
        for(unsigned mutation=0;mutation<4;mutation++){
            auto directory=root/std::to_string(serial++);fs::create_directory(directory);auto first=directory/"first";
            tree=std::make_unique<MemoryFS>(16<<20,compression,policy);auto hooks=std::make_shared<ramnest::IoTestHooks>();tree->setIoHooksForTest(hooks);
            std::vector<char> bytes(2*ramnest::pageSize,'A');assert(!tree->create("/f",S_IFREG|0600));assert(tree->write("/f",bytes.data(),bytes.size(),0)==int(bytes.size()));assert(strong?hooks->shaBytes>0:hooks->shaBytes==0);
            char byte=0;auto before=hooks->shaBytes.load();assert(tree->read("/f",&byte,1,0)==1&&byte=='A');assert(strong?hooks->shaBytes>before:hooks->shaBytes==0);
            assert(command("verification-policy")==std::string("OK\tfile-verification-v1\t")+(strong?"sha256":"sizeAndModTime"));assert(command("verification-policy\tchange")=="ERR\t22");
            assert(!tree->exportTree(first.string()));auto stats=tree->lastExportStats();assert(stats.fileVerificationSHA256Bytes==(strong?bytes.size():0));assert(stats.readback==(strong?bytes.size():0));
            MemoryFS loaded(16<<20,compression,policy);loaded.setIoHooksForTest(hooks);assert(!loaded.importTree(first.string()));std::vector<char> out(bytes.size());assert(loaded.read("/f",out.data(),out.size(),0)==int(out.size())&&out==bytes);
            if(mutation){mutate(first/"f",mutation==2,mutation==3);}
            const auto result=tree->exportTree((directory/"next").string(),false,first.string(),stats.generation);
            assert((result==0)==(mutation==0||(!strong&&mutation==1)));
            if(!result){auto next=tree->lastExportStats();assert(next.reused);assert(next.fileVerificationSHA256Bytes==(strong?bytes.size():0));}
            if(strong){assert(!tree->flipPayloadByteForTest("/f",0));assert(tree->read("/f",&byte,1,0)==-EIO);assert(!tree->flipPayloadByteForTest("/f",0));}
            else{
                assert(!tree->flipDigestByteForTest("/f",0));assert(tree->read("/f",&byte,1,0)==1&&byte=='A');
                if(!compression){assert(!tree->flipPayloadByteForTest("/f",0));assert(tree->read("/f",&byte,1,0)==1&&byte!='A');assert(!tree->flipPayloadByteForTest("/f",0));}
                assert(hooks->shaBytes==0);
            }
        }
    }
    for(auto policy:{FileVerification::sha256,FileVerification::sizeAndModTime})for(bool compression:{false,true})lifecycle(root/std::to_string(serial++),policy,compression);
    pageStructure();
    std::cout<<"PASS native verification: strict parser/offline handshake/session ACK; both policies raw/LZ4 write/read/import/export/no-op; size/mtime reject; same-size restored-mtime blind spot; zero payload SHA counters across metadata write/read/staging/truncate/import/fresh export/clone/noop/capture retries; raw corruption intentionally undetected; structural decode validation retained\n";
}
