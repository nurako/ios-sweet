/*
 * The MiniIOSurface side of the ios-sweet adapter, phase 2.
 *
 * We do NOT build the reference's MiniIOSurface.cpp: it defines a second
 * IOSurfaceRootUserClient, which would collide with SweetSurface.cpp's (the
 * working display/HID path). Instead, MiniIOSurfaceCopy() wraps the existing
 * SweetSurface for the same IOSurface id and fills the fields hakios.gpu.cpp
 * reads. The wrapper is an ordinary MiniIOSurface object with an extra
 * `sweet_surface` pointer (MiniIOSurface.h); Drop releases it.
 *
 * What the GPU service sees:
 *   client        the SweetSurface's IOMemoryDescriptor (pixels)
 *   kpixels       kernel VA of those pixels
 *   kbase         the SweetSurface state page, so shared()->seed is the same
 *                 seed the IOSurface framework/lock path moves (offset 0xc)
 *   info          geometry and allocSize copied from the SweetSurface
 *   scanPhys      non-zero only for the physical panel surface (its memory is
 *                 an IOMemoryDescriptor, not an IOBufferMemoryDescriptor)
 *
 * With gpu_wrap defaulting to 1 (hakios.gpu.cpp) surfaceBuffer() takes the
 * wrap path for every buffer-backed surface: IOSubMemoryDescriptor over the
 * SweetSurface pixels from offset 0, entered into the GPU's address space.
 */
#include "MiniIOSurface.h"
#include "arm/SweetSurface.h"

#include <IOKit/IOLib.h>
#include <libkern/c++/OSObject.h>

OSDefineMetaClassAndStructors(MiniIOSurface, OSObject);

static uint8_t sweet_minisurf_zero[MINISURF_AUX_OFFSET + sizeof(struct minisurf_aux)];

void
MiniIOSurface::free(void)
{
	SweetSurface *sweet = (SweetSurface *)sweet_surface;

	if (sweet != NULL) {
		sweet->release();
		sweet_surface = NULL;
	}
	OSObject::free();
}

void
MiniIOSurface::updateValuesState(void)
{
	/* No per-surface values dictionary in this adapter. */
}

extern "C" void
loader_log_line(const char *line)
{
	printf("%s", line);
}

MiniIOSurface *
MiniIOSurfaceCopy(uint32_t sid)
{
	static uint64_t told;
	SweetSurface *sweet = sweet_surface_copy(sid);
	MiniIOSurface *m;

	if (sweet == NULL) {
		return NULL;
	}
	m = OSTypeAlloc(MiniIOSurface);
	if (m == NULL || !m->init()) {
		OSSafeReleaseNULL(m);
		sweet->release();
		return NULL;
	}
	m->sid = sweet->id;
	m->holders = 1;
	m->memory = OSDynamicCast(IOBufferMemoryDescriptor, sweet->memory);
	m->client = sweet->memory;
	m->clientMap = NULL;
	m->clientTask = NULL;
	m->clientTaskID = 0;
	m->clientAddress = 0;
	m->kpixels = (uint8_t *)sweet->kernelAddress();
	m->kbase = sweet->state != NULL ? (uint8_t *)sweet->state->getBytesNoCopy() : sweet_minisurf_zero;
	m->drawn = 0;
	m->gpu_written = false;
	m->gpu_only = false;
	m->drawn_moves = 0;
	m->scanPhys = m->memory == NULL ? 1 : 0;        /* physical panel memory */
	m->values = NULL;
	m->useCount[0] = m->useCount[1] = 0;
	m->purgeable = 0;
	m->traced = false;
	m->readMap = NULL;
	m->kreadPixels = NULL;

	m->info.base = 0;
	m->info.shared = 0;
	m->info.aux = 0;
	m->info.sid = sweet->id;
	m->info.allocSize = sweet->allocSize;
	m->info.width = sweet->width;
	m->info.height = sweet->height;
	m->info.bytesPerRow = sweet->bytesPerRow;
	m->info.offset = sweet->offset;
	m->info.pixelFormat = sweet->pixelFormat;
	m->info.planeCount = sweet->planeCount;
	m->info.bytesPerElement = sweet->bytesPerElement;
	m->info.elementWidth = sweet->elementWidth;
	m->info.elementHeight = sweet->elementHeight;

	for (uint32_t i = 0; i < sweet->planeCount && i < MINISURF_MAX_PLANES; i++) {
		m->planes[i].width = sweet->planes[i].width;
		m->planes[i].height = sweet->planes[i].height;
		m->planes[i].offset = sweet->planes[i].offset;
		m->planes[i].bytesPerRow = sweet->planes[i].bytesPerRow;
		m->planes[i].size = sweet->planes[i].size;
		m->planes[i].bytesPerElement = sweet->planes[i].bytesPerElement;
		m->planes[i].elementWidth = sweet->planes[i].elementWidth;
		m->planes[i].elementHeight = sweet->planes[i].elementHeight;
	}

	m->sweet_surface = sweet;
	if (told++ < 8) {
		IOLog("HakiosGPU: surface %u wrapped as MiniIOSurface: %ux%u fmt %#x bpr %u size %u%s\n",
		    sid, sweet->width, sweet->height, sweet->pixelFormat, sweet->bytesPerRow,
		    sweet->allocSize, m->scanPhys != 0 ? " (physical panel memory)" : "");
	}
	return m;
}

MiniIOSurface *
MiniIOSurfaceCreateSimple(uint32_t width, uint32_t height, uint32_t pixelFormat)
{
	/* Not used by hakios.gpu.cpp; IOSurface creation stays with SweetSurface's
	 * IOSurfaceRootUserClient (IOSurface.framework). */
	(void)width;
	(void)height;
	(void)pixelFormat;
	return NULL;
}

mach_port_name_t
MiniIOSurfaceMakeSendRight(task_t task, MiniIOSurface *surface)
{
	SweetSurface *sweet;

	if (surface == NULL || surface->sweet_surface == NULL) {
		return 0;
	}
	sweet = (SweetSurface *)surface->sweet_surface;
	return sweet_surface_port_in_task(sweet, task);
}

void
MiniIOSurfaceDrop(MiniIOSurface *surface)
{
	if (surface != NULL) {
		surface->release();
	}
}
