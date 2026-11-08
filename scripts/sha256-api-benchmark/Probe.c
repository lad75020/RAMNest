#include "Probe.h"
#include <libproc.h>
#include <sys/resource.h>
#include <unistd.h>
BenchmarkProbe benchmark_probe(void) {
    BenchmarkProbe p = {0};
    struct rusage_info_v4 r = {0};
    if (proc_pid_rusage(getpid(), RUSAGE_INFO_V4, (rusage_info_t *)&r) == 0) {
        p.available = 1; p.pageins = r.ri_pageins;
        p.resident = r.ri_resident_size; p.footprint = r.ri_phys_footprint;
    }
    struct rusage u = {0};
    if (getrusage(RUSAGE_SELF, &u) == 0) {
        p.minor_faults = u.ru_minflt; p.major_faults = u.ru_majflt;
    }
    return p;
}
