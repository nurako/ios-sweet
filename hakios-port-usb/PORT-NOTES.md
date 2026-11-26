# Port notes: xiongnemo/hakios-alioth USB stack -> ios-sweet (hakios-usb branch)

Status: **phase 1, compile-only evaluation**. The reference USB sources and their
one header compile against this tree (main at `f8d920a`, plus the small adapter
in `adapter/`). The port is opt-in behind `usbhakios=1`; the default boot path is
unchanged. Nothing is pushed or booted from this branch.

## 1. What was imported

All files are copied verbatim from **xiongnemo/hakios-alioth**, branch `alioth`
(commit `acdb175e`, 2026-11-26); see `ORIGIN.md` for blob ids.

| Local file | Upstream path | Lines |
| --- | --- | --- |
| `kernel/bsd/dev/hakios.dwc3.c` | `devices/redmi-k40/overlays/xnu/files/bsd/dev/hakios.dwc3.c` | 949 |
| `kernel/bsd/dev/hakios.dwc3.h` | same directory | 128 |
| `kernel/bsd/dev/hakios.dwc3regs.h` | same directory | 633 |
| `kernel/bsd/dev/hakios.usb.c` | same directory, `hakios.usb.c` | 1086 |
| `kernel/bsd/dev/hakios.dwc3.LICENSE` | `hakios.dwc3.LICENSE` (m1n1/QcomXnuUsbDebug) | 22 |
| `kernel/iokit/Kernel/hakios.usbmux.cpp` | `.../iokit/Kernel/hakios.usbmux.cpp` | 77 |
| `kernel/bsd/sys/hakios.board.h` | `.../bsd/sys/hakios.board.h` | 33 |
| `reference-xnu-device.patch` | `devices/redmi-k40/xnu-device.patch` | 321 |
| `reference-boot.args` | `devices/redmi-k40/boot.args` | 1 |

`hakios.dwc3.c` is the device-side core (from FFT-infra/QcomXnuUsbDebug, itself
from Asahi m1n1): EP0/standard requests, a CDC-ACM serial port, an iPhone-style
usbmux interface, and a fastboot bulk interface. It is freestanding (only
`stdint.h`/`stddef.h` plus the two headers) and knows nothing about XNU.
`hakios.usb.c` is the XNU glue: boot-arg ladder, GCC/DWC3/QSCRATCH/SMMU reads,
`/dev/hakios-usb`, the polling thread, the log pump, and `usb=2`/`usb=3`.
`hakios.usbmux.cpp` publishes the `AppleUSBDeviceMux` IOService that lockdownd
matches.

## 2. Compile result (verified locally)

