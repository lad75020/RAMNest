#include "MetalSHA256.h"
#include <stdio.h>
#include <string.h>
int main(void) {
    MS256Context *c=NULL; MS256Prepared *p=NULL;
    int status=ms256_context_create(NULL,&c);
    if(status) { char e[1024]; ms256_last_error(e,sizeof(e)); fprintf(stderr,"GPU smoke failed: %s\n",e); return 1; }
    const unsigned char bytes[]={'x','a','b','c'};
    MS256Message d={1,3}; unsigned char out[32]; MS256Metrics m={0}; m.gpu_seconds=-1;
    const unsigned char expected[32]={0xba,0x78,0x16,0xbf,0x8f,0x01,0xcf,0xea,0x41,0x41,0x40,0xde,0x5d,0xae,0x22,0x23,0xb0,0x03,0x61,0xa3,0x96,0x17,0x7a,0x9c,0xb4,0x10,0xff,0x61,0xf2,0x00,0x15,0xad};
    status=ms256_prepare(c,bytes,sizeof(bytes),&d,1,sizeof(d),&p);
    if(!status) status=ms256_hash_prepared(c,p,out,sizeof(out),&m);
    MS256Info info={0}; ms256_context_info(c,&info);
    int ok=!status && !memcmp(out,expected,32) && m.completed_commands==1 && m.gpu_seconds>0;
    printf("%s C ABI device=%s commands=%llu gpuSeconds=%.9f\n",ok?"PASS":"FAIL",info.device_name,(unsigned long long)m.completed_commands,m.gpu_seconds);
    ms256_prepared_free(p); ms256_context_free(c); return ok?0:1;
}
