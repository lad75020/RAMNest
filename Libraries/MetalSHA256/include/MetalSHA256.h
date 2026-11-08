#ifndef METAL_SHA256_H
#define METAL_SHA256_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Experimental API v1; not audited or certified. All lengths are bytes.
   Handles must be live handles returned by this library. No concurrent free/use.
   Context must outlive its prepared handles. Calls on one context serialize.
   Input/output memory must remain valid and input immutable until call returns.
   prepare copies inputs: caller may mutate/free them after prepare returns.
   Output order matches descriptors; each is ONE ordinary SHA-256 message. */
typedef struct MS256Context MS256Context;
typedef struct MS256Prepared MS256Prepared;
typedef struct { uint64_t offset, length; } MS256Message;
typedef struct { uint64_t max_packed_bytes, max_messages; } MS256Config;
typedef struct {
    char device_name[256], shader_sha256[65];
    uint64_t max_buffer_length, max_packed_bytes, max_messages, max_message_bytes;
    uint64_t thread_execution_width, threads_per_group;
    int32_t unified_memory;
    double bootstrap_seconds;
} MS256Info;
typedef struct {
    uint64_t completed_commands, message_count, workload_bytes;
    /* -1 when unavailable or empty batch. Diagnostic GPU timestamps only. */
    double gpu_start_seconds, gpu_end_seconds, gpu_seconds;
} MS256Metrics;
enum { MS256_OK=0, MS256_INVALID=1, MS256_LIMIT=2, MS256_METAL=3, MS256_INTERNAL=4 };
/* NULL config selects 256 MiB / 65536. Explicit max packed <=1 GiB;
   max messages <=65536 and message <=16 MiB, also device limits apply.
   Sum of descriptor lengths (including overlaps) <= max_packed_bytes too,
   bounding command work as well as storage. */
int32_t ms256_context_create(const MS256Config *config, MS256Context **out_context);
void ms256_context_free(MS256Context *context);
int32_t ms256_context_info(MS256Context *context, MS256Info *info);
/* Per calling thread last error. Includes terminator, truncated safely.
   Returns full required capacity INCLUDING terminator, even with capacity=0. */
size_t ms256_last_error(char *destination, size_t capacity);
/* descriptor_size MUST equal sizeof(MS256Message). All validation before GPU.
   Valid overlapping and unaligned input ranges are allowed. */
int32_t ms256_prepare(MS256Context *context, const void *packed, uint64_t packed_bytes,
    const MS256Message *messages, uint64_t count, size_t descriptor_size,
    MS256Prepared **out_prepared);
void ms256_prepared_free(MS256Prepared *prepared);
int32_t ms256_hash_prepared(MS256Context *context, MS256Prepared *prepared,
    void *digests, size_t digest_capacity, MS256Metrics *metrics);
int32_t ms256_hash_batch(MS256Context *context, const void *packed, uint64_t packed_bytes,
    const MS256Message *messages, uint64_t count, size_t descriptor_size,
    void *digests, size_t digest_capacity, MS256Metrics *metrics);
#ifdef __cplusplus
}
#endif
#endif
