> [!WARNING]
> **This project is incomplete, highly experimental, and can brick your device.**
> It boots a modified Apple XNU kernel on hardware it was never meant for. Drivers are
> half-ported, large parts of the system do not work, and a wrong flash can leave the phone
> unbootable. The iOS root step **erases all Android user data**. Only use devices with an
> unlocked bootloader that you can afford to lose, keep partition backups, and expect nothing
> here to be safe or finished. Everything you do with this software is at your own risk.

# iOS 16 on the Xiaomi Mi 11X (alioth)

**This is the Mi 11X fork of [dipa-studio/ios-sweet](https://github.com/dipa-studio/ios-sweet)**
(the Redmi Note 10 Pro project, which boots to the iOS home screen). This fork ports the same
Apple XNU kernel (xnu-8796, the iOS 16 generation) to the **Xiaomi Mi 11X** (`alioth`, Qualcomm
SM8250-AC / Snapdragon 870). One tree supports both phones: the board is selected with
`--board alioth` in `tools/mkadt.py` and `BOARD=alioth` in `shim/build.sh`; the upstream sweet
defaults are untouched, so sweet keeps building and booting as before.

**On alioth the iPhone X 16.7.16 (20H392) userland runs from the internal UFS.** A bare-metal
shim stands in for iBoot (its firmware version is `sweet-shim`), loads our XNU 8796 and an Apple
device tree, and XNU mounts a 16 GiB HFS+ image from the start of `userdata`. SpringBoard reaches
the home screen, Settings opens, touch and the volume/power keys respond, all eight CPUs are
initialised, and the kernel log and a shell come out over USB. The GPU is the current wall: the
ported Adreno 650 driver brings up the whole block and draws its own test frame, but Mesa client
submissions reach the command processor but the pipeline wedges mid-IB; the frame is mostly zeros with a white corner. With one SMMU space per client (`gpu_spaces=1`) the earlier opcode error is gone and the CP consumes ~448 dwords before the hang.

> Experimental bring-up, not a usable phone OS. The iOS root lives in the `userdata` partition and
> **erased Android's user data** when it was flashed (bootloader, boot, dtbo, vbmeta, super,
> recovery, modem and persist are untouched; a recovery format-data or a fastboot ROM returns the
> phone to Android). Everything here runs with Apple's security model mostly switched off.

## Current status on alioth (2026-11-28)

| Area | State |
| --- | --- |
| Boot | **Works.** Stock Xiaomi bootloader → temporary `fastboot boot` of our shim → XNU. Nothing is flashed to the boot partitions yet |
| CPU | **Works.** `cpus=8` → `requested=8 selected=8`, PSCI CPU_ON for cores 1-7, `8/8 CPUs initialized` |
| Memory | Upper DDR bank, `0x1_00000000` + 0x140000000 (5 GiB), 16K pages, GICv3, virtual timer INTID 27 |
| Storage | **Works.** Own UFS host driver; GPT parsed; the iOS root is in `userdata` and mounted read-write (`hfs: mounted IOSRoot on device b(1,0)`) |
| Kernel | **Works.** XNU reaches `bsd_init` and beyond: AMFI/Sandbox stand-ins, HFS, networking stubs, KASLR slide, on-disk dyld cache |
| Display | **Works, CPU copy.** Kernel IOSurface + IOMobileFramebuffer (`AppleCLCD`), panel 1080×2400, presented to iOS as an iPhone X panel (1125×2436). No panel on/off, brightness or 120 Hz control yet; the panel is what ABL left on |
| iOS userland | **Works.** launchd, backboardd, SpringBoard, Settings; the home screen renders and is interactive |
| Touch | **Works.** FocalTech FT3698 on QUP SPI SE4 (`0x990000`), chip-id `0x5652`, MSB-first FIFO packing, 15-bit reports scaled from the 8640×19200 firmware space |
| Buttons | **Works.** PM8150 GPIO6 (power) and the volume keys, through the alioth keys driver |
| Battery | **Works.** Real percentage from the PM8150B fuel gauge (`batteryhakios=1`); the static 100 % / 4200 mV service is the fallback |
| Logging | **Works.** Kernel console ring in the last 4 MiB of `userdata`, readable at the next boot with `sweetlogdump` / `sweetloggrep`; also streamed over USB |
| USB | **Works.** Device mode: CDC-ACM console at `1209:316d`, manufacturer `Xiaomi`, product `Mi 11X`; the kernel log always flows and a shell attaches on demand |
| SWEETBOX | **Works.** A 1 MiB mailbox before the log ring accepts a checksummed payload from recovery ADB and installs it on the next boot; a new `/usr/local/bin/usbsh` was installed this way without reflashing `userdata` |
| GPU core | **Works.** The ported hakios-alioth Adreno 650 driver (patch `0200`) brings up zap/TrustZone, GMU firmware, HFI, the 3D core, the command processor, SMMU, the 2D fill and the panel, publishes `HakiosGPU` (msm-DRM ABI), takes the GPU interrupt (INTID 332 / SPI 300) and draws its orange/white/blue test bands |
| GPU client | **Partly working.** Mesa 25.0.7/freedreno identifies `FD650` and `gl_test` completes every step; with `gpu_spaces=1` the CP no longer raises an opcode error and consumes ~448 dwords of the IB before the pipeline wedges (`HLSLQ/SP` busy, no fault bit). The readback shows a white corner rather than the 26% triangle. The triangle was drawn correctly once, on 2026-11-27 |
| Wi-Fi / BT / cellular / audio / camera | **No drivers.** Wi-Fi is the next research project (see below) |
| Haptics / torch | **Parked.** The AW8697 never answers on the assumed GENI SE11 bus (the probe resets the boot before its first print), so its real bus and GPIOs still need checking; the flash module reports type `0x18`/subtype `0x0000`, not PM8150L, so the torch driver refuses |
| Persistent boot | **Prepared, not applied.** `boot_b` image, installer and restore path are documented and measured; nothing has been flashed |

