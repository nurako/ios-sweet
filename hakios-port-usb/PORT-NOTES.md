# Port notes: xiongnemo/hakios-alioth USB stack -> ios-sweet (hakios-usb branch)

Status: **phase 2, shell/file path over USB** (phase 1 compile-only evaluation
below is still current). The reference USB sources and header compile against
this tree (main at `f8d920a`, plus the small adapter in `adapter/`), `usb=2`
enumerates on the phone, and phase 2 adds the `usb=3` kernel socket hunk plus
their `usbmux`/`usbsh` userland with build/install/host scripts. The port is
opt-in behind `usbhakios=1`; the default boot path is unchanged. Nothing is
pushed or booted from this branch.

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
3. **`usb=3` host visibility.** Their `xnu-device.patch` changes
   `bsd/netinet/tcp_usrreq.c` so a connection from the userland mux process is
   treated as "from the kernel" (pid 0), which lockdownd requires. **Done in
   phase 2** (part of `0300`). Their `sysctl kern.bootargs` change (long
   cmdlines) is not included: our 251-byte cmdline is below arm64's 608-byte
   `BOOT_LINE_LENGTH`, and `usbsh` only reads it to notice `usb=3`.
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
  `sweet_gpu_init()`, gated on `PE_parse_boot_argn("usbhakios", ...)`;
* `bsd/netinet/tcp_usrreq.c`: the pid-0 peer hunk from their
  `xnu-device.patch` — a connection whose peer is the process holding the
  `usb=3` iPhone port (`hakios_usb_mux_pid()`) is reported as coming from the
  kernel, which lockdownd requires.

It does **not** modify `bsd/dev/sweet_usb.c`; our 0072-0101 probe/gadget and
its femto PHY sequence stay as they are. No new CFLAGS are needed.

## 6. Ordered plan

| # | step | state |
| --- | --- | --- |
| 0 | import files, adapter, this inventory, `0300` patch, compile check | **done, phase 1** |
| 1 | `usbhakios=1 usb=1` (read-only): GCC/DWC3/SMMU report | **done on the phone** |
| 2 | `usb=2` enumerates as `1209:316d` and streams the kernel log over CDC-ACM | **done on the phone** (SMR0 written by the shim) |
| 3 | `usb=2` + `usbsh` in the root: shell and `b64` file download | **phase 2, needs the iOS SDK build + install** |
| 4 | `usb=3` + `usbmux` + the `tcp_usrreq.c` hunk: iPhone mux, lockdownd 62078, AFC/file access via host `ifuse` | **phase 2, kernel side done; needs the userland build + trust pairing** |

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

Three ladders, one kernel:

```
# usb=2: CDC-ACM shell + kernel log (the one that works on the phone now)
... usual args ... \
sweettouch=1 sweettouchdelay=0 sweetkeys=1 sweetusb=0 usbhakios=1 usb=2

# usb=3: iPhone mux for lockdownd/AFC (host usbmuxd; needs userland usbmux)
... usual args ... \
sweettouch=1 sweettouchdelay=0 sweetkeys=1 sweetusb=0 usbhakios=1 usb=3

# usb=1: read-only look, safe on any boot
... usual args ... \
sweettouch=1 sweettouchdelay=0 sweetkeys=1 sweetusb=0 usbhakios=1 usb=1
```

`usb=3` needs the shim's SMR0 = 0x80000000 write (main's `shim/loader.c`,
already in place for the working `usb=2`). Host side, after the userland is
installed:

```
# usb=2: shell and files (tools/sweet-usbsh.sh)
tools/sweet-usbsh.sh 'ls /'
tools/sweet-usbsh.sh -g /var/tmp/usbmux.log usbmux.log

# usb=3: the phone as an iPhone (Linux host)
sudo usbmuxd -f -v &
idevice_id -l                 # the UDID given to HAKIOS_USB_IPHONE
ideviceinfo                   # 62078: lockdownd (accept "Trust This Computer")
ifuse /mnt/ios                # AFC over the same mux, after pairing
```

