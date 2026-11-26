/* Host-only syntax-check stand-in for <sys/sysctl.h>. */
#ifndef HAKIOS_CHECK_SYSCTL_H
#define HAKIOS_CHECK_SYSCTL_H

#include <stddef.h>

int sysctlbyname(const char *name, void *oldp, size_t *oldlenp,
    void *newp, size_t newlen);

#endif
