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
 *   - gic_v3_spi_*()       a small GICv3 SPI path of our own (the tree's
 *                          pe_fiq.c already owns the GIC, but keeps its bases
 *                          private), opt-in through the driver's gpu_irq=1;
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
#include <pexpert/arm/protos.h>
#include <console/video_console.h>
#include <arm/machine_routines.h>
#include <vm/pmap.h>
#include <kern/simple_lock.h>
#include <os/atomic_private.h>
#include <IOKit/IOInterrupts.h>

extern vm_offset_t ml_io_map(vm_offset_t phys_addr, vm_size_t size);

/* ---- the reference driver's logging and loader hooks -------------------- */

/* bsd/dev/sweet_ufs.c: the persistent console ring read by sweetlogdump. */
extern void sweet_log_append(const char *c, int size);

/*
 * The reference tree mirrors the kernel log into a 64 KiB loader ring
 * (osfmk/arm64/loader_return.c) and its USB driver streams that ring. Keep
 * one copy here, shared with hakios-port-usb; every byte also goes into the
 * persistent sweet console ring so either can be read back after a boot.
 */
#define HAKIOS_LOADER_LOG_TEE (64 * 1024)
char loader_log_tee[HAKIOS_LOADER_LOG_TEE];
volatile uint64_t loader_log_tee_total;

