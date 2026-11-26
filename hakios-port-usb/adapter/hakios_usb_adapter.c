/*
 * hakios-port-usb: the few symbols xiongnemo/hakios-alioth's USB files expect
 * from the rest of their kernel, implemented against this tree.
 *
 * Nothing here is on the default boot path: hakios_usb_init() is only called
 * when the `usbhakios=1` boot argument is present (see 0300-hakios-usb.patch).
 *
 *   hakios_board_is_alioth()  their /chosen hakios-board test, plus usbhakios=1
 *                             so this branch needs no ADT change to be tried
 *   hakios_smmu_lock          serializes the read-only apps-SMMU walk in
 *                             hakios.usb.c (their SMMU driver owns it upstream)
 *   loader_log_putc/tee       their loader log ring; here every byte also goes
 *                             into our persistent console ring (sweet_ufs.c)
 *                             so a session can be read back with sweetlogdump
 *
 * hakios_usbmux_publish()/hakios_usbmux_host() are defined by
 * iokit/Kernel/hakios.usbmux.cpp, which is built with this adapter.
 */
#include <sys/param.h>
#include <sys/systm.h>
#include <mach/vm_types.h>
#include <pexpert/pexpert.h>
#include <pexpert/device_tree.h>
#include <kern/locks.h>
#include <sys/hakios.board.h>

/* bsd/dev/sweet_ufs.c: the 4 MiB console ring read by sweetlogdump. */
extern void sweet_log_append(const char *c, int size);

/* Their loader log tee (osfmk/arm64/loader_return.c upstream): 64 KiB. */
#define HAKIOS_LOADER_LOG_TEE (64 * 1024)

char loader_log_tee[HAKIOS_LOADER_LOG_TEE];
volatile uint64_t loader_log_tee_total;

void
loader_log_putc(char c)
{
	uint64_t at = __atomic_fetch_add(&loader_log_tee_total, 1, __ATOMIC_RELEASE);

	loader_log_tee[at % HAKIOS_LOADER_LOG_TEE] = c;
	/* Never blocks; also survives the session in the UFS console ring. */
	sweet_log_append(&c, 1);
}

/* Their SMMU driver owns this mutex upstream; the USB walk only reads. */
static LCK_GRP_DECLARE(hakios_smmu_lck_grp, "hakios-smmu");
LCK_MTX_DECLARE(hakios_smmu_lock, &hakios_smmu_lck_grp);

bool
hakios_board_is_alioth(void)
{
	DTEntry chosen;
	const void *board;
	unsigned size;
	uint32_t opt_in = 0;

	/*
	 * tools/mkadt.py does not emit /chosen hakios-board on this tree, so the
	 * explicit boot argument is the switch; a future ADT property also works.
	 */
	if (PE_parse_boot_argn("usbhakios", &opt_in, sizeof(opt_in)) && opt_in != 0) {
		return true;
	}
	return SecureDTLookupEntry(NULL, "/chosen", &chosen) == kSuccess &&
	       SecureDTGetProperty(chosen, "hakios-board", &board, &size) == kSuccess &&
	       size == 7 && memcmp(board, "alioth", 7) == 0;
}

/* Their panel height helper; not used by the USB files, kept for the header. */
uint32_t
hakios_board_panel_height(void)
{
	return hakios_board_is_alioth() ? 2400 : 2340;
}