## How it boots

```
ABL (stock Xiaomi bootloader, unlocked)
  -> fastboot boot shim/out/shim-boot-alioth.img     (temporary; nothing is flashed to boot)
     -> shim: own MMU setup, reads the live FDT, fills in the ADT as iBoot would,
        loads the payload from the ramdisk
        -> XNU Mach-O + generated Apple Device Tree (ADT) + boot-args
           -> XNU -> UFS driver -> HFS+ root on userdata
              -> dyld + shared cache -> launchd -> daemons -> backboardd + SpringBoard
```

There is no serial port (the debug UART is muxed as SPI on this board), so the kernel draws its
console into the framebuffer ABL leaves at `0x9c000000` and the console is read off the screen,
or out of the persistent ring at the next boot.

### Reading logs without a serial port

The kernel keeps a 4 MiB console ring in the **last 1025 blocks of `userdata`**, past the end of
the iOS root, so it survives reboots. At the next boot the previous session's log can be printed
to the console and read/photographed:

```
sweetlogdump=4194304            # how many bytes of the ring to print (max 4 MiB)
sweetloggrep=GPU:               # only lines containing this substring (any boot arg text)
sweetlogdumpwait=120            # hold the console on the dump for N seconds
ufslogsecs=1                    # flush the ring every second so the tail is complete
```

The dump prints at UFS init, before the root is mounted, so a quiet cmdline
(`sweettouch=0 sweetkeys=0 sweetusb=0 sweetgpu=0`) keeps it on screen for the hold. There is a
known bug: `sweetloggrep` failed to filter in the last two dump boots and printed the whole ring;
check the argument parse before relying on it.

### Installing files without reflashing `userdata` (SWEETBOX)

Patch `0400` reserves 1 MiB immediately before the log ring for a mailbox. Pack files with
`tools/sweet-box.py pack`, write them from recovery ADB with `tools/sweet-box.py apply`, then boot
with `sweetbox=1`; the kernel verifies the header and payload CRCs and installs the files before
launchd. `ROOT/<path>` entries need `sweetboxroot=1` and must be under the allowlist
(`private/var/tmp/`, `private/var/mobile/`, `usr/local/bin/`,
`System/Library/LaunchDaemons/`, …). Everything else lands flat in `/private/var/tmp/`. The first box
also installs `sweet-autorun` and a launchd job, so later boxes can run
`/private/var/tmp/autorun.sh` and report through the log. Full design, commands and recovery:
[`docs/sweetbox.md`](docs/sweetbox.md).

> **Status note:** the `Status: implemented but not built or booted` line at the top of
> `docs/sweetbox.md` is from 2026-11-26 morning and is stale. The 2026-11-26 evening boot
> (image HKN) used the mailbox on the phone, and the current `usbsh` was installed through it.
> The newest `NOTES.md` entry wins.

