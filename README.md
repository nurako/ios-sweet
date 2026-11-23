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

**On alioth the iPhone X 16.7.16 (20H392) userland runs from internal UFS**: the shim, the UFS
driver, XNU, the alioth touch/key drivers and the flashed root all work. SpringBoard reaches the
home screen, Settings opens, and touch and the volume/power keys respond (first reached
2026-11-22). All eight cores come up. The GPU is being brought up in stages: the CX power
domain, its clocks and the **GMU firmware** are running, but the 3D core, the command processor
and Metal are not there yet.

> Experimental bring-up, not a usable phone OS. The iOS root lives in the `userdata` partition and
> **erased Android's user data** when it was flashed (bootloader, boot, dtbo, vbmeta, super,
> recovery, modem and persist are untouched; a recovery format-data or a fastboot ROM returns the
> phone to Android). Everything here runs with Apple's security model mostly switched off.

## Current status on alioth (2026-11-23)

| Area | State |
| --- | --- |
| Boot | Stock Xiaomi bootloader → temporary `fastboot boot` of our shim → XNU. Nothing is flashed to the boot partitions |
| CPU | **All 8 cores**: `cpus=8` → `requested=8 selected=8`, PSCI CPU_ON for cores 1-7, `8/8 CPUs initialized`, SG1 verified |
| Memory | Upper DDR bank, `0x1_00000000` + 0x140000000 (5 GiB), 16K pages, GICv3, virtual timer INTID 27 |
| Storage | Own UFS host driver; GPT parsed; the iOS root is **flashed into `userdata`** and mounted read-write (`hfs: mounted IOSRoot on device b(1,0)`) |
| Kernel | XNU reaches `bsd_init` and beyond: AMFI/Sandbox, HFS, networking stubs, KASLR slide, on-disk dyld cache |
| Display | Kernel IOSurface + IOMobileFramebuffer (`AppleCLCD`), panel 1080×2400, presented to iOS as an iPhone X panel (1125×2436) |
| iOS userland | **Running** — launchd, backboardd, SpringBoard, Settings; the home screen renders and is interactive |
| Touch | **Working** — FocalTech FT3698 on QUP SPI SE4 (`0x990000`), chip-id `0x5652`, MSB-first FIFO packing, 15-bit reports scaled from the 8640×19200 firmware space |
| Buttons | **Working** — PM8150 GPIO6 (power) and volume keys, reported through the alioth keys driver |
| Battery | Static fallback service (100 %, 4200 mV) |
| GPU | **Staged bring-up, in progress**: GCC/GPUCC clocks, CX power on, GMU clocked at 200 MHz, `a650_gmu.bin` running (`fw_init_result 0x100`), HFI tables and start accepted, and **the 3D core powers on and answers** (`gx gdsc 0xf8222800`, `rbbm_status 0x1`). SQE/CP start and the zap shader are next; no Metal yet |
| USB (gadget console) | **Blocked**: the femto HS PHY and DWC3 come up (`ep0` configured), but the apps SMMU translates StreamID 0 with a faulting S2CR and EL1 writes do not take, so the controller cannot fetch our DMA descriptors |
| Wi-Fi / BT / cellular / audio / camera | Not working (no drivers) |
| Logging | Kernel console ring persisted in the last 4 MiB of `userdata`, readable at the next boot with `sweetlogdump` / `sweetloggrep` (see below) |

## How it boots

```
ABL (stock Xiaomi bootloader, unlocked)
  -> fastboot boot shim/out/shim-boot-alioth.img     (temporary; nothing is flashed to boot)
     -> shim: own MMU setup, reads the live FDT, loads the payload from the ramdisk
        -> XNU Mach-O + generated Apple Device Tree (ADT) + boot-args
           -> XNU -> UFS driver -> HFS+ root on userdata
              -> dyld + shared cache -> launchd -> daemons -> backboardd + SpringBoard
```

