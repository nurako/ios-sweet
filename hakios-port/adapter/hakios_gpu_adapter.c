/*
 * Adapter between xiongnemo/hakios-alioth's GPU stack and this tree.
 *
 * The reference driver (bsd/dev/hakios.adreno.c) and its IOKit service
 * (iokit/Kernel/hakios.gpu.cpp) were written for a port that keeps its
 * firmware in a ramdisk image and has helpers this tree does not:
 *
 *   - hakios_image_file()  served from the ADT /sweet-gpu properties that
 *                          mkadt.py --gmu-fw/--sqe-fw/--zap-mdt/--zap-seg
 *                          already put next to the homegrown probe;
 *   - announce()/hakios_tl()/loader_log_putc()  routed to printf;
 *   - gic_v3_spi_*()       stubbed (this tree has no GICv3 driver yet, so the
 *                          GPU interrupt falls back to the driver's polling
 *                          path; see PORT-NOTES.md);
 *   - Misc. kernel-wide state the reference tree keeps in other drivers.
 *
 * Nothing here touches research/ci-buildtree: it is copied there only for a
 * local xnu-cc.py syntax check.
 */
#include <sys/param.h>
#include <sys/systm.h>
#include <sys/types.h>
#include <mach/mach_types.h>
#include <mach/kern_return.h>
#include <pexpert/pexpert.h>
#include <pexpert/device_tree.h>

/* ---- the reference driver's logging and loader hooks -------------------- */

void
loader_log_putc(char c)
{
	/* The reference tree mirrors the kernel log into its UEFI loader ring.
	 * This tree reads the console ring back with sweetlogdump instead. */
	(void)c;
}

void
loader_return(void)
{
	printf("HAKIOS GPU: loader_return() requested; this tree has no UEFI loader to return to\n");
}

void
hakios_tl(const char *format, ...)
{
	char line[512];
	va_list list;

	va_start(list, format);
	vsnprintf(line, sizeof(line), format, list);
	va_end(list);
	printf("%s", line);
}

/* ---- kernel-wide state the reference keeps in other drivers ------------ */

volatile bool hakios_screen_off = false;        /* bsd/dev/hakios.cpufreq.c in the reference */
volatile uint64_t hakios_input_at = 0;          /* bsd/dev/hakios.input.c in the reference */

void
hakios_data_range(uint32_t *size_mb, uint32_t *used_mb, uint32_t *hole_mb)
{
	/* The reference reports its data partition's occupancy; not needed for
	 * the GPU's own accounting. */
	if (size_mb != NULL) {
		*size_mb = 0;
	}
	if (used_mb != NULL) {
		*used_mb = 0;
	}
	if (hole_mb != NULL) {
		*hole_mb = 0;
	}
}

/* ---- firmware from the ADT /sweet-gpu properties ----------------------- */

/*
 * mkadt.py writes these names (tools/mkadt.py):
 *   zap-metadata  a650_zap.mdt
 *   zap-segment   a650_zap.b02
 *   gmu-firmware  a650_gmu.bin
 *   sqe-firmware  a650_sqe.fw
 * The reference asks for the same files by their vendor names under fw/.
 */
static const struct {
	const char *name;
	const char *property;
} gpu_files[] = {
	{ "a650_gmu.bin", "gmu-firmware" },
	{ "a650_sqe.fw",  "sqe-firmware" },
	{ "a650_zap.mdt", "zap-metadata" },
	{ "a650_zap.b02", "zap-segment" },
	/* The reference also knows the A660/Yupik set; this phone has the A650,
	 * but keep the names so the driver's profile probe answers truthfully. */
	{ "a660_gmu.bin", "gmu-firmware" },
	{ "a660_sqe.fw",  "sqe-firmware" },
	{ "a660_zap.mdt", "zap-metadata" },
	{ "a660_zap.b02", "zap-segment" },
};

const uint8_t *
hakios_image_file(const char *dir, const char *name, uint64_t *size, int *disk_out)
{
	DTEntry node;
	const void *prop;
	unsigned int length;

	if (disk_out != NULL) {
		*disk_out = -1;
	}
	if (size != NULL) {
		*size = 0;
	}
	if (dir == NULL || name == NULL || strcmp(dir, "fw") != 0) {
		return NULL;
	}
	if (SecureDTLookupEntry(NULL, "/sweet-gpu", &node) != kSuccess) {
		return NULL;
	}
	for (size_t i = 0; i < sizeof(gpu_files) / sizeof(gpu_files[0]); i++) {
		if (strcmp(name, gpu_files[i].name) != 0) {
			continue;
		}
		if (SecureDTGetProperty(node, gpu_files[i].property, &prop, &length) != kSuccess ||
		    prop == NULL || length == 0) {
			return NULL;
		}
		if (size != NULL) {
			*size = length;
		}
		return (const uint8_t *)prop;
	}
	return NULL;
}

/* ---- the panel copy the reference's 2D test asks for ------------------- */

void
MiniIOMobileFramebufferShow(const uint8_t *pixels, uint32_t width, uint32_t height, uint32_t row_bytes)
{
	static bool said;

	if (!said) {
		said = true;
		printf("HAKIOS GPU: show %ux%u (%u bytes a row) requested; the adapter has no "
		    "MiniIOMobileFramebuffer bridge yet (use a later patch to hand it to AppleCLCD)\n",
		    width, height, row_bytes);
	}
	(void)pixels;
}

/* ---- GICv3 shared peripheral interrupts -------------------------------- */

/*
 * This tree has no gic_v3_irq.c: the reference adds one in xnu/hakios.patch and
 * drives the CPU interface through ICC_*_EL1 with a redistributor per CPU.
 * Until that is ported, the GPU's INTID 332 cannot be attached; the reference
 * driver sees the failure and keeps polling for its fence (hakios.adreno.c,
 * gpu_irq_on()), so the service still works without the interrupt.
 */
kern_return_t
gic_v3_spi_attach(uint32_t intid, bool edge, void (*handler)(void *context, uint32_t intid), void *context)
{
	static bool said;

	if (!said) {
		said = true;
		printf("HAKIOS GPU: GICv3 SPI %u (%s) not attached: no GICv3 driver in this tree yet; "
		    "the GPU will poll for its fence\n", intid, edge ? "edge" : "level");
	}
	(void)handler;
	(void)context;
	return KERN_FAILURE;
}

void
gic_v3_spi_mask(uint32_t intid)
{
	(void)intid;
}

void
gic_v3_spi_detach(uint32_t intid)
{
	(void)intid;
}
