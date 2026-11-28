/* Host-only syntax-check extra: Darwin declares getprogname() in <stdlib.h>,
 * glibc does not. Included with -include by the check command. */
#ifndef HAKIOS_CHECK_COMPAT_H
#define HAKIOS_CHECK_COMPAT_H
const char *getprogname(void);
#endif
