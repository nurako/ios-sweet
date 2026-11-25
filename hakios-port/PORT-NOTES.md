# Port notes: xiongnemo/hakios-alioth GPU stack -> ios-sweet (hakios-gpu branch)

Status: **phase 1, compile-only evaluation**. The two big reference sources and
their headers compile against this tree with a small adapter. Nothing is wired
into the CI patch series; `research/ci-buildtree` is untouched except for
temporary copies used by `tools/xnu-cc.py` (git-ignored).

## 1. What was imported

See `ORIGIN.md`. Sizes: `hakios.adreno.c` 5355 lines, `hakios.gpu.cpp` 1888,
`hakios.board.c` 148, `MiniIOSurface.cpp` 2149, `MiniIOSurface.h` 225.

The reference's build description (`drivers/gpu/conf`) only says:

```
driver ADRENO
    file bsd/dev/hakios.adreno.c
    file iokit/Kernel/hakios.gpu.cpp iokitcpp
```

Their `devices/redmi-k40/xnu-device.patch` adds `bsd/dev/hakios.board.c` to
`bsd/conf/files`; the GPU files themselves are added by their generated config
(`drivers/gpu/conf` -> `hakios-config.py`), not by that patch. On this tree the
equivalent edits are in `build-integration.patch`.

## 2. Compile result (verified locally)

Command shape, once per file:

```
XNU_CC_CLANG=/usr/bin/clang python3 tools/xnu-cc.py /tmp/ci.log \
    research/ci-buildtree <path-under-xnu> --per-file
```

`/tmp/ci.log` is `gh run view 45663768795 -R nurako/ios-sweet --log`.

| file | syntax check | notes |
| --- | --- | --- |
| `bsd/dev/hakios.adreno.c` | **OK** | 0 of 1 failed |
| `bsd/dev/hakios.board.c` | **OK** | developer-mode calls exist in our `kern_codesigning.c` |
| `iokit/Kernel/hakios.gpu.cpp` | **OK** | against imported `MiniIOSurface.h` |
| `iokit/Kernel/MiniIOSurface.cpp` | **OK standalone** | **not linked**: duplicate `IOSurfaceRootUserClient` with `SweetSurface.cpp` |
| `bsd/dev/hakios_gpu_adapter.c` | **OK** | new adapter |
| `iokit/Kernel/hakios_miniosurface_stub.cpp` | **OK** | new stub for phase 1 |

Link-level check (`XNU_CC_OBJDIR` + `llvm-nm`, compared with the CI
`config/allsymbols`): every custom symbol is satisfied by the imported objects,
the adapter, or an existing kernel symbol. The only names not found in
`allsymbols` are private kernel startup symbols that do exist in the kernel
sources (`kernel_startup_tunable_init`, `kmem_alloc_guard`,
`kmem_free_guard`, `lck_*_startup_init`, `sysctl_register_oid_early`).

## 3. External symbols: what the reference needs, and its state here

### 3.1 Provided by this tree already

`ml_io_map`, `ml_io_map_wcomb`, `kvtophys`, `kernel_map`, `kmem_alloc_guard`,
`kmem_free_guard`, `lck_*`, `PE_parse_boot_argn`, `SecureDT*`, `printf`,
`thread_set_thread_name`, `pe_arm_get_soc_base_phys`,
`enable_developer_mode`/`disable_developer_mode`/`developer_mode_state`,
`get_task_uniqueid`, all standard BSD/IOLib/kern calls.

### 3.2 Implemented by `adapter/hakios_gpu_adapter.c`

