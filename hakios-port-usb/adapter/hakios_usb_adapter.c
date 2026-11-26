/*
 * hakios-port-usb: the few symbols xiongnemo/hakios-alioth's USB files expect
 * from the rest of their kernel, implemented against this tree.
 *
 * Nothing here is on the default boot path: hakios_usb_init() is only called
 * when the `usbhakios=1` boot argument is present (see 0300-hakios-usb.patch).
 *
 *   hakios_smmu_lock          serializes the read-only apps-SMMU walk in
 *                             hakios.usb.c (their SMMU driver owns it upstream)
 *
 * On hakios-all the GPU patch (0200) already supplies hakios_board_is_alioth()
 * / hakios_board_panel_height() (hakios.board.c) and the loader log tee
 * (hakios_gpu_adapter.c), so this adapter must not define them again.
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

/*
 * The loader log tee and loader_log_putc() live in the GPU adapter
 * (hakios-port/adapter/hakios_gpu_adapter.c) because hakios.adreno.c needs the
 * same symbols; 0300 is applied after 0200, so there is exactly one copy.
 * hakios.usb.c still streams loader_log_tee/loader_log_tee_total from there.
 */

/* Their SMMU driver owns this mutex upstream; the USB walk only reads. */
static LCK_GRP_DECLARE(hakios_smmu_lck_grp, "hakios-smmu");
LCK_MTX_DECLARE(hakios_smmu_lock, &hakios_smmu_lck_grp);
