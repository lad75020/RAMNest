// Owned, no-mount test driver. Dispatches through the production command handler.
#define main unused_helper_main
#include "Helper.cpp"
#undef main
#include <cassert>
int main(int argc,char**argv){
 assert(argc==3);identifier=argv[1];volume=argv[2];tree=std::make_unique<MemoryFS>(16*1024*1024,false);mounted=true;activated=true;populated=true;
 assert(tree->create("/payload",S_IFREG|0600)==0&&tree->write("/payload","original",8,0)==8);
 std::string input;while(std::getline(std::cin,input)){
  std::string result;
  if(input.starts_with("fixture-write\t")){auto data=input.substr(14);int e=tree->truncate("/payload",0);if(!e)e=tree->write("/payload",data.data(),data.size(),0);result=e<0?"ERR\t"+std::to_string(-e):"OK";}
  else if(input=="fixture-unmounted"){mounted=false;result="OK";}
  else result=command(input);
  std::cout<<result<<std::endl;
 }
}
