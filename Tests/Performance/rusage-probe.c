#include <libproc.h>
#include <sys/resource.h>
#include <unistd.h>
#include <stdint.h>

int read_cpu_ticks(uint64_t *ticks, uint64_t *start) {
    struct rusage_info_v4 r;
    if (proc_pid_rusage(getpid(), RUSAGE_INFO_V4, (rusage_info_t *)&r) != 0) return -1;
    *ticks = r.ri_user_time + r.ri_system_time;
    *start = r.ri_proc_start_abstime;
    return 0;
}

int read_cpu_nanoseconds(uint64_t *nanoseconds) {
    struct rusage r;
    if (getrusage(RUSAGE_SELF, &r) != 0) return -1;
    *nanoseconds = ((uint64_t)r.ru_utime.tv_sec + (uint64_t)r.ru_stime.tv_sec) * 1000000000
                 + ((uint64_t)r.ru_utime.tv_usec + (uint64_t)r.ru_stime.tv_usec) * 1000;
    return 0;
}

uint64_t busy_work(uint64_t seed) {
    volatile uint64_t value = seed;
    for (unsigned i = 0; i < 32768; i++) value = value * 2862933555777941757ULL + 3037000493ULL;
    return value;
}