void
loader_log_putc(char c)
{
	uint64_t at = __atomic_fetch_add(&loader_log_tee_total, 1, __ATOMIC_RELEASE);

	loader_log_tee[at % HAKIOS_LOADER_LOG_TEE] = c;
	sweet_log_append(&c, 1);
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

/*
 * The kernel text console already mapped the boot framebuffer with
 * ml_io_map_unmappable() (osfmk/console/video_console.c, initialize_screen)
 * and keeps the virtual address in the global `vinfo': 0x9c000000,
 * 1080x2400, stride 4320. That mapping is WCOMB, lives outside the 8 MB io
 * submap, and is writable here, so reuse it. Do NOT ml_io_map() the 10.4 MB
 * framebuffer: io_map's submap is only 8 MB and the call fails with
 * KERN_NO_SPACE (a panic on the way).
 */
extern struct vc_info vinfo;

/*
 * Whether `phys` (for `size` bytes) may be handed to the GPU's SMMU: it must
 * be kernel-managed DRAM (pmap_valid_address -- this kernel maps only the high
 * bank, 0x1_00000000.., through phystokv/phystokv_range), or, for a scan-out
 * buffer only, the boot framebuffer that the console already mapped.
 *
 * Anything else -- in particular the reserved region below 0x80000000 and the
 * GPU address window (0x20000000..0x1_00000000, where 0x50304000 lives) -- is
 * an address that phystokv_range() is required to panic on. A user client
 * must never be able to make the kernel convert one, so buffers carrying such
 * a value are refused while they are still only a request.
 */
extern boolean_t pmap_valid_address(uint64_t addr);
bool
hakios_gpu_phys_ok(uint64_t phys, uint64_t size, bool scanout)
{
	uint64_t fb = vinfo.v_physaddr;
	uint64_t fb_size = (uint64_t)vinfo.v_rowbytes * vinfo.v_height;

	if (phys == 0 || size == 0 || phys + size < phys) {
		return false;                   /* no address, or a range that wraps */
	}
	if (pmap_valid_address(phys) && pmap_valid_address(phys + size - 1)) {
		return true;                    /* kernel-managed, and in the linear map */
	}
	return scanout && fb != 0 && fb_size != 0 && phys >= fb && phys + size <= fb + fb_size;
}

void
MiniIOMobileFramebufferShow(const uint8_t *pixels, uint32_t width, uint32_t height, uint32_t row_bytes)
{
	static bool said;
	uint8_t *dst = (uint8_t *)vinfo.v_baseaddr;
	uint32_t dst_row = vinfo.v_rowbytes;
	uint32_t src_row = row_bytes != 0 ? row_bytes : width * 4u;
	uint32_t rows, bytes;

	if (pixels == NULL || dst == NULL || vinfo.v_width == 0 || vinfo.v_height == 0 ||
	    dst_row == 0 || src_row == 0) {
		if (!said) {
			said = true;
			printf("HAKIOS GPU: panel copy skipped: no writable console framebuffer "
			    "(vinfo base %p, %ux%u stride %u)\n", (void *)vinfo.v_baseaddr,
			    vinfo.v_width, vinfo.v_height, vinfo.v_rowbytes);
		}
		return;
	}
	rows = height < vinfo.v_height ? height : vinfo.v_height;
	bytes = (width < vinfo.v_width ? width : vinfo.v_width) * 4u;
	if (bytes > dst_row) {
		bytes = dst_row;
	}
	if (bytes > src_row) {
		bytes = src_row;
	}
	for (uint32_t y = 0; y < rows; y++) {
		memcpy(dst + (size_t)y * dst_row, pixels + (size_t)y * src_row, bytes);
	}
	/* The mapping is write-combined: make sure the stores reach the panel. */
	__asm__ volatile("dsb sy" ::: "memory");
	if (!said) {
		said = true;
		printf("HAKIOS GPU: panel copy %ux%u row %u -> %ux%u row %u via the console "
		    "framebuffer mapping (vinfo %p, phys %#llx)\n", width, height, src_row,
		    vinfo.v_width, vinfo.v_height, dst_row, (void *)vinfo.v_baseaddr,
		    (unsigned long long)vinfo.v_physaddr);
	}
}

/* ---- GICv3 shared peripheral interrupts -------------------------------- */

/*
 * A small SPI path for the GPU's INTID 332 (alioth live.dts kgsl-3d0:
 * interrupts = <0 0x12c 4>, SPI 300, level). This tree's pe_fiq.c already
 * brings up the GICv3 CPU interface and GICD/GICR, but keeps those bases
 * static. We map the 64 KiB distributor once (well inside the 8 MB io
 * submap), configure and route the SPI to the processor that attaches it,
 * and install one dispatcher through ml_install_interrupt_handler().
 *
 * sleh_irq() already handles the virtual timer and SGIs itself and sends
 * every other INTID to that one handler; our dispatcher looks the INTID up
 * in this table and otherwise does nothing, so existing polling drivers see
 * exactly the behaviour they saw before. The path is opt-in: only
 * hakios.adreno.c's gpu_irq=1 calls gic_v3_spi_attach().
 */
#define GICD_CTLR               0x0000
#define GICD_CTLR_RWP           (1u << 31)
#define GICD_IGROUPR(n)         (0x0080 + 4 * (n))
#define GICD_ISENABLER(n)       (0x0100 + 4 * (n))
#define GICD_ICENABLER(n)       (0x0180 + 4 * (n))
#define GICD_ICPENDR(n)         (0x0280 + 4 * (n))
#define GICD_ICACTIVER(n)       (0x0380 + 4 * (n))
#define GICD_IPRIORITYR(n)      (0x0400 + (n))
#define GICD_ICFGR(n)           (0x0c00 + 4 * (n))
#define GICD_IGRPMODR(n)        (0x0d00 + 4 * (n))
#define GICD_IROUTER(n)         (0x6000 + 8 * (n))
#define GIC_INTID_SPI_MIN       32u
#define GIC_INTID_SPURIOUS_MIN  1020u
#define GIC_PRIORITY_DEFAULT    0xa0u
#define GIC_SPI_MOST            8u

struct sweet_gic_spi {
	uint32_t intid;
	void   (*handler)(void *context, uint32_t intid);
	void    *context;
	uint32_t busy;
};

static vm_offset_t sweet_gicd;
static struct sweet_gic_spi sweet_gic_spi[GIC_SPI_MOST];
static decl_simple_lock_data(, sweet_gic_spi_lock);
static bool sweet_gic_spi_lock_ready;
static bool sweet_gic_handler_installed;

static inline uint32_t
sweet_gic_read32(vm_offset_t at)
{
	return *(volatile uint32_t *)at;
}

static inline void
sweet_gic_write32(vm_offset_t at, uint32_t value)
{
	*(volatile uint32_t *)at = value;
}

static void
sweet_gic_settle(void)
{
	while (sweet_gic_read32(sweet_gicd + GICD_CTLR) & GICD_CTLR_RWP) {
		;
	}
}

static bool
sweet_gic_map(void)
{
	DTEntry entry;
	const void *prop;
	unsigned int size;
	uint64_t reg[4];

	if (sweet_gicd != 0) {
		return true;
	}
	if (SecureDTLookupEntry(NULL, "/arm-io/gic", &entry) != kSuccess ||
	    SecureDTGetProperty(entry, "reg", &prop, &size) != kSuccess ||
	    size < sizeof(reg)) {
		return false;
	}
	memcpy(reg, prop, sizeof(reg));
	sweet_gicd = ml_io_map(pe_arm_get_soc_base_phys() + reg[0], (vm_size_t)reg[1]);
	return sweet_gicd != 0;
}

/* sleh_irq()'s OTHER-interrupt callback: the GPU's SPI, if it is ours. */
static void
sweet_gic_spi_interrupt(__unused void *target, __unused void *refCon, __unused void *nub, int source)
{
	uint32_t intid = (uint32_t)source;

	for (unsigned i = 0; i < GIC_SPI_MOST; i++) {
		struct sweet_gic_spi *spi = &sweet_gic_spi[i];

		if (os_atomic_load(&spi->intid, acquire) == intid) {
			os_atomic_inc(&spi->busy, relaxed);
			if (os_atomic_load(&spi->intid, relaxed) == intid && spi->handler != NULL) {
				spi->handler(spi->context, intid);
			}
			os_atomic_dec(&spi->busy, release);
			return;
		}
	}
	/* Not an SPI of ours: sleh_irq() ends it exactly as it did before. */
}

kern_return_t
gic_v3_spi_attach(uint32_t intid, bool edge, void (*handler)(void *context, uint32_t intid), void *context)
{
	struct sweet_gic_spi *slot = NULL;
	uint64_t mpidr;
	uint32_t config;

	if (intid < GIC_INTID_SPI_MIN || intid >= GIC_INTID_SPURIOUS_MIN || handler == NULL) {
		return KERN_INVALID_ARGUMENT;
	}
	if (!sweet_gic_map()) {
		printf("HAKIOS GPU: GICD map failed: SPI %u cannot be attached\n", intid);
		return KERN_RESOURCE_SHORTAGE;
	}
	if (!sweet_gic_spi_lock_ready) {
		simple_lock_init(&sweet_gic_spi_lock, 0);
		sweet_gic_spi_lock_ready = true;
	}
	simple_lock(&sweet_gic_spi_lock, LCK_GRP_NULL);
	for (unsigned i = 0; i < GIC_SPI_MOST; i++) {
		if (sweet_gic_spi[i].intid == intid) {
			simple_unlock(&sweet_gic_spi_lock);
			return KERN_NAME_EXISTS;
		}
		if (slot == NULL && sweet_gic_spi[i].intid == 0 && sweet_gic_spi[i].busy == 0) {
			slot = &sweet_gic_spi[i];
		}
	}
	if (slot == NULL) {
		simple_unlock(&sweet_gic_spi_lock);
		return KERN_RESOURCE_SHORTAGE;
	}
	slot->handler = handler;
	slot->context = context;
	os_atomic_store(&slot->intid, intid, release);
	simple_unlock(&sweet_gic_spi_lock);

	if (!sweet_gic_handler_installed) {
		ml_install_interrupt_handler(NULL, 0, NULL, sweet_gic_spi_interrupt, NULL);
		sweet_gic_handler_installed = true;
	}

	/* Disabled while it is configured; nothing stale pending or active. */
	sweet_gic_write32(sweet_gicd + GICD_ICENABLER(intid / 32), 1u << (intid % 32));
	sweet_gic_write32(sweet_gicd + GICD_ICPENDR(intid / 32), 1u << (intid % 32));
	sweet_gic_write32(sweet_gicd + GICD_ICACTIVER(intid / 32), 1u << (intid % 32));
	sweet_gic_write32(sweet_gicd + GICD_IGROUPR(intid / 32),
	    sweet_gic_read32(sweet_gicd + GICD_IGROUPR(intid / 32)) | 1u << (intid % 32));
	sweet_gic_write32(sweet_gicd + GICD_IGRPMODR(intid / 32),
	    sweet_gic_read32(sweet_gicd + GICD_IGRPMODR(intid / 32)) & ~(1u << (intid % 32)));
	*(volatile uint8_t *)(sweet_gicd + GICD_IPRIORITYR(intid)) = GIC_PRIORITY_DEFAULT;
	config = sweet_gic_read32(sweet_gicd + GICD_ICFGR(intid / 16)) & ~(3u << (intid % 16 * 2));
	sweet_gic_write32(sweet_gicd + GICD_ICFGR(intid / 16),
	    config | (edge ? 2u : 0u) << (intid % 16 * 2));
	mpidr = __builtin_arm_rsr64("MPIDR_EL1");
	*(volatile uint64_t *)(sweet_gicd + GICD_IROUTER(intid)) =
	    (mpidr & 0xff00000000ull) | (mpidr & 0xffffffull);
	sweet_gic_settle();
	sweet_gic_write32(sweet_gicd + GICD_ISENABLER(intid / 32), 1u << (intid % 32));
	printf("HAKIOS GPU: GIC SPI %u %s attached, routed to MPIDR %#llx (gpu_irq=1)\n",
	    intid, edge ? "edge" : "level", (unsigned long long)mpidr);
	return KERN_SUCCESS;
}

void
gic_v3_spi_mask(uint32_t intid)
{
	if (sweet_gicd != 0 && intid >= GIC_INTID_SPI_MIN && intid < GIC_INTID_SPURIOUS_MIN) {
		sweet_gic_write32(sweet_gicd + GICD_ICENABLER(intid / 32), 1u << (intid % 32));
		sweet_gic_settle();
	}
}

void
gic_v3_spi_detach(uint32_t intid)
{
	if (sweet_gicd == 0 || intid < GIC_INTID_SPI_MIN || intid >= GIC_INTID_SPURIOUS_MIN) {
		return;
	}
	gic_v3_spi_mask(intid);
	sweet_gic_write32(sweet_gicd + GICD_ICPENDR(intid / 32), 1u << (intid % 32));
	for (unsigned i = 0; i < GIC_SPI_MOST; i++) {
		if (sweet_gic_spi[i].intid == intid) {
			os_atomic_store(&sweet_gic_spi[i].intid, 0, release);
			while (os_atomic_load(&sweet_gic_spi[i].busy, acquire) != 0) {
				;
			}
		}
	}
}
