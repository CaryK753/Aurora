#include <stdint.h>
int read_cpu_ticks(uint64_t *ticks, uint64_t *start);
int read_cpu_nanoseconds(uint64_t *nanoseconds);
uint64_t busy_work(uint64_t seed);
