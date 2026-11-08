#include <stdint.h>
typedef struct { int available; uint64_t pageins, resident, footprint; int64_t minor_faults, major_faults; } BenchmarkProbe;
BenchmarkProbe benchmark_probe(void);
