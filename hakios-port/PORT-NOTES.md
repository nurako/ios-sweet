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
line above. `MiniIOMobileFramebufferShow()` now copies the frame into the
console's existing framebuffer mapping (section 9), so the bands should also
be visible. Read the log on the next boot with
`sweetlogdump=262144 sweetloggrep=adreno sweetlogdumpwait=120 ufslogsecs=1`
(and keep `sweetgpu=0`).

## 8. Panel bridge and GIC SPI (2026-11-26)

### Panel copy

`MiniIOMobileFramebufferShow()` now copies the frame into the **kernel text
console's existing mapping** of the boot framebuffer. `osfmk/console/video_console.c`
maps it early with `ml_io_map_unmappable()` (outside the 8 MB io submap, so no
`KERN_NO_SPACE` panic) and publishes the writable VA as the global
`struct vc_info vinfo`; its `v_rowbytes` is the panel stride (4320). The adapter
externs `vinfo`, copies `min(width, v_width) * 4` bytes per row for
`min(height, v_height)` rows from the GPU's `row_bytes` pitch to `v_rowbytes`,
then executes `dsb sy`. It does **not** call `ml_io_map` at all.

Cmdline (panel test; same as before):

```
debug=0xc serial=3 cpus=8 keepsyms=1 -noprogress rd=ufsroot0 \
unentitled_ios_sim_launch=1 ignition_level=1 wdt_test=no_user_checkin \
ufsrw=1 rootrw=1 launchd_unsecure_cache=1 wdt=-1 \
sweettouch=1 sweettouchdelay=0 sweetkeys=1 sweetusb=0 sweetgpu=0 \
board_pil_gpu=0x8681a000 board_pil_gpu_size=0x2000 \
adreno=22 adreno_keep=0 adreno_pause=0 adreno_watch=30 gpu_irq=0
```

Proof lines:

* `HAKIOS GPU: panel copy 1080x2400 row 4352 -> 1080x2400 row 4320 via the console framebuffer mapping (vinfo ..., phys 0x9c000000)`
* the driver's `adreno: 22: A PICTURE DRAWN BY THE GPU IS ON THE PANEL: orange, white, blue from the top`

The bands are written to the real panel memory; later kernel log lines still
draw over the top of the image, so film the boot or use `sweetlogdump` to catch
the moment. If the line begins `panel copy skipped`, `vinfo` had no framebuffer
(console not initialised / no video).

### GICv3 SPI 332

The GPU's interrupt is SPI 300, INTID 332, level (`live.dts` kgsl-3d0:
`interrupts = <0 0x12c 4>`). The adapter now owns a small SPI path: it maps the
64 KiB GICD from `/arm-io/gic` (the tree's `pe_fiq.c` sets up the GIC and CPU
interface but keeps its bases private), configures the SPI as Group 1 NS,
priority 0xa0, level, routes it to the attaching processor's MPIDR, enables it,
and installs one dispatcher with `ml_install_interrupt_handler()`.
`sleh_irq()` continues to handle the virtual timer and SGIs itself and sends
every other INTID to that dispatcher, which only looks up attached SPIs and
otherwise does nothing; existing polling drivers are unchanged. It is opt-in:
only `gpu_irq=1` calls `gic_v3_spi_attach()`.

Cmdline (interrupt test; keeping the GPU starts HakiosGPU, which is the only
path that calls `gpu_irq_on()`):

```
debug=0xc serial=3 cpus=8 keepsyms=1 -noprogress rd=ufsroot0 \
unentitled_ios_sim_launch=1 ignition_level=1 wdt_test=no_user_checkin \
ufsrw=1 rootrw=1 launchd_unsecure_cache=1 wdt=-1 \
sweettouch=1 sweettouchdelay=0 sweetkeys=1 sweetusb=0 sweetgpu=0 \
board_pil_gpu=0x8681a000 board_pil_gpu_size=0x2000 \
adreno=22 adreno_keep=1 adreno_pause=0 gpu_irq=1
```

Proof lines:

* `HAKIOS GPU: GIC SPI 332 level attached, routed to MPIDR 0x... (gpu_irq=1)`
* `adreno: THE 3D CORE'S INTERRUPT (GIC 332, level) tells the waits of each submission's end (gpu_irq=1)`
* and **not** `adreno: the 3D core's interrupt (GIC 332) is not taken ... the waits look for the fence as before`.