| reference symbol | where it lives upstream | adapter behaviour |
| --- | --- | --- |
| `hakios_image_file(dir,name,size,disk)` | `bsd/dev/hakios.image.c` (RAM-disk image) | reads ADT `/sweet-gpu` properties (see 4) |
| `hakios_tl(fmt,...)` | `bsd/dev/hakios.cpufreq.c` | `printf` |
| `loader_log_putc` | `osfmk/arm64/loader_return.c` | no-op (no UEFI loader ring here) |
| `loader_return` | same | log + no-op (no loader to return to) |
| `hakios_screen_off` | `bsd/dev/hakios.cpufreq.c` | `false` |
| `hakios_input_at` | `bsd/dev/hakios.input.c` | `0` (governor's touch boost inert) |
| `hakios_data_range` | `bsd/dev/hakios.image.c` | zeros |
| `MiniIOMobileFramebufferShow` | `iokit/Kernel/MiniIOMobileFramebuffer.cpp` | logs once; **no panel copy** |
| `gic_v3_spi_attach/mask/detach` | `osfmk/arm64/gic_v3_irq.c` | **stub**: attach returns `KERN_FAILURE` |

### 3.3 Imported alongside the GPU files

* `hakios_board_addr/number/report/kona_name/is_alioth/panel_height` —
  `hakios.board.c` (alioth speed table + 2400-line panel selection).
* `HakiosGPUStart/Stop`, `hakios_gpu_screen` — defined in `hakios.gpu.cpp`.
* `hakios_gpu_*`, `hakios_adreno_init/stop/quiesce/minute`, `gpu_log` —
  defined in `hakios.adreno.c`.
* `MiniIOSurfaceCopy/Drop/CreateSimple/MakeSendRight` — for phase 1 supplied
  by `adapter/hakios_miniosurface_stub.cpp`; full implementation is
  `MiniIOSurface.cpp`, currently blocked by the SweetSurface conflict below.

### 3.4 Still functionally missing (not just unresolved symbols)

1. **GICv3 SPI delivery.** Our tree has no `gic_v3_irq.c`; the reference adds
   it in `xnu/hakios.patch` (508 lines, ICC_*_EL1, redistributor per CPU,
   INTID 332 for the GPU). The adapter fails the attach, so the driver falls
   back to polling its fence (`gpu_irq_on()` handles this). To get the
   reference's IRQ-driven waits, port that file (and the PSCI/GIC hooks its
   `GENERIC_GIC_V3_IRQ` config expects).
2. **Panel copy / display bridge.** `MiniIOMobileFramebufferShow` only logs.
   This tree's display is `AppleCLCD` in
   `iokit/Kernel/arm/SweetFramebuffer.cpp`; a bridge must copy the 1080x2400
   BGRA image into the panel framebuffer (or the surface lookup path). The
   reference's own `MiniIOMobileFramebuffer.cpp` is a different display stack
   and should not be imported wholesale.
3. **IOSurface merge.** `MiniIOSurface.cpp` and `SweetSurface.cpp` both define
   `IOSurfaceRootUserClient`; two impls cannot link. Phase 1 therefore uses the
   header plus stubs. Real GPU buffers-from-IOSurfaces need either
   (a) adapting `hakios.gpu.cpp` to `SweetSurface`, or (b) replacing
   SweetSurface with MiniIOSurface after re-validating display/HID. Recommended:
   (a), a copy of the `surfaceBuffer()`/`MiniIOSurfaceDrawn()` glue, because
   SweetSurface is already wired into AppleCLCD and SweetHID.
4. **`/chosen` board identity.** `hakios_board_is_alioth()` reads
   `/chosen hakios-board`; `tools/mkadt.py` does not emit it yet. Without it
   the driver uses the UMI tables (587 MHz top, 2340-line panel) instead of
   alioth's 370/470/570/670 MHz and 2400 lines. Add
   `('hakios-board', cstr('alioth'))` on the alioth board (patch hunk not yet
   included in `build-integration.patch`; see next steps).
5. **Zap region address.** Alioth's `pil_gpu` is at `0x8681a000`/`0x2000` on
   the current firmware. Pass `board_pil_gpu=0x8681a000
   board_pil_gpu_size=0x2000` on the cmdline, or teach the adapter/board to
   read `/reserved-memory` from the ADT. Wrong address stalls the phone.
6. **`mdevlookup`/`mdevgetkernelrange`.** Declared in `hakios.adreno.c` but no
   reference in the compiled object; not needed for this driver.
7. **GPU service boot args.** The reference keeps the GPU with
   `adreno=21 adreno_keep=1`, or starts by itself with `gpu=1
   adreno_keep=1`. Our probe uses `sweetgpu=N`; keep both until the new stack
   is proven. `gpu_irq=1` needs item 1.

## 4. Firmware delivery adaptation (done in the adapter)

Our ADT already carries the four blobs at `/sweet-gpu`
(`tools/mkadt.py --gmu-fw --sqe-fw --zap-mdt --zap-seg`). The reference asks
for vendor names under `fw/`; `hakios_image_file()` maps them:

| reference name | ADT property |
| --- | --- |
| `a650_gmu.bin` / `a660_gmu.bin` | `gmu-firmware` |
| `a650_sqe.fw` / `a660_sqe.fw` | `sqe-firmware` |
| `a650_zap.mdt` / `a660_zap.mdt` | `zap-metadata` |
| `a650_zap.b02` / `a660_zap.b02` | `zap-segment` |