A following boot with
`sweetlogdump=262144 sweetloggrep=usb: sweetlogdumpwait=120 ufslogsecs=1`
(and `sweetusb=0`) reads the USB lines back from the persistent ring without a
photo of a scrolling screen.

Expected lines (all start with `usb:`): for `usb=2`, `THE CONTROLLER IS THE
KERNEL'S: a serial port (1209:316d ...)`; for `usb=3`, `an iPhone (05ac:12a8,
serial ...) with Apple's usbmux interface`, `AppleUSBDeviceMux for lockdownd:
published`, then from userland `usb: the USB mux is process N: its connections
are the kernel's to lockdownd`.

## 8. Phase 2: shell and file access (`usb=2`/`usb=3`)

### 8.1 Kernel side

The imported `hakios.usb.c` already implements both device shapes and all the
ioctls the userland uses (`HAKIOS_USB_LOG`, `_IPHONE`, `_HOST`, `_GENERATION`,
`_NOTE`). Phase 2 adds only the missing `tcp_usrreq.c` hunk in `0300`: when
`tcp_lookup_peer_pid_locked()` sees the pid that called `HAKIOS_USB_IPHONE`, it
reports pid 0 to lockdownd. `hakios_usb_mux_pid()` is already defined in
`hakios.usb.c` (`-1` unless `usb=3`). No change to `sweet_usb.c`,
`sweet_gpu.c`, or the default boot.