The attach lines prove configuration; an interrupt actually arrives when a
client submits work with `CP_EVENT_IRQ` (the service's normal fence wait), so
delivery counters/fence waits show it after the surface/buffer path is used.
Until then the GPU still draws (polling) and the panel test is independent.

## 9. Files added by this port

```
hakios-port/kernel/...                 reference sources, verbatim
hakios-port/adapter/hakios_gpu_adapter.c
hakios-port/adapter/hakios_miniosurface_stub.cpp
hakios-port/build-integration.patch    proposed bsd/iokit/start changes
hakios-port/ORIGIN.md                  provenance + licenses
hakios-port/PORT-NOTES.md              this file
```

## 10. Phase 2: HakiosGPU service and SweetSurface adaptation (2026-11-26)

### Decision: adapt MiniIOSurface to SweetSurface, do not replace it

The reference's `MiniIOSurface.cpp` defines a second `IOSurfaceRootUserClient`
with the same C++ names as `SweetSurface.cpp`; building both is a link error,
and replacing SweetSurface would put the working SpringBoard/AppleCLCD CPU path
at risk. The adapter therefore keeps the header and implements only the calls
`hakios.gpu.cpp` uses (`MiniIOSurfaceCopy`, `MiniIOSurfaceDrop`,
`MiniIOSurfaceCreateSimple`, `MiniIOSurfaceMakeSendRight`) as a wrapper around
the existing `SweetSurface`:

* `MiniIOSurfaceCopy(id)` -> `sweet_surface_copy(id)`, fills `client` (the
  SweetSurface pixels descriptor), `kpixels` (its kernel VA), `kbase` (the
  SweetSurface state page, so `shared()->seed` is the same seed the IOSurface
  lock path moves), geometry and `info.allocSize`.
* buffer-backed surfaces present `clientAddress = 0`, `scanPhys = 0`; the
  service's wrap path (`gpu_wrap`, now **default 1**) makes an
  `IOSubMemoryDescriptor` from byte 0 and enters it into the GPU SMMU.
* the physical panel surface (no `IOBufferMemoryDescriptor`) is marked with
  `scanPhys != 0`, so `surfaceBuffer()` maps its physical memory from byte 0.
* `MiniIOSurfaceDrop` releases the SweetSurface with the wrapper.

The `MiniIOSurface` object is a normal `MiniIOSurface` with one extra
`void *sweet_surface` field; no reference `MiniIOSurface.cpp` is built.

### Service and user client

`HakiosGPUStart()` is called only by the keep path (`adreno_keep=1`) and still
publishes class `HakiosGPU` with `kIOUserClientClassKey =
"HakiosGPUUserClient"`. Because `hakios_adreno_init()` runs inside
`sweet_ufs_init()` before `IOKitBSDInit()` has started the platform expert, a
first call with no `IOService::getPlatform()` now defers itself with a
`thread_call` retry (100 ms) instead of dropping the service. Once the
platform is up it publishes and logs. A client opens it with type 0; the
factory base `IOService::newUserClient` reads the user-client class property.

`kMsmGemNew` continues to allocate its own GPU buffers; `clientMemoryForType`
returns that buffer's `IOMemoryDescriptor` for mapping; `surfaceBuffer` wraps a
SweetSurface as above. Surface creation itself stays with the existing
IOSurface framework/SweetSurface user client, so SpringBoard's CPU rendering
is unchanged.

### Interrupts

No new submit code was needed: `hakios_gpu_submit()` already emits
`CP_EVENT_WRITE(EVENT_CACHE_FLUSH | CP_EVENT_IRQ)` when `gpu_irq=1`, and
`gpu_irq=0` leaves `gpu_irq_wanted` zero, so the service polls. The adapter's
SPI 332 handler is the one that wakes the fence waits.

### Boot cmdlines for the next evaluation

Service + interrupt (`adreno_keep=1` is what starts HakiosGPU and `gpu_irq=1`
what attaches SPI 332):

```
debug=0xc serial=3 cpus=8 keepsyms=1 -noprogress rd=ufsroot0 \
unentitled_ios_sim_launch=1 ignition_level=1 wdt_test=no_user_checkin \
ufsrw=1 rootrw=1 launchd_unsecure_cache=1 wdt=-1 \
sweettouch=1 sweettouchdelay=0 sweetkeys=1 sweetusb=0 sweetgpu=0 \
board_pil_gpu=0x8681a000 board_pil_gpu_size=0x2000 \
adreno=22 adreno_keep=1 adreno_pause=0 gpu_irq=1
```

Plain/panel boot (no service, no IRQ; proves the normal path is unchanged):

```
debug=0xc serial=3 cpus=8 keepsyms=1 -noprogress rd=ufsroot0 \
unentitled_ios_sim_launch=1 ignition_level=1 wdt_test=no_user_checkin \
ufsrw=1 rootrw=1 launchd_unsecure_cache=1 wdt=-1 \
sweettouch=1 sweettouchdelay=0 sweetkeys=1 sweetusb=0 sweetgpu=0 \
board_pil_gpu=0x8681a000 board_pil_gpu_size=0x2000 \
adreno=22 adreno_keep=0 adreno_pause=0 adreno_watch=30 gpu_irq=0
```

Proof lines in the service/IRQ boot:

* `HakiosGPU: IOKit platform not up yet; service start deferred` (expected once)
* `HakiosGPU: IOServiceMatching("HakiosGPU") will find this service; open it with type 0`
* `HakiosGPU: service published (class HakiosGPU), user client HakiosGPUUserClient`
* `HAKIOS GPU: GIC SPI 332 level attached, ...` and
  `adreno: THE 3D CORE'S INTERRUPT (GIC 332, level) ...`
* after a client asks for a surface:
  `HakiosGPU: surface N wrapped as MiniIOSurface: WxH fmt 0x... bpr ... size ...`
  and, with `gpu_wrap=1`, no `surface N wraps a program's memory` refusal.

A plain boot must show no `HakiosGPU`/`GIC SPI` lines at all.

### What userland still needs

* the reference's `tools/mesa/hakios-drm` equivalent (Mesa freedreno's
  `msm` ioctl transport: `kMsmGetParam`, `GemNew`, `GemInfo`, `GemCpuPrep`,
  `Submit`, `WaitFence`, `SubmitQueue*`, `surfaceBuffer`), built for iOS;