Base buildtree: xnu-buildtree artifact of **run 45663768795** (`main` at
`f8d920a`, i.e. exactly this branch's base). Compile-command log:
`gh run view 45670566657 -R nurako/ios-sweet --log > /tmp/ci-usb.log`.

```
XNU_CC_CLANG=/usr/bin/clang python3 tools/xnu-cc.py /tmp/ci-usb.log \
    research/ci-buildtree bsd/dev/hakios.usb.c bsd/dev/hakios.dwc3.c \
    bsd/dev/hakios_usb_adapter.c bsd/dev/sweet_ufs.c \
    iokit/Kernel/hakios.usbmux.cpp
-> 0 of 5 files failed
```

Also checked by applying `xnu/patches/0300-hakios-usb.patch` to a pristine
extraction of the same artifact (`git apply --check` OK) and compiling those
files in the patched tree: **0 of 5 failed**.

Link-level check (`XNU_CC_OBJDIR` + `llvm-nm`, compared with the artifact's
`config/allsymbols`): every custom symbol is defined by the imported objects,
the adapter, or `hakios.usbmux.cpp`. The only names not in `allsymbols` are
`lck_grp_startup_init` and `lck_mtx_startup_init`, private kernel startup
symbols that exist in the kernel sources (same class of "missing" the GPU port
recorded; `LCK_MTX_DECLARE` expands to them).

## 3. External symbols/headers: what the reference needs, and its state here

### 3.1 Provided by this tree already

`ml_io_map`, `kvtophys`, `kernel_thread_start`, `thread_set_thread_name`,
`thread_deallocate`, `thread_terminate`, `ml_get_interrupts_enabled`,
`mach_absolute_time`, `absolutetime_to_nanoseconds`,
`nanoseconds_to_absolutetime`, `PE_parse_boot_argn`, `PE_parse_boot_arg_str`,
`printf`/`snprintf`/`vsnprintf`, `cdevsw_add`, `devfs_make_node`, `msleep`,
`tsleep`, `wakeup`, `selrecord`, `selwakeup`, `uiomove`, `_uio_resid`,
`OSCompareAndSwap`, `SecureDTLookupEntry`/`SecureDTGetProperty`,
`enable_developer_mode` (not needed by USB), all standard BSD/kern/lck calls.
`hakios.dwc3.c` needs no kernel symbol at all.

### 3.2 Implemented by `adapter/hakios_usb_adapter.c`

| reference symbol | where it lives upstream | adapter behaviour |
| --- | --- | --- |
| `hakios_board_is_alioth()` | `bsd/dev/hakios.board.c` (reads `/chosen hakios-board`) | returns true when `usbhakios=1` is present, else does the same `/chosen` test. Our `tools/mkadt.py` does not emit the property yet |
| `hakios_board_panel_height()` | same | `2400` on alioth, `2340` otherwise (unused by USB, satisfies `hakios.board.h`) |
| `hakios_smmu_lock` | their SMMU driver (not in the USB files) | `LCK_MTX_DECLARE`; the USB path only takes it around its read-only apps-SMMU walk |
| `loader_log_putc(c)` | `osfmk/arm64/loader_return.c` | appends to a 64 KiB `loader_log_tee` ring (same size/contract as upstream) and to our persistent console ring via `sweet_log_append()` |
| `loader_log_tee`, `loader_log_tee_total` | same | the ring `hakios.usb.c` streams over `usb=2` |

`hakios_usbmux_publish()` / `hakios_usbmux_host()` are defined by the imported
`iokit/Kernel/hakios.usbmux.cpp`, so no stubs are needed.

### 3.3 Not supplied (functional gaps, not compile errors)

1. **PHY bring-up.** `hakios.usb.c` deliberately does not initialize a PHY or
   clocks: it assumes the loader already runs the link and then lends the
   controller (`usbfree=1`, `bootcpu=0`). Our boot is `fastboot boot` from ABL,
   and our own probe showed the **SNPS femto HS PHY is powered down after ABL**.
   `usb>=2` therefore needs our patch 0098 femto sequence
   (`sweet_usb.c: sweet_usb_phy_init`) exported and run before
   `hakios_usb_init()`. `usb=1` (read-only) does not need it.
2. **SMMU / DMA addresses.** The reference says the firmware leaves StreamID 0
   matched to a context bank with `SCTLR.M=0` (physical addresses work). Our
   earlier reading of S2CR0 on this phone was `type 2 = FAULT`, so the
   controller may not be able to fetch even kernel-image physical TRBs. Their
   `usb=1` output (`SMRn ... S2CR ... CB ... SCTLR.M`) decides which story is
   true now; if it says FAULT, either a secure (SCM) mapping or a mapping the
   secure side already installed is required, exactly like the GPU wall.
3. **`usb=3` host visibility.** Their `xnu-device.patch` also changes
   `bsd/netinet/tcp_usrreq.c` so a connection from the userland mux process is
   treated as "from the kernel" (pid 0), which lockdownd requires. That hunk is
   **not** in `0300`; add it before expecting pairing. Their
   `sysctl kern.bootargs` change (long cmdlines) is also not included.
4. **Shutdown/quiesce.** `hakios_usb_quiesce()` is called from their
   `loader_return.c`, which this tree does not have. With `usb>=2` the
   controller is left as the kernel left it on reboot; acceptable for a test
   boot, but a clean hand-back is a later step.
5. **Userland.** `/dev/hakios-usb` is served, but `usb=2` needs their `usbsh`
   and `usb=3` needs their `usbmux` in the iOS root, plus the
   `com.hakios.usbmux.plist` launchd job. Not ported here.
6. **Log tee vs console.** `loader_log_putc` carries the USB driver's own
   `say()` lines; the rest of the kernel console is in the sweet ring, not in
   `loader_log_tee`. So a `usb=2` serial log starts with USB lines only. A later
   adapter can feed `sweet_log_copy()` into `dwc3_queue()` instead.

## 4. Boot arguments and defaults

Their ladder is selected by `usb=N` (from `hakios.usb.c`; their `boot.args` does
not set it because their loader/userland choose it):

| arg | behaviour |
| --- | --- |
| `usb=1` | read-only: GCC power/clocks, DWC3 identity/role/state/event buffer, apps-SMMU stream 0. No writes. |
| `usb=2` | takes the controller: CDC-ACM serial (`1209:316d`), kernel log over USB, `/dev/hakios-usb`. |
| `usb=3` | same, but presents `05ac:12a8` "iPhone" with the usbmux interface; needs userland `usbmux` and the tcp hunk. |
| `usb_name=...` | serial-port product name (`_` = space). |
| `usbfree=1` | declares the loader has stopped its link and lent the controller. |
| `bootcpu=N` | if non-zero without `usbfree=1`, the driver leaves the controller to the loader. |

Our port adds **`usbhakios=1`** as the master switch: `sweet_ufs_init()` calls
`hakios_usb_init()` only when it is present, so no existing cmdline changes
behaviour. `usbhakios=1` also makes `hakios_board_is_alioth()` true without an
ADT change, so `usb=N` is the only other argument needed.

## 5. Build-system change (`xnu/patches/0300-hakios-usb.patch`)

Branch-only patch, generated from the `f8d920a` buildtree and checked with
`git apply --check` against a fresh extraction of it. It:

* adds the four imported sources, `hakios.board.h`, `hakios.usbmux.cpp` and
  the adapter;
* `bsd/conf/files`: adds `hakios.usb.c`, `hakios.dwc3.c`,
  `hakios_usb_adapter.c` (`standard`);
* `iokit/conf/files.arm64` (the arm64 list, not `iokit/conf/files`): adds
  `hakios.usbmux.cpp optional iokitcpp`;
* `bsd/dev/sweet_ufs.c`: declares `hakios_usb_init()` and calls it after
  `sweet_gpu_init()`, gated on `PE_parse_boot_argn("usbhakios", ...)`.

It does **not** modify `bsd/dev/sweet_usb.c`; our 0072-0101 probe/gadget and
its femto PHY sequence stay as they are. No new CFLAGS are needed.

## 6. Ordered plan

| # | step | state |
| --- | --- | --- |
| 0 | import files, adapter, this inventory, `0300` patch, compile check | **done (this branch)** |
| 1 | one CI run, then `usbhakios=1 usb=1` (read-only): read PHY/GDSC/clock state, DWC3 role, and the real SMMU S2CR/SCTLR for stream 0 | 1 boot |
| 2 | if the controller is powered but the PHY is off, export the 0098 femto init and run it before `hakios_usb_init()`; retry `usb=1`, then `usb=2` with a PC `lsusb` | 1-2 days |
| 3 | decide the SMMU route from step 1 (bypass already installed vs secure mapping); if FAULT, test the secure/SCM path or a secure-installed mapping | 1-3 days |
| 4 | `usb=2`: serial kernel log + `/dev/hakios-usb` (no userland needed); this is the first useful live log | 1 day |
| 5 | `usb=3`: add the `tcp_usrreq.c` hunk, port `usbmux`/`usbsh` and the launchd plist into the iOS root, verify lockdownd "Trust This Computer" | 2-4 days |

Honest stop points: after step 1 the log names exactly which block is off or
which SMMU type stream 0 has. After step 2 either a PC enumerates
`1209:316d`, or the log says the DWC3 still cannot start transfers. Only after
step 5 does the phone pair as an iPhone.

## 7. Evaluation boot (one bootable build)

ADT and payload as usual (no new ADT properties are required; `usbhakios=1`
stands in for `/chosen hakios-board`):

```
python3 tools/mkadt.py shim/out/alioth.adt --board alioth --highmem \
    --gmu-fw research/alioth-gpu/a650_gmu.bin \
    --sqe-fw research/alioth-gpu/a650_sqe.fw \
    --zap-mdt research/alioth-gpu/a650_zap.mdt \
    --zap-seg research/alioth-gpu/a650_zap.b02

python3 tools/mkpayload.py xnu/out/kernel.development.sweet shim/out/alioth.adt \
    shim/out/payload.bin --cmdline 'debug=0xc serial=3 cpus=8 keepsyms=1 \
-noprogress rd=ufsroot0 unentitled_ios_sim_launch=1 ignition_level=1 \
wdt_test=no_user_checkin ufsrw=1 rootrw=1 launchd_unsecure_cache=1 wdt=-1 \
sweettouch=1 sweettouchdelay=0 sweetkeys=1 sweetusb=0 \
usbhakios=1 usb=1'

cd shim && BOARD=alioth CC=clang OBJCOPY=llvm-objcopy NM=llvm-nm \
    READELF=llvm-readelf ./build.sh out/payload.bin
fastboot boot shim/out/shim-boot-alioth.img
```

Start with `usb=1` (read-only, safe on any boot). After the PHY step, use
`usb=2`; only then try `usb=3`. A following boot with
`sweetlogdump=262144 sweetloggrep=usb: sweetlogdumpwait=120 ufslogsecs=1`
(and `sweetusb=0`) reads the USB lines back from the persistent ring without a
photo of a scrolling screen.

Expected lines (all start with `usb:`): `level 1: a look, reading only`,
`GCC USB30_PRIM GDSC ...`, `DWC3 GSNPSID ...`, `SMRn ... S2CR ... type ...`,
and no `cannot map the registers` / `not a Redmi K40`.

## 8. Files added by this port

```
hakios-port-usb/kernel/...                 reference USB sources, verbatim
hakios-port-usb/adapter/hakios_usb_adapter.c
hakios-port-usb/ORIGIN.md                  provenance + licenses
hakios-port-usb/PORT-NOTES.md              this file
hakios-port-usb/reference-xnu-device.patch their build/glue patch (reference)
hakios-port-usb/reference-boot.args        their full boot args
xnu/patches/0300-hakios-usb.patch          branch-only build integration
```

Licenses: the device layer (`devices/redmi-k40/overlays/`) is MIT per the
upstream README; `hakios.dwc3.*` is MIT (m1n1/QcomXnuUsbDebug, notice kept);
XNU-derived headers keep Apple's APSL-2.0 notices. `adapter/` is new work under
this fork's license (see the repository `LICENSE`).