There is no serial port (the debug UART is muxed as SPI on this board), so the kernel draws its
console into the framebuffer ABL leaves at `0x9c000000` and the console is read off the screen.

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
(`sweettouch=0 sweetkeys=0 sweetusb=0 sweetgpu=0`) keeps it on screen for the hold.

## How to build and boot (alioth)

You need a Mi 11X (`alioth`) with an **unlocked bootloader**, a Linux PC, and a GitHub account for
the kernel build.

### 0. The device tree

The shim needs the phone's live FDT. Either unpack it from the stock `boot.img`
(`python3 tools/unpack_bootv2.py backup/boot.img dtb/boot_unpacked`) or dump the live FDT from a
rooted device. The alioth shim build defaults to `../../phone/live.dtb` (kept **outside** the
repo, like all device dumps); pass `DTB=<path>` to override.

### 1. Build the kernel

The kernel builds on GitHub's macOS runners with [blacktop/darwin-xnu-build](https://github.com/blacktop/darwin-xnu-build).
The workflow fetches xnu-8796 and applies `xnu/patches/` in order. **CI runs only by manual
dispatch** (a push does not trigger a build, to save macOS minutes):

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
# ADT (add the GPU firmware blobs for the staged GPU probe)
python3 tools/mkadt.py shim/out/alioth.adt --board alioth --highmem \
    --gmu-fw research/alioth-gpu/a650_gmu.bin \
    --sqe-fw research/alioth-gpu/a650_sqe.fw \
    --zap-mdt research/alioth-gpu/a650_zap.mdt \
    --zap-seg research/alioth-gpu/a650_zap.b02

# payload: the cmdline that boots the current UI
python3 tools/mkpayload.py xnu/out/kernel.development.sweet shim/out/alioth.adt shim/out/payload.bin \
    --cmdline 'debug=0xc serial=3 cpus=8 keepsyms=1 -noprogress rd=ufsroot0 \
unentitled_ios_sim_launch=1 ignition_level=1 wdt_test=no_user_checkin ufsrw=1 rootrw=1 \
launchd_unsecure_cache=1 wdt=-1 sweettouch=1 sweettouchdelay=0 sweetkeys=1 sweetusb=0'

cd shim && BOARD=alioth CC=clang OBJCOPY=llvm-objcopy NM=llvm-nm READELF=llvm-readelf \
    ./build.sh out/payload.bin      # -> shim/out/shim-boot-alioth.img