* Mesa's freedreno/iRP (or their prebuilt) plus `libhakios.metal`/`eagl.c`
  for Metal and OpenGL ES; neither is in this branch;
* a client submission that names a SweetSurface (then the new wrapper path
  and the interrupt fence should be visible). Until then Metal/IOAccelerator
  is not claimed: the kernel service and surface bridge exist, the userland
  DRM emulation does not.

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

## 2026-11-25/26: the GPU's picture is on the panel (Image HK2 `75abf042...`)

CI run 45676272787 on `hakios-gpu` (panel bridge + GIC SPI 332). Boot cmdline
`adreno=22 gpu_irq=0`, `sweetgpu=0`, `board_pil_gpu=0x8681a000 board_pil_gpu_size=0x2000`.

```
HAKIOS GPU: panel copy 1080x2400 row 4352 -> 1080x2400 row 4320 via the console
            framebuffer mapping (vinfo 0xfffffe000b0b0000, phys 0x9c000000)
adreno: 22: A PICTURE DRAWN BY THE GPU IS ON THE PANEL: orange, white, blue from the top
adreno: step 22: done
```
and the phone showed the three bands (orange / white / blue). The Adreno 650 draws
on the panel from our kernel.

## 2026-11-26: interrupt + service (Image HK4 `11ea4904...`)

CI run 45731891772 (phase 2: SweetSurface-backed MiniIOSurface, HakiosGPU publish,
GIC SPI 332). Boot `adreno=22 adreno_keep=1 gpu_irq=1`:
```
HAKIOS GPU: panel copy 1080x2400 row 4352 -> 4320 via the console framebuffer (phys 0x9c000000)
adreno: 22: A PICTURE DRAWN BY THE GPU IS ON THE PANEL: orange, white, blue
HAKIOS GPU: GIC SPI 332 level attached, routed to MPIDR 0x81000000 (gpu_irq=1)
adreno: THE 3D CORE'S INTERRUPT (GIC 332, level) tells the waits of each submission's end (gpu_irq=1)
adreno: THE GPU STAYS ON for the system to draw with; the service HakiosGPU
HakiosGPU: IOServiceMatching("HakiosGPU") will find this service; open it with type 8
HakiosGPU: service published (class HakiosGPU), user client HakiosGPUUserClient
```
Bands on screen; iOS interactive afterwards. Next: a user client that allocates a surface and
submits (needs the userland DRM/Mesa layer).

## 2026-11-26: gl_test panic — illegal PA 0x50304000 and the opt-in test job

The first Mesa userland client (`gl_test`, pid 67, started by launchd) panicked:

```
panic(cpu 6 caller 0xfffffe0007b0ce7c): phystokv_range: illegal PA 0x50304000;
      phys base 0x100000000, size 0x13ff00000 (arm_vm_init.c:406)
```

