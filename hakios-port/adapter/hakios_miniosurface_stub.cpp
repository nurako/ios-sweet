/*
 * Stand-ins for the two MiniIOSurface helpers the GPU service calls, for a
 * first compile-only evaluation.
 *
 * This tree already has its own IOSurface implementation
 * (iokit/Kernel/arm/SweetSurface.cpp, class IOSurfaceRootUserClient). The
 * reference's MiniIOSurface.cpp defines a second IOSurfaceRootUserClient with
 * the same C++ names, so building both would be a duplicate-symbol link error.
 * Phase 1 therefore builds the GPU service against MiniIOSurface.h only, with
 * these four entry points as stubs; putting surfaces into the GPU's address
 * space is not usable until the two implementations are merged (PORT-NOTES.md).
 *
 * When the merge happens, delete this file and build MiniIOSurface.cpp instead.
 */
#include "MiniIOSurface.h"

extern "C" void
loader_log_line(const char *line)
{
	printf("%s", line);
}

MiniIOSurface *
MiniIOSurfaceCopy(uint32_t sid)
{
	printf("HAKIOS GPU: MiniIOSurfaceCopy(%u): the MiniIOSurface/SweetSurface merge is not done yet\n", sid);
	return NULL;
}

void
MiniIOSurfaceDrop(MiniIOSurface *surface)
{
	(void)surface;
}

MiniIOSurface *
MiniIOSurfaceCreateSimple(uint32_t width, uint32_t height, uint32_t pixelFormat)
{
	printf("HAKIOS GPU: MiniIOSurfaceCreateSimple(%ux%u, %#x) not implemented\n", width, height, pixelFormat);
	return NULL;
}

mach_port_name_t
MiniIOSurfaceMakeSendRight(task_t task, MiniIOSurface *surface)
{
	(void)task;
	(void)surface;
	return 0;
}