```

`--board alioth` picks the SM8250 memory map, timer INTID 27, the 1080×2400 panel and the
`qcom,kryo470` CPU match. `rd=ufsroot0` is what makes the UFS root probe run at all — the touch,
keys, USB and GPU hooks live inside it. GPU steps are opt-in: `sweetgpu=N` runs steps 1..N
(`sweetgpudelay` seconds after the drivers start, default 15), `sweetgpukeep=1` leaves the CX
domain powered, `sweetgpuzap=N` selects the TrustZone/zap ladder.

Boot arguments are space separated; use a substring without spaces for
`sweetloggrep`.

### 3. Boot it (temporary, non-destructive)

```sh
fastboot boot shim/out/shim-boot-alioth.img
```

Expected: the shim splash, the kernel console (8 CPUs, UFS, drivers), then the HFS mount,
launchd and — after the UI is up — the SpringBoard home screen. Because nothing is written to
the boot partitions, a hard reset always returns to whatever is installed.

### 4. iOS root (destructive — already done on this device)

The root is the iPhone X (iPhone10,3) 16.7.16 (20H392) system, built from the IPSW with
`tools/mkiosroot.sh` (HFS+, case-sensitive, journaled, 16 GiB) plus `tools/sweet-root-tweaks.py`
(Setup skipped, watchdog exceptions, migration marked complete, container dirs, audio disabled),
then written to `userdata`:

```sh
fastboot -S 512M flash userdata ios16-root.simg   # ~5 minutes; ERASES ANDROID USER DATA
```

The ADT must carry the iPhone X `/product` node (mkadt copies it from
`research/ipsw-x/d22ap.adt`, extracted from the same IPSW). Without it SpringBoard aborts in
`SBStartupTransitionLockOut` (`ns 2 code 0x6`) instead of drawing the home screen.

To go back to Android: format `userdata` in a recovery (or flash a fastboot ROM). Nothing else
was changed.

## Repository layout

| Path | What |
| --- | --- |
| `shim/` | Bare-metal boot shim (C + asm) packed as an Android boot image; `BOARD=sweet\|alioth` |
| `xnu/patches/` | The XNU patch series (applied in order by CI), plus staging scripts for libpthread, HFS and BearSSL |
| `.github/workflows/xnu.yml` | Kernel CI build (manual dispatch only) |
| `tools/mkadt.py` | Generates the Apple Device Tree; `--board`, `--gmu-fw`, `--sqe-fw`, `--zap-mdt`, `--zap-seg` |
| `tools/mkpayload.py` | Packs kernel + ADT + boot-args into the shim payload |
| `tools/mkiosroot.sh` | Builds the HFS+ iOS root from the IPSW images |
| `tools/sweet-root-tweaks.py` | Bring-up changes to the root (Setup skip, activation, daemons) |
| `tools/xnu-cc.py` | Local single-file compile check from a CI log |
| `tools/qemu-sweet.py` | QEMU test boots of the sweet board with framebuffer text decoding |
| `tools/adt.py`, `remotezip.py`, `unpack_bootv2.py`, `sparsediff.py` | Helpers |
| `NOTES.md` | Detailed engineering log: every boot, crash and decision, plus hardware facts |

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
| 0098–0100 | USB: femto HS PHY bring-up, 64-bit STARTTRANSFER, apps-SMMU bypass attempt (blocked) |
| 0101–0102 | USB/SMMU reporting, `sweetlogdumpwait` |
| 0103–0108 | GPU phases 1–2, step reordering, log-dump timing and `sweetloggrep` |
| 0109 | Full staged Adreno 650 bring-up (steps 1–21, GMU firmware, HFI, SQE/CP, zap via SCM) |

## GPU bring-up (state of the art in this fork)

`bsd/dev/sweet_gpu.c` is a staged driver adapted from
[aTechGeekDev/ios-apollo](https://github.com/aTechGeekDev/ios-apollo) (which descends from
HackiOS's `redwood_adreno.c`). Nothing runs without `sweetgpu=N`; each step prints what it is
about to touch. Verified on alioth so far:

- steps 1–6: GCC GPU clocks, GPUCC, CX power on (`cx gdsc 0x00222001 → 0xf0222000`), GPU bus and
  GMU clocks, GMU always-on counter ticking at **19.2 MHz** — the block is alive;
- steps 7–10: RSCC, the GPU's SMMU ID/stream registers, context 0, and a GMU DTCM write/read test
  (`0x600d0001/0x0a110002` read back), so firmware can be loaded;
- steps 11–14: `a650_gmu.bin` loaded from the ADT, **GMU firmware running** (`fw_init_result
  0x100`), and the HFI message queues up;
- steps 15–17: the RPMh command DB is read, the HFI speed/bus/start messages are accepted, and
  the **3D core powers on**: `gx gdsc 0x00222001 → 0xf8222800`, `rbbm_status 0x1`.

Not yet: steps 18–19 (SQE microcode and the command processor) and 20 (the zap shader through
TrustZone, `sweetgpuzap`).

A lesson worth keeping: SMMU/GMU registers are emulated by the hypervisor and only plain,
non-inlined single `ldr`/`str` accesses work — a C loop can compile to a post-indexed load and
freeze the phone. The same class of bug was behind the USB gadget's `STARTTRANSFER` freeze.

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
- GPU: Adreno 650 (`0x06050002`), GPUCC `0x3d90000`, GMU `0x3d6a000`, KGSL SMMU `0x3da0000`,
  zap memory `0x8681a000`.
- USB: DWC3 `0xa600000`, femto HS PHY `0x88e3000`, apps SMMU `0x15000000` (StreamID 0).
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
iOS itself is Apple's and is not distributed here.