The caller resolves in the CI kernel artifact of run `45778296613`
(`kernel.development.sweet`, `__TEXT` at `0xfffffe0007004000`) to
`phystokv_range.cold.1+0x44` — the `panic()` at `osfmk/arm64/arm_vm_init.c:406`.
The path to it is `copypv()` → `flush_dcache64(addr, size, phys=TRUE)` (the
`cppvFsnk`/`cppvFsrc` flush), which calls `flush_dcache()` with no `pa_valid()`
guard; `flush_dcache()` then asks `phystokv_range()` for the linear mapping of a
physical address and panics when there is none. `IOMemoryDescriptor::readBytes/
writeBytes` reach `copypv()` with the result of `getPhysicalSegment()`.

**Why 0x50304000 is not a physical address.** It is below both the low DRAM
window (`0x80000000..0xbf000000`) and the high bank (`0x1_00000000..`), so
`pmap_valid_address()` is false for it. It is, however, exactly inside the GPU
address window (`hakios.adreno.c`: `GPU_ADDRESSES_START 0x20000000`,
`GPU_ADDRESSES_SIZE 0xe0000000`, allocations rounded to 64 KiB) and 0x50304000
is 64 KiB-aligned. The other candidates are ruled out by evidence:

* (a) SweetSurface physical memory: `sweet_surface_create_physical()` is called
  with `video.v_baseAddr`; the boot log says `phys 0x9c000000`, not 0x50304000,
  and 0x50304000 is not any panel/carveout address in our ADT.
* (c) SweetSurface kernel base: `kernelAddress()` returns a kernel VA
  (`0xfffffe...`) or an `IOBufferMemoryDescriptor` VA, never a 32-bit PA; the
  seed page is likewise a kernel VA.
* (b) an IOVA mistaken for a PA is the only value consistent with both the
  window and the alignment. `newBuffer()` used to pass every
  `getPhysicalSegment()` result straight into `hakios_gpu_map_in()` and into
  the descriptor the client later maps/copies; the validation was only on the
  segment being non-zero.

**Fix.** `hakios_gpu_phys_ok(phys, size, scanout)` (adapter) accepts only
kernel-managed DRAM (`pmap_valid_address()` at both ends) or, for a scan-out
buffer only, the boot framebuffer range from `vinfo`. `newBuffer()` now checks
the requested `from/size` against `memory->getLength()` and validates **every**
run before entering any page into the SMMU; a refusal is logged and the
request gets `kIOReturnNoMemory`, never a panic. As a second, kernel-wide
guard, `copypv()` only flushes a physical source/sink when
`pmap_valid_address()` says it can be converted; device memory is not flushed
through `flush_dcache64(phys)`. Both are in `xnu/patches/0200-hakios-gpu.patch`
(which still does not touch `bsd/dev/sweet_gpu.c`; 0300 still applies after it).

**The test job is now opt-in.** `tools/add-launchd-jobs.py` and
`tools/daemons/com.hakios.gltest.plist` run `gl_test` only if
`/var/tmp/run-gl-test` exists; the job removes the sentinel *before* starting
the client, so a panic cannot repeat on the next boot. Run it deliberately:

```
# on a mounted root image
touch <mounted-root>/var/tmp/run-gl-test
# or on a booted phone before rebooting
touch /var/tmp/run-gl-test
```

The job then sleeps 5 s (USB gadget) and runs with
`DYLD_LIBRARY_PATH=/usr/local/lib`, output to `/dev/hakios-usb` with a fallback
to `/dev/console`. No sentinel = no gl_test on a normal boot.

**Verification.** `tools/xnu-cc.py` against CI run `45778296613` (`/tmp/ci-fix.log`)
compiles `hakios_gpu_adapter.c`, `hakios.gpu.cpp` and `osfmk/arm64/loose_ends.c`
with 0 failures. Regenerated `0200` applies to blacktop `6639065` + `0001..0118`;
`0300` applies cleanly after it.

**Still uncertain.** The panic string alone cannot name the descriptor that
carried 0x50304000: gl_test's OSMesa path uses only GEM + `kHakiosShow`
(userland notes §1.2), and the exact user call that first produced the value
was not captured (no `HakiosGPU` buffer/surface refusal line appeared before
the panic). The new checks make either the GEM or the surface route refuse that
value; if a later boot logs `physical ... is not kernel memory; refused`, that
line names the route and is the next thing to read.