## USB console and shell

The USB stack is device mode only; there is no USB host stack. It is selected with
`usbhakios=1` and one `usb=` value. `usb=2` is the verified path; `usb=3` exists but pairing and
AFC have not been shown on this phone yet.

| boot arg | the phone looks like | userland | use |
| --- | --- | --- | --- |
| `usb=2` | CDC-ACM serial, `1209:316d`, `Xiaomi` / `Mi 11X` | `usbsh` | kernel log, shell, `b64` file download |
| `usb=3` | iPhone, `05ac:12a8`, usbmux interface | `usbmux` + iOS `lockdownd` | host `usbmuxd`/`idevice*`/AFC (`ifuse`) |
| `usb=1` | nothing (read-only probe) | none | diagnostics |

On `usb=2` the kernel log always flows while no program has attached. A shell is requested with
the eight magic bytes `1d 1d 53 48 45 4c 4c 0a` (`\x1d\x1dSHELL\n`); the kernel pauses the log,
prints `--- usbsh: log paused; 'log' resumes it ---`, and wakes `/dev/hakios-usb-shell`. `usbsh`
opens the port, prints `ios:/#`, and gives it back with `log` or after 120 s of inactivity. The
`usb=` argument decides which of `usbsh` and `usbmux` may open the port; the other exits without
touching it. Host side: `tools/sweet-usbsh.sh` (and `-g REMOTE [LOCAL]` for `b64`).

`usbsh` has `reboot`, `reboot fastboot`, `reboot recovery` and `halt`. The three reboot modes call
`ioctl(/dev/hakios-usb, HAKIOS_USB_RESTART, &mode)`; the driver writes the LK/Xiaomi restart reason
to IMEM (`0x146bf65c`, `board_imem=` overrides) through an uncached mapping and then runs the
normal `reboot(2)` path. Patch `0120` supplies `SweetPlatformExpert::haltRestart()` with PSCI
`SYSTEM_RESET`/`SYSTEM_OFF`; without it the kernel spins at `MACH Reboot`. Reasons: normal
`0x77665501`, fastboot `0x77665500`, recovery `0x77665502`.

**Not verified on hardware yet.** The matching `usbsh` was installed through SWEETBOX, but none of
the three reboot reasons has been observed on the phone from this branch. A reason ABL ignores
just boots normally; do not claim `fastboot devices` will appear until it has been run once.
Details: [`docs/usb-shell.md`](docs/usb-shell.md).

### Known-good boot cmdline

The last combination recorded as known-good in `NOTES.md` (2026-11-26 evening) is the common UI
line plus every opt-in that was working then:

```
debug=0xc serial=3 cpus=8 keepsyms=1 -noprogress rd=ufsroot0 \
unentitled_ios_sim_launch=1 ignition_level=1 wdt_test=no_user_checkin \
ufsrw=1 rootrw=1 launchd_unsecure_cache=1 wdt=-1 \
sweettouch=1 sweettouchdelay=0 sweetkeys=1 sweetusb=0 \
sweetgpu=22 sweetgpukeep=1 usbhakios=1 usb=2 usbreplay=1 \
sweetbox=1 batteryhakios=1 \
board_pil_gpu=0x8681a000 board_pil_gpu_size=0x2000
```

That line runs the old in-kernel probe (`sweetgpu=N`) through its 2D frame. The image described
in [`docs/persistent-boot.md`](docs/persistent-boot.md) (2026-11-27) instead turns that probe off
and runs the ported driver:

```
sweetgpu=0 board_pil_gpu=0x8681a000 board_pil_gpu_size=0x2000 \
adreno=22 adreno_keep=1 adreno_pause=0 adreno_watch=30 adreno_loud=1 gpu_irq=1
```

Use the second form for the Mesa client; `sweetgpu=N` and `adreno=N` are alternative ladders, not
something to enable together. `adreno_keep=1` publishes `HakiosGPU`; `gpu_irq=1` attaches the GPU
interrupt (INTID 332 / SPI 300); `adreno_loud=1` logs every client request and fence wait. Boot
arguments are space separated; use a substring without spaces for `sweetloggrep`.

## How to build and boot (alioth)