Returned pointers point into the ADT (valid for the kernel's life), matching
the reference's contract. `disk_out` is `-1` (no RAM-disk image).

## 5. Build-system changes (`xnu/patches/0200-hakios-gpu.patch`)

The scratch `build-integration.patch` has been turned into the real numbered
patch **`xnu/patches/0200-hakios-gpu.patch`** (branch only; main's series stops
at 0118). It adds the full source files, not just the config lines. It was
generated from a tree that had patches 0001..0118 applied and checked with
`git apply --check` against that exact CI state; it does not touch
`bsd/dev/sweet_gpu.c` (that name appears only as context in `bsd/conf/files`).

* `bsd/conf/files`: add `hakios.board.c`, `hakios.adreno.c`,
  `hakios_gpu_adapter.c` (`standard`).
* `iokit/conf/files.arm64` (not `iokit/conf/files`): add `hakios.gpu.cpp` and
  `hakios_miniosurface_stub.cpp` (`optional iokitcpp`); swap the stub for
  `MiniIOSurface.cpp` only after the SweetSurface merge.
* Copy headers to `bsd/sys/hakios.board.h`, `bsd/sys/hakios.input.h`,
  `iokit/Kernel/MiniIOSurface.h`, `iokit/Kernel/MiniDrivers.h`.
* Call `hakios_adreno_init()` from `sweet_ufs_init()` after
  `sweet_gpu_init()`, gated on `PE_parse_boot_argn("adreno", ...) != 0`, so
  the default boot and existing `sweetgpu=N` runs are unchanged.
* `tools/mkadt.py`: `--board alioth` now emits
  `/chosen hakios-board = "alioth\0"` (7 bytes, as `hakios_board_is_alioth()`
  requires; `cstr()` supplies the NUL). `--board sweet` output is byte-for-byte
  unchanged (checked with fixed-seed builds for sweet, sweet --highmem and
  sweet --qemu: same SHA-256 before and after).
* No new CFLAGS are needed for these files; both compile with the flags
  `xnu-cc.py` borrows from the existing CI commands.

## 6. Ordered plan and effort

| # | step | effort |
| --- | --- | --- |
| 0 | port the two files + adapter + this inventory (this branch) | **done, ~1 day** |
| 1 | `xnu/patches/0200-hakios-gpu.patch`, `/chosen hakios-board`, and the evaluation cmdline with `board_pil_gpu*` | **done, see section 7** |
| 2 | one CI run + one `fastboot boot` at `adreno=1..22`, compare the step log with our probe (zap/GMU/CP/frame), no service yet | 1-2 days |
| 3 | `adreno_keep=1` + `HakiosGPUStart()`: bring the IOKit service up; validate DRM gem/submit with a tiny userland client | 2-3 days |
| 4 | merge surface buffers: adapt `surfaceBuffer()` to `SweetSurface` (or move to MiniIOSurface), keep AppleCLCD/HID working | 3-5 days |
| 5 | port `osfmk/arm64/gic_v3_irq.c` (or a GPU-only SPI path) and enable `gpu_irq=1` | 2-3 days |
| 6 | display bridge (`MiniIOMobileFramebufferShow`/scanout) and the Mesa/`eagl.c` userland path (outside this kernel port) | 1-2 weeks |

Stop points that are honest: after step 2 the reference driver either reaches
its step 21 and draws its 2D test frame, or the log says exactly which step
fails. Only after step 4 does the GPU service have real IOSurface-backed
buffers, and only after step 6 do OpenGL ES apps render.

## 7. Evaluation boot (one bootable build)

Generate the ADT with the GPU blobs (the adapter serves these four properties;
verified in a generated alioth ADT: `gmu-firmware` 41548 B, `sqe-firmware`
31632 B, `zap-metadata` 6860 B, `zap-segment` 1676 B under `/sweet-gpu`):

```
python3 tools/mkadt.py shim/out/alioth.adt --board alioth --highmem \
    --gmu-fw research/alioth-gpu/a650_gmu.bin \
    --sqe-fw research/alioth-gpu/a650_sqe.fw \
    --zap-mdt research/alioth-gpu/a650_zap.mdt \
    --zap-seg research/alioth-gpu/a650_zap.b02
```

Kernel cmdline for the evaluation boot (`sweetgpu=0` keeps the old probe off;
`adreno=22` runs the reference ladder through the 2D frame; `adreno_keep=0`
lets it stop cleanly after the watch instead of starting HakiosGPU):

```
debug=0xc serial=3 cpus=8 keepsyms=1 -noprogress rd=ufsroot0 \
unentitled_ios_sim_launch=1 ignition_level=1 wdt_test=no_user_checkin \
ufsrw=1 rootrw=1 launchd_unsecure_cache=1 wdt=-1 \
sweettouch=1 sweettouchdelay=0 sweetkeys=1 sweetusb=0 sweetgpu=0 \
board_pil_gpu=0x8681a000 board_pil_gpu_size=0x2000 \
adreno=22 adreno_keep=0 adreno_pause=0 adreno_watch=30 gpu_irq=0
```

`adreno=N` runs steps 1..N and stops at the first failure. Use `adreno=4`,
`=10`, `=13`, `=15`, `=17`, `=20`, `=21`, `=22` to bisect. `adreno_keep=1`
with `adreno=21` or `22` additionally starts the HakiosGPU service (not useful
until the surface merge), and `adreno_skip=0x...` skips step bits (e.g. the
reference's `gpu=1` path skips steps 10-12 on its other board; do not skip them
here).

What to look for (all lines start with `adreno:`):

| step | line that shows success |
| --- | --- |
| 1-3 | `step 3: done`; GPUCC reads, PLL/GDSC values |
| 4 | `CX is on` |
| 5 | clocks reported on, GMU RCG at 200 MHz |
| 6-7 | GMU/RPMh register reads; no `FAILED` |
| 8-9 | `SMMU: ... stream match registers ...`; context test |
| 10 | `TAKES WHAT IS WRITTEN: its firmware can be loaded` |
| 11-12 | `TRUSTZONE ACCEPTS THE ZAP SHADER'S SIGNATURE FROM THIS KERNEL` |
| 13-14 | `THE GMU'S FIRMWARE IS LOADED` |
| 15 | `THE GMU'S FIRMWARE RUNS` |
| 16 | `THE GMU'S MESSAGE QUEUES ARE UP` |
| 17 | `THE 3D CORE HAS POWER AND ANSWERS` |
| 18 | 3D-core SMMU context and SQE microcode loaded |
| 19 | `TRUSTZONE HAS AUTHENTICATED AND STARTED THE ZAP SHADER` |
| 20 | `THE 3D CORE TAKES COMMANDS` |
| 21 | `THE 3D CORE WRITES OUR MEMORY ON COMMAND` |
| 22 | first-pixel line then **`A PICTURE DRAWN BY THE GPU IS ON THE PANEL: orange, white, blue from the top`** |

A failure prints `adreno: step N: FAILED; the steps after it are not attempted`
and the next steps are skipped. The 2D-frame success criterion is the pixel
readback (`the picture's first pixel is 00 80 ff ff ...`) plus the step-22
line above. **Caveat:** the adapter's `MiniIOMobileFramebufferShow()` only logs
the request, so the pixels are proven in GPU memory but are not yet copied to
the panel; a screenshot will not show the bands until the display bridge is
implemented. Read the log on the next boot with
`sweetlogdump=262144 sweetloggrep=adreno sweetlogdumpwait=120 ufslogsecs=1`
(and keep `sweetgpu=0`).

## 8. Files added by this port

```
hakios-port/kernel/...                 reference sources, verbatim
hakios-port/adapter/hakios_gpu_adapter.c
hakios-port/adapter/hakios_miniosurface_stub.cpp
hakios-port/build-integration.patch    proposed bsd/iokit/start changes
hakios-port/ORIGIN.md                  provenance + licenses
hakios-port/PORT-NOTES.md              this file
```

## 2026-11-25: first evaluation boot (Image HK1 `b0e2d767...`)

Kernel from CI run 45670566657 on branch `hakios-gpu`; ADT regenerated with
`/chosen hakios-board = "alioth"`; cmdline `sweetgpu=0 ... adreno=22 gpu_irq=0
board_pil_gpu=0x8681a000 board_pil_gpu_size=0x2000`.

Their driver ran the whole ladder without panic and iOS stayed interactive:

```
adreno: 20: THE 3D CORE TAKES COMMANDS
adreno: 21: the 3D core has done it (ring read up to 11, status 0x1)      <- out of secure mode
adreno: 21: the page reads 0x600dc0de: THE 3D CORE WRITES OUR MEMORY ON COMMAND
adreno: 22: the 3D core has done it (ring read up to 123, status 0x1)
adreno: 22: the picture's first pixel is 00 80 ff ff (told 00 80 ff ff),
            middle ff ff ff ff, last row ff 80 00 ff
adreno: 22: A PICTURE DRAWN BY THE GPU IS ON THE PANEL: orange, white, blue
```
So on OUR kernel and OUR ADT the Adreno 650 draws a correct frame in memory,
and `CP_SET_SECURE_MODE` does not wedge their CP (the zap is authenticated with
the core powered, which is what our own probe could not make work).

Remaining to see it on the panel: `MiniIOMobileFramebufferShow()` is still an
adapter log line; it must copy 1080x2400 rows (4352 bytes pitch) into the
AppleCLCD framebuffer.
