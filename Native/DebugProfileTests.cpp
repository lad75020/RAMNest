#define main ramnest_helper_entry
#include "Helper.cpp"
#undef main
#include <cassert>
int main(){
    tree=std::make_unique<MemoryFS>(32*1024*1024); mounted=true;activated=true;
    const std::string token="12345678-1234-4234-8234-123456789abc";
#ifdef RAMNEST_DEBUG_PROFILING
    assert(command("capabilities").find("debug-io-profile-v2")!=std::string::npos);
    assert(ramnest::profile::names.size()==14);
    assert(command("capabilities").find("debug-io-profile-v1")==std::string::npos);
    assert(command("profile-begin\tbad\twrite")=="ERR\t22");
    assert(command("profile-begin\t"+token+"\twrite").starts_with("OK\t{"));
    assert(command("profile-begin\t"+token+"\tread")=="ERR\t16");
    assert(command("profile-end\t00000000-0000-4000-8000-000000000000\twrite")=="ERR\t22");
    fuse_file_info info{};info.flags=O_RDWR;assert(!cr("/owned",0600,&info));
    std::vector<char> input(65536,'x'),output(65536);
    assert(writeFile("/owned",input.data(),input.size(),0,&info)==65536);
    assert(readFile("/owned",output.data(),output.size(),0,&info)==65536);assert(input==output);
    auto result=command("profile-end\t"+token+"\twrite");
    assert(result.find("\"version\":2")!=std::string::npos);
    assert(result.find("\"integrityAlgorithm\":\"sha256\"")!=std::string::npos);
    assert(result.find("\"id\":\"fnv\"")==std::string::npos);
    // The payload may still exist during untimed read preparation/readback.
    // Ending a measured window must not permit a periodic checkpoint.
    assert(command("period\t1")=="ERR\t16");
    assert(interval.load()==0);
    const std::string fixture="/.ramnest-debug-io-"+token;
    assert(tree->create(fixture,S_IFDIR|0700)==0);
    assert(command("profile-release\t"+token+"\twrite")=="ERR\t16");
    assert(command("export\t/invalid")=="ERR\t16");
    assert(tree->remove(fixture,true)==0);
    assert(result.size()<8192&&result.find("\"id\":\"callback_write\",\"calls\":1")!=std::string::npos);
    assert(result.find("\"id\":\"lz4_encode\",\"calls\":1")!=std::string::npos);
    assert(result.find("\"id\":\"sha256\",\"calls\":2")!=std::string::npos);
    assert(command("profile-begin\t"+token+"\tread").starts_with("OK\t{"));
    { ramnest::profile::Scope old(ramnest::profile::Metric::native_read);
      auto stopped=command("profile-end\t"+token+"\tread");assert(stopped.find("\"inFlight\":1")!=std::string::npos);
      assert(command("profile-begin\t"+token+"\twrite")=="ERR\t16"); }
    assert(command("profile-begin\t"+token+"\twrite").starts_with("OK\t{"));
    std::array<std::thread,4> threads;
    for(auto& t:threads)t=std::thread([]{for(int i=0;i<100;i++){ramnest::profile::Scope s(ramnest::profile::Metric::memcpy);}});
    for(auto& t:threads)t.join();
    result=command("profile-end\t"+token+"\twrite");assert(result.find("\"id\":\"memcpy\",\"calls\":400")!=std::string::npos);
    assert(command("profile-begin\t"+token+"\tread").starts_with("OK\t{"));
    assert(readFile("/missing",output.data(),output.size(),0,nullptr)==-ENOENT);
    result=command("profile-end\t"+token+"\tread");
    assert(result.find("\"errors\":1")!=std::string::npos);
    assert(command("profile-begin\t"+token+"\tread").starts_with("OK\t{"));
    ramnest::profile::active.load()->deadline=ramnest::profile::now()-1;
    assert(command("profile-end\t"+token+"\tread")=="ERR\t22");
    assert(command("profile-begin\t"+token+"\twrite").starts_with("OK\t{"));
    assert(command("profile-end\t"+token+"\twrite").starts_with("OK\t{"));
    tree=std::make_unique<MemoryFS>(32*1024*1024,false);profileCompression=false;
    assert(!cr("/raw-owned",0600,&info));
    assert(command("profile-begin\t"+token+"\twrite").starts_with("OK\t{"));
    assert(writeFile("/raw-owned",input.data(),input.size(),0,&info)==65536);
    assert(readFile("/raw-owned",output.data(),output.size(),0,&info)==65536);
    result=command("profile-end\t"+token+"\twrite");
    assert(result.find("\"compression\":false")!=std::string::npos);
    assert(result.find("\"id\":\"lz4_encode\",\"calls\":0")!=std::string::npos);
    assert(result.find("\"id\":\"lz4_decode\",\"calls\":0")!=std::string::npos);
    assert(result.find("\"id\":\"raw_block\",\"calls\":1")!=std::string::npos);
    assert(command("period\t1")=="ERR\t16");
    assert(command("profile-release\t"+token+"\twrite")=="OK\t"+token);
    assert(command("period\t1")=="OK");
    assert(ramnest::profile::claimPeriodic(interval));
    assert(command("period\t0")=="OK");
    assert(command("profile-begin\t"+token+"\twrite")=="ERR\t16");
    ramnest::profile::finishPeriodic();
    // Whichever contender owns the common admission mutex wins; both can
    // never succeed while a fixture reservation would be live.
    for(int i=0;i<32;i++){
        std::atomic<bool> go=false;std::string beginReply,periodReply;
        std::thread a([&]{while(!go.load())std::this_thread::yield();beginReply=command("profile-begin\t"+token+"\tread");});
        std::thread b([&]{while(!go.load())std::this_thread::yield();periodReply=command("period\t1");});
        go=true;a.join();b.join();
        if(beginReply.starts_with("OK\t{")){
            assert(periodReply=="ERR\t16");
            assert(command("profile-end\t"+token+"\tread").starts_with("OK\t{"));
            assert(command("period\t1")=="ERR\t16");
            assert(command("profile-release\t"+token+"\tread")=="OK\t"+token);
        }else{assert(beginReply=="ERR\t16"&&periodReply=="OK");}
        assert(command("period\t0")=="OK");
    }
#else
    assert(command("capabilities").find("debug-io-profile-v2")==std::string::npos);
    assert(command("profile-begin\t"+token+"\twrite")=="ERR\t22");
#endif
}