You need a Mi 11X (`alioth`) with an **unlocked bootloader**, a Linux PC, and a GitHub account for
the kernel build.

### 0. The device tree

The shim needs the phone's live FDT. Either unpack it from the stock `boot.img`
(`python3 tools/unpack_bootv2.py backup/boot.img dtb/boot_unpacked`) or dump the live FDT from a
rooted device. The alioth shim build defaults to `../../phone/live.dtb` (kept **outside** the
repo, like all device dumps); pass `DTB=<path>` to override.

### 1. Build the kernel

The kernel builds on GitHub's macOS runners with
[blacktop/darwin-xnu-build](https://github.com/blacktop/darwin-xnu-build). The workflow fetches
xnu-8796 and applies `xnu/patches/` in order. **CI runs only by manual dispatch** (a push does not
trigger a build, to save macOS minutes):

```sh
gh workflow run xnu.yml -R YOU/ios-sweet
gh run download RUN_ID -R YOU/ios-sweet -n xnu-kernel -D xnu/out    # -> kernel.development.sweet
```

The kernel is board-independent (the board shows up in the ADT and boot-args). To check a patch
locally before spending a CI run, `tools/xnu-cc.py` replays the compile commands of a previous CI
log for single files.

### 2. Build the boot image

Needs `clang`/LLVM (`llvm-objcopy`, `llvm-nm`, `llvm-readelf`) and `mkbootimg`.

```sh
# ADT, with the GPU firmware blobs
python3 tools/mkadt.py shim/out/alioth.adt --board alioth --highmem \
    --gmu-fw research/alioth-gpu/a650_gmu.bin \
    --sqe-fw research/alioth-gpu/a650_sqe.fw \
    --zap-mdt research/alioth-gpu/a650_zap.mdt \
    --zap-seg research/alioth-gpu/a650_zap.b02

# payload: the cmdline that boots the current UI
python3 tools/mkpayload.py xnu/out/kernel.development.sweet shim/out/alioth.adt shim/out/payload.bin \
    --cmdline 'debug=0xc serial=3 cpus=8 keepsyms=1 -noprogress rd=ufsroot0 \
unentitled_ios_sim_launch=1 ignition_level=1 wdt_test=no_user_checkin ufsrw=1 rootrw=1 \
launchd_unsecure_cache=1 wdt=-1 sweettouch=1 sweettouchdelay=0 sweetkeys=1 sweetusb=0 \
sweetgpu=0 board_pil_gpu=0x8681a000 board_pil_gpu_size=0x2000 \
adreno=22 adreno_keep=1 adreno_pause=0 adreno_watch=30 adreno_loud=1 gpu_irq=1 \
usbhakios=1 usb=2 usbreplay=1 sweetbox=1 batteryhakios=1'

cd shim && BOARD=alioth CC=clang OBJCOPY=llvm-objcopy NM=llvm-nm READELF=llvm-readelf \
    ./build.sh out/payload.bin      # -> shim/out/shim-boot-alioth.img
```

`--board alioth` picks the SM8250 memory map, timer INTID 27, the 1080×2400 panel and the
`qcom,kryo470` CPU match. `rd=ufsroot0` is what makes the UFS root probe run at all — the touch,
keys, USB and GPU hooks live inside it. `build.sh` also puts `root=/dev/ram0` in the boot-header
cmdline, which Qualcomm's boot code treats as a dev image (it skips A/B retry decrements; XNU
never reads that string).

The GPU patch is generated from the sources in `hakios-port/`, and the generated patch has
silently shipped an old kernel twice. After editing those sources, run
`tools/regen-0200.sh --run RUN_ID` (or `--tree DIR`) and then `tools/check-patch-sources.sh`;
that check is the guard against the drift that shipped an old kernel twice.

### 3. Boot it (temporary, non-destructive)

```sh
fastboot boot shim/out/shim-boot-alioth.img
```

Expected: the shim splash, the kernel console (8 CPUs, UFS, drivers), then the HFS mount, launchd
and — after the UI is up — the SpringBoard home screen. Because nothing is written to the boot
partitions, a hard reset always returns to whatever is installed.

### 4. iOS root (destructive — already done on this device)

The root is the iPhone X (iPhone10,3) 16.7.16 (20H392) system, built from the IPSW with
`tools/mkiosroot.sh` (HFS+, case-sensitive, journaled, 16 GiB) plus `tools/sweet-root-tweaks.py`
(Setup skipped, watchdog exceptions, migration marked complete, container dirs, audio disabled),
then written to `userdata`:

