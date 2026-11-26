/* Host-only syntax-check stand-in for <mach/mach_time.h>. */
#ifndef HAKIOS_CHECK_MACH_TIME_H
#define HAKIOS_CHECK_MACH_TIME_H

#include <stdint.h>

typedef struct mach_timebase_info {
	uint32_t numer;
	uint32_t denom;
} mach_timebase_info_data_t;

int mach_timebase_info(mach_timebase_info_data_t *info);
uint64_t mach_absolute_time(void);

#endif
