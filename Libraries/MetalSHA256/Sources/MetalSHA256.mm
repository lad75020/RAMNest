#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "MetalSHA256.h"
#include "ShaderSource.h"
#include <mutex>
#include <memory>
#include <cstring>
#include <chrono>
#include <exception>
#include <cstddef>
#include <algorithm>
#include <cstdio>
static_assert(sizeof(MS256Message)==16 && alignof(MS256Message)==8 && offsetof(MS256Message,length)==8, "MSL layout");
static constexpr uint64_t MiB=1024*1024, MessageLimit=16*MiB;
static thread_local char lastError[4096] = {};
static int fail(int status, const char *s) { snprintf(lastError,sizeof(lastError),"%s",s?s:"Unknown error"); return status; }
static int metalError(NSError *e) { return fail(MS256_METAL,e ? e.localizedDescription.UTF8String : "Metal object creation failed"); }
struct MS256Context {
    std::mutex mutex;
    id<MTLDevice> device;
    id<MTLCommandQueue> queue;
    id<MTLComputePipelineState> pipeline;
    MS256Info info{};
};
struct MS256Prepared {
    MS256Context *owner;
    id<MTLBuffer> input, descriptors, output;
    uint64_t count=0, bytes=0;
};
// C ABI catches both native and ObjC exceptions; handles use RAII/ARC.
#define BEGIN_API try { @try {
#define END_API } @catch(NSException *e) { return fail(MS256_INTERNAL,e.reason.UTF8String); } } catch(const std::exception &e) { return fail(MS256_INTERNAL,e.what()); } catch(...) { return fail(MS256_INTERNAL,"Unknown native exception"); }
static void resetMetrics(MS256Metrics *m) { if(m) *m={0,0,0,-1,-1,-1}; }
static int validate(MS256Context *c,const void *bytes,uint64_t n,const MS256Message *d,uint64_t count,size_t stride, size_t cap, bool output) {
    if(!c || stride!=sizeof(MS256Message)) return fail(MS256_INVALID,"Invalid context or descriptor size");
    // Reject all dimensions/overflow before reading descriptors or allocating.
    if(count>SIZE_MAX/32 || count>SIZE_MAX/sizeof(MS256Message)) return fail(MS256_LIMIT,"Count/output arithmetic overflow");
    if(n>c->info.max_packed_bytes || n>c->info.max_buffer_length || count>c->info.max_messages)
        return fail(MS256_LIMIT,"Packed batch/count exceeds configured or Metal device limit");
    if((n&&!bytes) || (count&&!d)) return fail(MS256_INVALID,"Missing input/descriptors");
    if(output && cap<count*32) return fail(MS256_INVALID,"Digest destination too small");
    uint64_t work=0;
    for(uint64_t i=0;i<count;++i) {
        if(d[i].length>MessageLimit) return fail(MS256_LIMIT,"Message exceeds 16 MiB; chunk into INDEPENDENT messages only if that is your workload, never ordinary file SHA");
        if(d[i].offset>n || d[i].length>n-d[i].offset) return fail(MS256_INVALID,"Descriptor offset+length overflow or outside packed input");
        if(d[i].length>c->info.max_packed_bytes-work) return fail(MS256_LIMIT,"Total message work exceeds batch budget (including overlapping views)");
        work+=d[i].length;
    }
    return MS256_OK;
}
int32_t ms256_context_create(const MS256Config *config,MS256Context **out) {
    if(out) *out=nullptr;
    BEGIN_API
    @autoreleasepool {
        if(!out) return fail(MS256_INVALID,"Missing context destination");
        uint64_t bytes=config?config->max_packed_bytes:256*MiB, count=config?config->max_messages:65536;
        if(!bytes || bytes>1024*MiB || !count || count>65536) return fail(MS256_LIMIT,"Config requires 1...1GiB packed bytes and 1...65536 messages");
        auto start=std::chrono::steady_clock::now();
        auto c=std::make_unique<MS256Context>();
        c->device=MTLCreateSystemDefaultDevice();
        if(!c->device) return fail(MS256_METAL,"Metal device unavailable; no CPU fallback");
        if(bytes>c->device.maxBufferLength || count*32>c->device.maxBufferLength || count*sizeof(MS256Message)>c->device.maxBufferLength)
            return fail(MS256_LIMIT,"Config exceeds Metal maxBufferLength");
        NSError *error=nil;
        MTLCompileOptions *opts=[MTLCompileOptions new]; opts.fastMathEnabled=NO;
        id<MTLLibrary> lib=[c->device newLibraryWithSource:[NSString stringWithUTF8String:MS256ShaderSource] options:opts error:&error];
        if(!lib) return metalError(error);
        id<MTLFunction> fn=[lib newFunctionWithName:@"sha256_batch"];
        if(!fn) return fail(MS256_METAL,"SHA-256 kernel missing");
        c->pipeline=[c->device newComputePipelineStateWithFunction:fn error:&error];
        if(!c->pipeline) return metalError(error);
        c->queue=[c->device newCommandQueue]; if(!c->queue) return metalError(nil);
        auto &i=c->info;
        snprintf(i.device_name,sizeof(i.device_name),"%s",c->device.name.UTF8String);
        snprintf(i.shader_sha256,sizeof(i.shader_sha256),"%s",MS256ShaderHash);
        i.max_buffer_length=c->device.maxBufferLength; i.max_packed_bytes=bytes; i.max_messages=count; i.max_message_bytes=MessageLimit;
        i.thread_execution_width=c->pipeline.threadExecutionWidth;
        i.threads_per_group=std::min<NSUInteger>(256,c->pipeline.maxTotalThreadsPerThreadgroup);
        if(i.threads_per_group>=i.thread_execution_width) i.threads_per_group-=i.threads_per_group%i.thread_execution_width;
        if(!i.threads_per_group) return fail(MS256_METAL,"Invalid pipeline threadgroup width");
        i.unified_memory=c->device.hasUnifiedMemory;
        i.bootstrap_seconds=std::chrono::duration<double>(std::chrono::steady_clock::now()-start).count();
        *out=c.release(); lastError[0]=0; return MS256_OK;
    }
    END_API
}
void ms256_context_free(MS256Context *c) {
    try { @try { delete c; } @catch(NSException *e) { fail(MS256_INTERNAL,e.reason.UTF8String); } }
    catch(...) { fail(MS256_INTERNAL,"Exception releasing context"); }
}
int32_t ms256_context_info(MS256Context *c,MS256Info *i) {
    BEGIN_API
    if(!c||!i) return fail(MS256_INVALID,"Missing context/info");
    *i=c->info; return MS256_OK;
    END_API
}
size_t ms256_last_error(char *out,size_t cap) {
    size_t length=strlen(lastError), required=length+1;
    if(out&&cap) { size_t n=std::min(cap-1,length); memcpy(out,lastError,n); out[n]=0; }
    return required;
}
static int prepareLocked(MS256Context *c,const void *bytes,uint64_t n,const MS256Message *d,uint64_t count,MS256Prepared **out) {
    auto p=std::make_unique<MS256Prepared>(); p->owner=c; p->count=count;
    for(uint64_t i=0;i<count;++i) p->bytes+=d[i].length; // sum already bounded by configured work budget
    if(count) {
        p->input=[c->device newBufferWithLength:std::max<uint64_t>(n,1) options:MTLResourceStorageModeShared];
        p->descriptors=[c->device newBufferWithBytes:d length:count*sizeof(MS256Message) options:MTLResourceStorageModeShared];
        p->output=[c->device newBufferWithLength:count*32 options:MTLResourceStorageModeShared];
        if(!p->input || !p->descriptors || !p->output) return metalError(nil);
        if(n) memcpy(p->input.contents,bytes,n);
    }
    *out=p.release(); return MS256_OK;
}
int32_t ms256_prepare(MS256Context *c,const void *bytes,uint64_t n,const MS256Message *d,uint64_t count,size_t stride,MS256Prepared **out) {
    if(out) *out=nullptr;
    BEGIN_API
    @autoreleasepool {
        if(!out) return fail(MS256_INVALID,"Missing prepared destination");
        int s=validate(c,bytes,n,d,count,stride,0,false); if(s) return s;
        std::lock_guard<std::mutex> lock(c->mutex);
        return prepareLocked(c,bytes,n,d,count,out);
    }
    END_API
}
void ms256_prepared_free(MS256Prepared *p) {
    try { @try { delete p; } @catch(NSException *e) { fail(MS256_INTERNAL,e.reason.UTF8String); } }
    catch(...) { fail(MS256_INTERNAL,"Exception releasing prepared input"); }
}
static int hashLocked(MS256Context *c,MS256Prepared *p,void *out,size_t cap,MS256Metrics *m) {
    if(!p || p->owner!=c) return fail(MS256_INVALID,"Prepared handle belongs to another context");
    if(cap<p->count*32 || (p->count&&!out)) return fail(MS256_INVALID,"Missing/undersized digest destination");
    if(!p->count) return MS256_OK; // empty batch: no command, metrics explicitly zero/-1
    id<MTLCommandBuffer> cmd=[c->queue commandBuffer];
    cmd.label=@"MetalSHA256.standardSHA256Batch";
    id<MTLComputeCommandEncoder> enc=[cmd computeCommandEncoder];
    if(!cmd||!enc) return metalError(nil);
    [enc setComputePipelineState:c->pipeline];
    [enc setBuffer:p->input offset:0 atIndex:0]; [enc setBuffer:p->descriptors offset:0 atIndex:1];
    [enc setBuffer:p->output offset:0 atIndex:2]; [enc setBytes:&p->count length:sizeof(p->count) atIndex:3];
    const uint64_t group=c->info.threads_per_group;
    const uint64_t groups=(p->count+group-1)/group; // count<=65536; checked during prepare
    [enc dispatchThreadgroups:MTLSizeMake(groups,1,1) threadsPerThreadgroup:MTLSizeMake(group,1,1)];
    [enc endEncoding]; [cmd commit]; [cmd waitUntilCompleted];
    if(cmd.status!=MTLCommandBufferStatusCompleted || cmd.error) return fail(MS256_METAL,cmd.error ? cmd.error.localizedDescription.UTF8String : "Metal command did not complete successfully");
    memcpy(out,p->output.contents,p->count*32);
    if(m) {
        m->completed_commands=1; m->message_count=p->count; m->workload_bytes=p->bytes;
        double a=cmd.GPUStartTime,b=cmd.GPUEndTime;
        if(a>0 && b>a) { m->gpu_start_seconds=a; m->gpu_end_seconds=b; m->gpu_seconds=b-a; }
    }
    return MS256_OK;
}
int32_t ms256_hash_prepared(MS256Context *c,MS256Prepared *p,void *out,size_t cap,MS256Metrics *m) {
    resetMetrics(m);
    BEGIN_API
    @autoreleasepool {
        if(!c) return fail(MS256_INVALID,"Missing context");
        std::lock_guard<std::mutex> lock(c->mutex); return hashLocked(c,p,out,cap,m);
    }
    END_API
}
int32_t ms256_hash_batch(MS256Context *c,const void *bytes,uint64_t n,const MS256Message *d,uint64_t count,size_t stride,void *out,size_t cap,MS256Metrics *m) {
    resetMetrics(m);
    BEGIN_API
    @autoreleasepool {
        int s=validate(c,bytes,n,d,count,stride,cap,true); if(s) return s;
        if(count&&!out) return fail(MS256_INVALID,"Missing digest destination");
        std::lock_guard<std::mutex> lock(c->mutex);
        MS256Prepared *raw=nullptr; s=prepareLocked(c,bytes,n,d,count,&raw); if(s) return s;
        std::unique_ptr<MS256Prepared> p(raw); return hashLocked(c,p.get(),out,cap,m);
    }
    END_API
}