Compile check for every touched kernel file (buildtree of run 45735232511,
which already contains phase 1's `0300`):

```
XNU_CC_CLANG=/usr/bin/clang python3 tools/xnu-cc.py /tmp/ci-usb2.log \
    research/ci-buildtree bsd/netinet/tcp_usrreq.c bsd/dev/hakios.usb.c \
    bsd/dev/hakios.dwc3.c bsd/dev/hakios_usb_adapter.c bsd/dev/sweet_ufs.c \
    iokit/Kernel/hakios.usbmux.cpp
-> 0 of 6 files failed
```

### 8.2 Userland sources and whether they build here

`hakios-port-usb/userland/src/usbmux.c` (670 lines) and `usbsh.c` (911) are
copied verbatim; their plists are beside them. **They cannot be built on this
Linux box**: they are normal dynamically linked arm64 iOS programs and need the
iPhoneOS SDK headers/libraries (CoreFoundation, MobileGestalt, libproc). There
is no SDK, theos, ld64 or ldid installed here. `build.sh` detects that and
stops with instructions.

Precise recipe (what the reference uses, and what we need):

| item | value |
| --- | --- |
| host | macOS with Xcode 15/16, or Linux/macOS with Theos + cctools/ld64 + ldid |
| SDK | **iPhoneOS16.5.sdk** (Theos) — it has CoreFoundation and a `libMobileGestalt.tbd`; a stock Xcode SDK may lack the private stub |
| flags | `clang -arch arm64 -isysroot <SDK> -miphoneos-version-min=16.0 -O2` |
| usbsh link | libSystem only (`proc_kmsgbuf` declared by hand in the source) |
| usbmux link | `-framework CoreFoundation -lMobileGestalt` |
| signing | ad-hoc: `ldid -S out/usbsh out/usbmux` (or `codesign -s -`) |
| entitlements | none required by the sources; miniamfi here does not enforce them. `usbmux` calls `MGCopyAnswer(UniqueDeviceID)`; if a stricter AMFI path is ever used, add `com.apple.private.MobileGestalt.AllowedProtectedKeys = [UniqueDeviceID]`. `usbsh cs` needs `com.apple.private.cs.debugger` to inspect other processes |
| install path | our root has no `/redwood`: binaries in `/usr/local/bin`, jobs in `/System/Library/LaunchDaemons` (override `JOBDIR=/Library/LaunchDaemons` if that is what your launchd scans) (`userland/install-root.sh` rewrites the plists) |
| launchd jobs | `com.hakios.usbsh` (`RunAtLoad`, usb=2) and `com.hakios.usbmux` (`RunAtLoad`, `KeepAlive.SuccessfulExit=false`, usb=3) |

```
cd hakios-port-usb/userland
IOS_SDK=~/theos/sdks/iPhoneOS16.5.sdk ./build.sh
./install-root.sh /path/to/mounted/ios/root
```

`usbsh` runs on **usb=2** (the CDC-ACM port); `usbmux` runs on **usb=3** (the
iPhone port). Both can be installed at once: the one whose boot argument is
absent exits at once (usbsh checks `kern.bootargs`; usbmux's `open()` fails).

### 8.3 Host side

`tools/sweet-usbsh.sh` speaks the usbsh line protocol on `/dev/ttyACM0`
(`-d`, `-b`, `-l`, `-t`; `-g REMOTE [LOCAL]` downloads via the builtin `b64`).
Its byte-level I/O is done by embedded Python 3 (`termios` + `select`), because
bash's `read -N` loses bytes at timeout boundaries and cannot preserve a bare
newline, which corrupts b64. File access is currently **read-only** (`ls`,
`cat`, `b64`): usbsh has no write builtin. Writes today go through a program it
can run, or through AFC over `usb=3` + `ifuse` after pairing. See
`docs/usb-shell.md` for the protocol and the host recipe.

### 8.4 Files added in phase 2

```
hakios-port-usb/userland/src/usbmux.c, usbsh.c     reference, verbatim
hakios-port-usb/userland/com.hakios.*.plist        reference launchd jobs
hakios-port-usb/userland/build.sh                  SDK build (macOS/Theos)
hakios-port-usb/userland/install-root.sh           install into our root
tools/sweet-usbsh.sh                               serial host client
docs/usb-shell.md                                  protocol + recipes
```

## 9. Files added by this port

```
hakios-port-usb/kernel/...                 reference USB sources, verbatim
hakios-port-usb/adapter/hakios_usb_adapter.c
hakios-port-usb/userland/...               reference usbmux/usbsh + scripts
hakios-port-usb/ORIGIN.md                  provenance + licenses
hakios-port-usb/PORT-NOTES.md              this file
hakios-port-usb/reference-xnu-device.patch their build/glue patch (reference)
hakios-port-usb/reference-boot.args        their full boot args
xnu/patches/0300-hakios-usb.patch          branch-only build integration
tools/sweet-usbsh.sh                       host client for usbsh
docs/usb-shell.md                          USB shell/mux docs
```

Licenses: the device layer (`devices/redmi-k40/overlays/`) is MIT per the
upstream README; `hakios.dwc3.*` is MIT (m1n1/QcomXnuUsbDebug, notice kept);
XNU-derived headers keep Apple's APSL-2.0 notices. `adapter/` is new work under
this fork's license (see the repository `LICENSE`).

## 8. Log-first port ownership (2026-11-26, revised)

Both launchd jobs check `usb=` in `kern.bootargs` **before** opening
`/dev/hakios-usb`:

* `usb=2` -> the kernel log owns the port. `usbsh` does not open it at boot;
  it blocks on `/dev/hakios-usb-shell`. `usbmux` exits 0 without opening.
* `usb=3` -> `usbmux` is the owner, as before. `usbsh` exits 0 without opening.

A shell is requested on `usb=2` only by the magic line the host sends while
the port is in log mode:

```
1d 1d 53 48 45 4c 4c 0a          ("\x1d\x1dSHELL\n")
```

The kernel's port thread matches it in `shell_input()`, stops `feed_log()`,
prints `--- usbsh: log paused; 'log' resumes it ---` on the port, sets
`shell_wanted` and wakes `/dev/hakios-usb-shell`. `usbsh` opens
`/dev/hakios-usb` only then; the open is refused with `EBUSY` if no request is
pending, so no program can silence the log by accident. `HAKIOS_USB_LOG`
(or the shell's `log` command) returns to log mode; 120 s without shell input
does the same; a request with no attach for 10 s also returns.

Kernel transition lines (one per change, all in the persistent ring):

```
usb: log mode
usb: host asked for a shell
usb: shell took the port
usb: log mode again
```

The earlier race (usbmux opening unconditionally and making usbsh fail with
`EBUSY`) is still fixed by the boot-arg gate above; it is no longer the only
ordering rule.