```sh
fastboot -S 512M flash userdata ios16-root.simg   # ~5 minutes; ERASES ANDROID USER DATA
```

The ADT must carry the iPhone X `/product` node (mkadt copies it from `research/ipsw-x/d22ap.adt`,
extracted from the same IPSW). Without it SpringBoard aborts in `SBStartupTransitionLockOut`
(`ns 2 code 0x6`) instead of drawing the home screen.

To go back to Android: format `userdata` in a recovery (or flash a fastboot ROM). Nothing else
was changed.

## Persistent boot (`boot_b`)

A normal power-on has no host to supply boot arguments, so the image must be self-contained. The
plan is to flash **only the active slot, `boot_b`** (`b` at the 2026-11-27 measurement, 192 MiB,
header v2, payload cmdline baked in); `boot_a` stays stock, and `vbmeta` is not needed while the
bootloader is unlocked (`verifiedbootstate=orange`). Nothing has been flashed yet.

```sh
tools/install-persistent-boot.sh --yes
# if `fastboot getvar slot-successful:b` is not `yes`:
tools/install-persistent-boot.sh --yes --dev-image-cmdline
```

The installer refuses without `--yes`, checksums the stock `boot_<slot>`/`vbmeta_<slot>`, checks
the baked payload cmdline for the required tokens, and prints the undo. Restore with
`tools/persistent-boot-restore.sh`. Read [`docs/persistent-boot.md`](docs/persistent-boot.md)
before running it; do **not** run `fastboot getvar all` on this ABL (it wedges), and never re-lock
the bootloader.

The bootloader is never modified, so fastboot is always reachable with **Power + Volume-Down**
(handled in XBL/ABL before any boot image is read). For day-to-day work without button combos, a
failed `boot_b` in practice lands in OrangeFox (the A/B retry path), which has adb:

```
power-on -> OrangeFox adb -> adb reboot fastboot (fastbootd)
         -> fastboot reboot bootloader -> bootloader fastboot
```

`tools/sweet-fastboot.sh` automates exactly that chain and returns immediately if the phone is
already in fastboot. The dangerous mistake in this area is letting Android boot with the iOS image
in `userdata`: it may reformat the partition.

## GPU: the ported Adreno 650 driver

`bsd/dev/hakios.adreno.c` and `iokit/Kernel/hakios.gpu.cpp` are the hakios-alioth driver ported as
patch `0200`; they are separate from the older staged probe in `bsd/dev/sweet_gpu.c`
(`sweetgpu=N`). The ported driver is the one that matters now.

Verified on alioth:

- zap via TrustZone: the whole SCM ladder runs, the phone's own `a650_zap.mdt` authenticates and
  starts, and the 3D core leaves secure mode. (An earlier failure was our `.mdt`, which was zeros
  after the ELF header; the phone's `vendor.img` copy fixed it.)
- GMU firmware `a650_gmu.bin` loads and runs (`fw_init_result 0x100`); the HFI queues come up.
- The 3D core powers on (`gx gdsc 0xf8222800`, `rbbm_status 0x1`), the SQE microcode loads, the
  command processor takes `CP_ME_INIT`, and `CP_MEM_WRITE` lands (`0x600dc0de`).
- The 2D fill draws 1080×2400 orange/white/blue bands, and the panel bridge copies them into the
  console's framebuffer mapping at `0x9c000000`; the phone shows them.
- `HakiosGPU` is published as an `IOService` with the msm-DRM user client; the GPU interrupt
  (INTID 332, SPI 300, level) tells fence waits when a submission finishes.
- The Mesa 25.0.7/freedreno client (`gl_test`, `libOSMesa.8.dylib`, the `hakios-drm` stand-in) gets
  `FD650`, allocates buffers, maps them and submits; `gl_test` reaches its last step.

What is broken: the pipeline wedges mid-IB instead of finishing. With the default one shared SMMU
space the CP stopped after exactly **256 dwords** with `CP int 0x1` (opcode error, `CP_SQE_STAT_DATA`
0). With `gpu_spaces=1` (one space per client, which is what the working reference build uses) the
opcode error is gone: the CP consumes about **448 dwords** (`CP_IB1_REM_SIZE` 1736 -> 1288,
`ROQ 247`) and then sits with `RBBM_STATUS 0xe51005` (CP/HLSQ/SP/VPC/PC busy), no fault bit and the
fence word still 0 — the same "no fault, only a wait timeout" signature `hakios-metal` documents.
The readback is no longer all zeros: a white corner and ~15k pixels inside the triangle, against
26% expected. The triangle itself was drawn correctly once, on 2026-11-27.

Next: name the packet at IB dword 448 (end of binning or a nested indirect buffer), check whether a
per-client space needs `CP_SMMU_TABLE_UPDATE` (0x53, present in the reference's metal notes), and
make a hung client wait always print the last CP command and IB offset before recovering.

A lesson worth keeping: SMMU/GMU registers are emulated by the hypervisor and only plain,
non-inlined single `ldr`/`str` accesses work — a C loop can compile to a post-indexed load and
freeze the phone. The same class of bug was behind the USB gadget's `STARTTRANSFER` freeze.

## Research, not started

| Area | State |
| --- | --- |
| Wi-Fi | **Not started.** alioth's radio is a **QCA6390 on PCIe0/MHI**, not a WCN6750/WPSS; the `wpss.mdt` path never runs here. The reference (xiongnemo/hakios-alioth) works on this phone with an in-kernel ath11k object over a LinuxKPI-shaped layer, not a userland supplicant. Porting it means ~13k lines of XNU files plus a prebuilt ath11k object and QCA6390 firmware; estimate **10-16 sessions**. Decision report: `research/hakios-net-decision.md` on branch `hakios-net2` (the `research/` tree is not in this branch) |
| Metal / GPU UI | **Not started; after the GL path.** AdrenoMetal is a userland Metal frontend over metal2vulkan + Turnip with a NativeAdreno user client; it does not speak our `HakiosGPU` msm-DRM ABI, and upstream supports neither A650 nor iOS 16. `docs/guacamole-ios16-metal.md` documents an iOS 16.7.16 A640 stack that can be adapted; `docs/adrenometal-feasibility.md` has the A650 route. **Correction to the old framing:** the reference composites SpringBoard with OpenGL ES/freedreno, not Metal; Metal is for apps. Both ride the same submit ring, so the 256-dword stop gates either path |
| Splitboot / dual boot | **Deferred.** The Open Mapple mechanism is real but MediaTek-only; the alioth version is a GPT **front**-carve (`darwin` over the existing 16 GiB HFS+ volume, `userdata` moved after it) plus a menu in our shim and a `misc` slot switch. The only new brick vector is the first GPT write, which Power+Volume-Down, `fastboot boot` and `boot_a` do not cover. See `docs/splitboot-feasibility.md` |

## Repository layout

| Path | What |
| --- | --- |
| `shim/` | Bare-metal boot shim (C + asm) packed as an Android boot image; `BOARD=sweet` or `BOARD=alioth` |
| `xnu/patches/` | The XNU patch series (applied in order by CI), plus staging scripts for libpthread, HFS and BearSSL |
| `.github/workflows/xnu.yml` | Kernel CI build (manual dispatch only) |
| `hakios-port/` | The ported GPU driver sources and adapter; `0200` is generated from here |
| `hakios-port-gpu2/` | Submit-path debugging notes and probes |
| `hakios-port-usb/` | DWC3 driver sources and the `usbmux`/`usbsh` userland |
| `hakios-port-userland/` | Mesa 25.0.7 build, `hakios-drm`, `gl_test`, EAGL/OSMesa adapter |
| `hakios-port-battery/`, `hakios-port-small/` | PM8150B gauge, AW8697 haptics, PM8150L torch notes |
| `hakios-port-ref/` | Diff against the working xiongnemo/hakios-alioth submit path |
| `tools/mkadt.py` | Generates the Apple Device Tree; `--board`, `--gmu-fw`, `--sqe-fw`, `--zap-mdt`, `--zap-seg` |
| `tools/mkpayload.py` | Packs kernel + ADT + boot-args into the shim payload |
| `tools/mkiosroot.sh` | Builds the HFS+ iOS root from the IPSW images |
| `tools/sweet-root-tweaks.py` | Bring-up changes to the root (Setup skip, activation, daemons) |
| `tools/sweet-box.py` | Pack/apply/pull/clear the SWEETBOX mailbox over recovery ADB |
| `tools/sweet-usbsh.sh`, `tools/sweet-fastboot.sh` | Host side of the USB shell; recovery-adb → fastbootd → bootloader |
| `tools/install-userland.sh` | Install the CI `userland` artifacts into the root image and rebuild the sparse image |
| `tools/install-persistent-boot.sh`, `tools/persistent-boot-restore.sh` | Flash/restore `boot_b` with checks |
| `tools/regen-0200.sh`, `tools/check-patch-sources.sh` | Keep `0200` in step with its sources; catch a patch that no longer matches them |
| `tools/xnu-cc.py` | Local single-file compile check from a CI log |
| `tools/qemu-sweet.py` | QEMU test boots of the sweet board with framebuffer text decoding |
| `tools/adt.py`, `remotezip.py`, `unpack_bootv2.py`, `sparsediff.py` | Helpers |
| `NOTES.md` | Detailed engineering log: every boot, crash and decision, plus hardware facts. **Newest entries at the top; when docs disagree, this wins** |
| `BRANCHES.md` | One line per branch: what it carries, its patch, its boot args |

Not in git: partition backups, live device trees, recovery images, Apple firmware and root images,
GPU firmware blobs (`research/alioth-gpu/`), and downloaded or generated build trees.

## Kernel patches

The series starts from upstream ios-sweet (0001–0069). The alioth work in this fork:

| # | What |
| --- | --- |
| 0070–0081 | Board plumbing: `--board alioth` in mkadt, shim `ALIOTH` path, LLVM/clang fixes, alioth ADT |
| 0082 | Keys: PM8150 GPIO6 power/volume through the PMIC arbiter |
| 0083 | Touch: FocalTech FT3698 on QUP SPI SE4 + RPMh rails (ldoc10, ldoc1) |
| 0084–0085 | TLMM split into small windows (a 16 MiB `ml_io_map` panics) and DWC3 probe ladder |
| 0086 | HWCG-aware clock halt poll for `wrap_0_s_ahb` |
| 0087–0088 | RPMh rail guard and the ldoc1 1.8 V vote |
| 0089–0096 | FT3698 SPI frame, MSB-first FIFO packing, chip-id `0x5652`, IRQ-gated reads, 15-bit decode |
| 0097 | `sweetlogdump`: print the previous boot's console ring at UFS init |
| 0098–0102 | USB: femto HS PHY bring-up, 64-bit STARTTRANSFER, SMMU reporting, `sweetlogdumpwait` |
| 0103–0118 | Staged GPU probe (CX/GMU/RSCC/SMMU/zap/CP), step ordering and log-dump timing |
| 0119 | userland console tee, so `/dev/console` output reaches the persistent log |
| 0120 | `SweetPlatformExpert::haltRestart()` with PSCI reset/off; makes `usbsh reboot` work |
| 0200 | The ported hakios-alioth Adreno 650 driver, `HakiosGPU` service, msm-DRM user client, panel copy, GPU interrupt (INTID 332) |
| 0300 | DWC3 device stack, CDC-ACM `1209:316d`, `usbmux`/`usbsh` userland, `HAKIOS_USB_RESTART` |
| 0400 | SWEETBOX: checksummed 1 MiB mailbox before the console ring, installs files before launchd |
| 0500 | PM8150B fg-gen4 battery gauge (`batteryhakios=1`) |
| 0501 | AW8697 haptics and PM8150L torch (both opt-in; parked on this board) |

The feature patches apply in the order `0200` → `0300` → `0400` → `0500` → `0501` after
`0001`–`0120`.

## Branches

`hakios-integrate` is the integration branch: topics merge there, and `main` gets the merge once
the GPU submit path is settled. The short version (full table in [`BRANCHES.md`](BRANCHES.md)):

| Branch | Role |
| --- | --- |
| `main` | Baseline iOS 16 port: display/console, UFS root, touch/keys, USB probe, GPU ladder up to `0118` |
| `hakios-integrate` | **Current work.** All merged topics, patches `0001`–`0120`, `0200`, `0300`, `0400`, `0500`, `0501` |
| `hakios-gpu`, `hakios-gpu2` | Adreno 650 port, then submit-path debugging against the working alioth reference |
| `hakios-usb`, `hakios-usbname` | DWC3/CDC-ACM/usbmux stack; the `Xiaomi` / `Mi 11X` descriptors |
| `hakios-autorun` | SWEETBOX mailbox and the no-reflash install channel |
| `hakios-battery`, `hakios-small` | PM8150B gauge; AW8697 haptics and PM8150L torch |
| `hakios-userland` | Mesa 25.0.7/freedreno, `hakios-drm`, `gl_test`, build and install scripts |
| `hakios-persist`, `hakios-reboot` | `boot_b` persistence; IMEM restart reason and patch `0120` |
| `hakios-net`, `hakios-net2` | Wi-Fi port and the QCA6390 decision report; deliberately not merged |
| `hakios-console` | Separate console work; not merged |

## Key hardware facts (alioth)

- SoC: SM8250-AC (Snapdragon 870), Kryo 585 tri-cluster: 1×Cortex-A77 @2.84 GHz (prime),
  3×A77 @2.42 GHz, 4×A55 @1.80 GHz. MPIDR uses Aff1 for the core number.
- RAM: 8 GB; the kernel runs in the upper bank `0x1_00000000` + `0x140000000` (5 GiB), above
  Qualcomm's protected carve-outs.
- GICv3 with security extensions: the virtual timer is PPI 11 → **INTID 27** (sweet uses 19).
  PSCI through `smc`, 19.2 MHz timer, ARMv8.2 without pointer authentication.
- UFS host controller at `0x01d84000`; framebuffer at `0x9c000000` (ABL splash, 23 MiB).
- Panel: 1080×2400 DSC command mode (`qcom,mdss_dsi_k11a_38_08_0a_dsc_cmd`), continuous splash
  from ABL; presented to iOS as 1125×2436.
- Touch: FocalTech FT3698 on QUP SPI SE4 (`0x990000`), chip-id `0x5652`, 15-bit reports in an
  8640×19200 space; rails PM8150A L10 (2.95–3.41 V) and L1 (1.8 V).
- Buttons: PM8150 GPIO6 (power), volume keys on the same PMIC.
- Battery: PM8150B on SPMI SID 2, fg-gen4 (`fg-batt-soc` at `0x4000`, `fg-batt-info` at `0x4100`);
  4520 mAh.
- GPU: Adreno 650 (`0x06050002`), GPUCC `0x3d90000`, GMU `0x3d6a000`, KGSL SMMU `0x3da0000`,
  zap memory `0x8681a000`; interrupt SPI 300 / INTID 332.
- USB: DWC3 `0xa600000`, femto HS PHY `0x88e3000`, apps SMMU `0x15000000` (StreamID 0).
- Wi-Fi: QCA6390 on PCIe0/MHI (not WCN6750), with `bt_qca6390` on UART.
- IMEM restart reason register: `0x146bf65c`.

More in [`NOTES.md`](NOTES.md).

## AI disclosure

This project is developed in close collaboration with AI coding agents (OpenCode running large
language models). The kernel patch series for the alioth port, the shim/tool changes, the
debugging analysis, and large parts of `NOTES.md` and this README were written or revised by AI,
with a human maintainer directing the work, performing the hardware steps (flashing, booting,
photographing console output) and reviewing the results. CI builds and on-device boots are used
to verify the AI's reasoning against real hardware.

Consequently, expect bugs and confidently-written but incorrect claims: analysis in `NOTES.md`
is explicitly marked where it separates observations from guesses. Treat all of it as unverified
until reproduced on hardware.

## Credits

Built on Apple's open-source releases (xnu, IOHIDFamily, libpthread, hfs),
[BearSSL](https://bearssl.org), [blacktop/darwin-xnu-build](https://github.com/blacktop/darwin-xnu-build),
[ipsw](https://github.com/blacktop/ipsw), Qualcomm/Xiaomi's published Linux kernel sources for the
hardware details, the upstream **ios-sweet** project by dipa-studio, and the community ports whose
staged hardware work this fork builds on: [aTechGeekDev/ios-apollo](https://github.com/aTechGeekDev/ios-apollo),
[FFT-infra/UniXNU-alioth](https://github.com/FFT-infra/UniXNU-alioth) (A650 firmware images),
MrMoxing/ios-alioth and [coreycusick/ios-guacamole](https://github.com/coreycusick/ios-guacamole).
The GPU driver is a port of [xiongnemo/hakios-alioth](https://github.com/xiongnemo/hakios-alioth).
iOS itself is Apple's and is not distributed here.
