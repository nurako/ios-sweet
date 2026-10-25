> [!WARNING]
> **This project is incomplete, highly experimental, and can brick your device.**
> It boots a modified Apple XNU kernel on hardware it was never meant for. Drivers are
> half-ported, large parts of the system do not work, and a wrong flash can leave the phone
> unbootable. Stage 4 additionally **erases all Android user data**. Only use devices with an
> unlocked bootloader that you can afford to lose, keep partition backups, and expect nothing
> here to be safe or finished. Everything you do with this software is at your own risk.

# iOS 16 on the Xiaomi Mi 11X (alioth)

**This is the Mi 11X fork of [dipa-studio/ios-sweet](https://github.com/dipa-studio/ios-sweet)**
(the Redmi Note 10 Pro project, which boots to the iOS home screen). This fork ports the same
Apple XNU kernel (xnu-8796, the iOS 16 generation) to the **Xiaomi Mi 11X** (`alioth`, Qualcomm
SM8250-AC / Snapdragon 870). One tree supports both phones: the board is selected with
`--board alioth` in `tools/mkadt.py` and `BOARD=alioth` in `shim/build.sh`; the upstream sweet
defaults are untouched, so sweet keeps building and booting as before.

On sweet, the unmodified iOS 16.7.16 (20H392) userland of the iPhone X runs: launchd, the system
daemons, backboardd, SpringBoard and the stock apps, with touch and buttons. **On alioth the
bring-up is at the kernel stage (stage 2 of the porting guide), reached 2026-10-22:** the shim,
UFS storage driver and the XNU kernel all work, and the kernel boots end to end into the BSD root
wait — it stops only because no iOS root has been flashed yet. The touch and button drivers are
sweet-specific (Goodix/I²C, PMIC/SPMI) and are being re-ported for alioth's hardware
(FocalTech FT3698 over SPI, PM8150 GPIO keys).

> Experimental bring-up, not a usable phone OS. On alioth nothing is installed yet; the iOS root
> (stage 4) flashes into the `userdata` partition and **erases Android's user data**. Everything
> here runs with Apple's security model mostly switched off.

## Current status on alioth (2026-10-22)

| Area | State |
| --- | --- |
| Boot | Stock Xiaomi bootloader → temporary `fastboot boot` of our shim → XNU. Nothing is flashed to the boot partitions |
| CPU | Boot CPU (Cortex-A77 prime); the ADT defines all 8 cores (1×A77 @2.84 + 3×A77 @2.42 + 4×A55 @1.80 GHz); `cpus=1` so far, SMP bring-up path ready but untested on alioth |
| Memory | Upper DDR bank, `0x1_00000000` + 0x140000000 (5 GiB), 16K pages, GICv3, virtual timer INTID 27 |
| Storage | Own UFS host driver; GPT of the internal UFS parsed. No root volume yet — the kernel waits at `Waiting on <IOMedia, Apple_HFS>` |
| Kernel | XNU reaches `bsd_init`: AMFI/Sandbox policies, HFS driver, networking stubs all up |
| Display | Kernel IOSurface + IOMobileFramebuffer (`AppleCLCD`) services registered; panel 1080×2400 from the ABL splash; presented to iOS as an iPhone X panel (1125×2436) |
| iOS userland | **Not yet** — needs the root image (stage 4, pending: it erases Android user data) |
| Touch / buttons | **Not yet** — ports in progress: FocalTech FT3698 on QUP SPI SE4, keys on PM8150 GPIO6 |
| Battery | Static fallback service (100 %, 4200 mV) registered |
| Device identity | iPhone X (`iPhone10,3` / `D22AP`), same "Hactivation" path as sweet — prepared, untested without a root |

What does not work yet on alioth: everything from the userland down (no iOS root), input drivers,
SMP beyond the boot CPU, and all the upstream limitations too (no Wi-Fi, Bluetooth, cellular,
audio, camera, sensors, GPU).

## How it boots

```
ABL (stock Xiaomi bootloader, unlocked)
  -> fastboot boot shim/out/shim-boot-alioth.img     (temporary; nothing is flashed to boot)
     -> shim: own MMU setup, reads the live FDT, loads the payload from the ramdisk
        -> XNU Mach-O + generated Apple Device Tree (ADT) + boot-args
           -> XNU -> UFS driver -> (root on the userdata partition, once flashed)
              -> dyld + shared cache -> launchd -> daemons -> backboardd + SpringBoard
```

There is no serial port (the debug UART is wired as SPI on this board). The kernel draws its
console into the framebuffer that ABL leaves at `0x9c000000`; on alioth the console is read off
the screen until the USB live-log path is ported.

## How to build and boot (alioth)

You need a Mi 11X (`alioth`) with an **unlocked bootloader**, a Linux PC, and a GitHub account for
the kernel build. Everything on `userdata` is only lost when the iOS root is flashed (stage 4);
the steps below never write to the phone's storage.

### 0. The device tree

The shim needs the phone's live FDT. Either unpack it from the stock `boot.img`
(`python3 tools/unpack_bootv2.py backup/boot.img dtb/boot_unpacked`) or dump the live FDT from a
rooted device. The alioth shim build defaults to `../../phone/live.dtb` (kept **outside** the
repo, like all device dumps); pass `DTB=<path>` to override.

### 1. Build the kernel

The kernel builds on GitHub's macOS runners with [blacktop/darwin-xnu-build](https://github.com/blacktop/darwin-xnu-build).
The workflow fetches xnu-8796 and applies `xnu/patches/` in order. Fork the repo (public repos
get free macOS minutes) and run:

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
python3 tools/mkadt.py shim/out/alioth.adt --board alioth --highmem
python3 tools/mkpayload.py xnu/out/kernel.development.sweet shim/out/alioth.adt shim/out/payload.bin \
    --cmdline 'debug=0xc serial=3 cpus=1 keepsyms=1 sweettouch=0 sweetkeys=0'
cd shim && BOARD=alioth CC=clang OBJCOPY=llvm-objcopy NM=llvm-nm READELF=llvm-readelf \
    ./build.sh out/payload.bin      # -> shim/out/shim-boot-alioth.img
```

`--board alioth` picks the SM8250 memory map, timer INTID 27 and the alioth panel; `BOARD=alioth`
compiles the shim with `-DALIOTH` and embeds the alioth DTB. `cpus=1` is the current safe
setting; `sweettouch=0 sweetkeys=0` disable the not-yet-ported input drivers.

### 3. Boot it (temporary, non-destructive)

```sh
fastboot boot shim/out/shim-boot-alioth.img
```

Expected on the screen: the shim splash, then the kernel console ending in the Apple copyright
banner and `Waiting on <IOMedia, Apple_HFS>` — the kernel idle at the root wait. To get the phone
back, long-press Power to hard-reset into Android (nothing was written).

### 4. iOS root (stage 4 — NOT yet performed on alioth)

Same recipe as upstream: build the iPhone X (iPhone10,3) 16.7.16 root from the IPSW with
`tools/mkiosroot.sh` + `tools/sweet-root-tweaks.py` (see upstream README / `NOTES.md`), then

```sh
fastboot -S 512M flash userdata ios16-root.simg   # ~7 minutes; ERASES ANDROID USER DATA
fastboot boot shim/out/shim-boot-alioth.img
```

This is destructive to Android data and is deliberately **on hold** until the user approves the
concrete step. Bootloaders, recovery, modem, persist and their backups are never touched.

## Repository layout

| Path | What |
| --- | --- |
| `shim/` | Bare-metal boot shim (C + asm) packed as an Android boot.img v2; `BOARD=sweet\|alioth` |
| `xnu/patches/` | The XNU patch series (applied in order by CI), plus staging scripts for libpthread, HFS and BearSSL |
| `.github/workflows/xnu.yml` | Kernel CI build |
| `tools/mkadt.py` | Generates the Apple Device Tree; `--board sweet\|alioth` selects the memory map, timer and panel |
| `tools/mkpayload.py` | Packs kernel + ADT + boot-args into the shim payload |
| `tools/mkiosroot.sh` | Builds the HFS+ iOS root from the IPSW images |
| `tools/sweet-root-tweaks.py` | Bring-up changes to the root (Setup skip, activation, daemons) |
| `tools/xnu-cc.py` | Local single-file compile check from a CI log |
| `tools/qemu-sweet.py` | QEMU test boots of the sweet board with framebuffer text decoding |
| `tools/adt.py`, `remotezip.py`, `unpack_bootv2.py`, `sparsediff.py` | Helpers |
| `NOTES.md` | Detailed engineering log: every boot, crash and decision, plus hardware facts |

Not in git: partition backups, live device trees, recovery images, Apple firmware and root images,
and downloaded or generated build trees. They contain device serials and calibration data, or
Apple's copyrighted files.

## Kernel patches

The full patch series (0001–0069) is inherited from upstream and documented in
[`NOTES.md`](NOTES.md). The alioth-specific work in this fork so far is toolchain-side
(mkadt/shim board switch); the driver ports in flight are:

| # | What |
| --- | --- |
| 0060 | Being re-ported for alioth: power/volume keys on PM8150 GPIO6 (PPID 0x0c5/0xc510); touch on QUP SPI SE4 (0x990000), FocalTech FT3698 instead of Goodix/I²C |
| 0062 | Being re-ported for alioth: touch power rail (PM8150 L10C + GPIO69) instead of the sweet RPMh vote |

## Key hardware facts (alioth)

- SoC: SM8250-AC (Snapdragon 870), Kryo 485 tri-cluster: 1×Cortex-A77 @2.8416 GHz (prime),
  3×A77 @2.4192 GHz, 4×A55 @1.8048 GHz. MPIDR uses Aff1 for the core number.
- RAM: 8 GB; the kernel runs in the upper bank `0x1_00000000` + `0x140000000` (5 GiB), above
  Qualcomm's protected carve-outs (the low bank carries all fixed reserved regions).
- GICv3 with security extensions: the virtual timer is PPI 11 → **INTID 27** (sweet uses 19).
  PSCI through `smc`, 19.2 MHz timer, ARMv8.2 without pointer authentication.
- UFS host controller at `0x01d84000`; framebuffer at `0x9c000000` (ABL splash, 23 MiB).
- Panel: 1080×2400 DSC command mode (`qcom,mdss_dsi_k11a_38_08_0a_dsc_cmd`), continuous splash
  from ABL — electrically the same presentation as sweet, so the kernel console settings are
  shared.
- Touch (to be ported): FocalTech FT3698 on QUP SPI SE4 (`0x990000`), rail = PM8150 L10C + GPIO69.
- Buttons (to be ported): PM8150 GPIO6, PPID 0x0c5/0xc510.
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
hardware details, and the upstream **ios-sweet** project by dipa-studio. This fork adapts it to
the Xiaomi Mi 11X. iOS itself is Apple's and is not distributed here.
