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

## 5. Build-system changes (see `build-integration.patch`)

* `bsd/conf/files`: add `hakios.board.c`, `hakios.adreno.c`,
  `hakios_gpu_adapter.c` (`standard`).
* `iokit/conf/files.arm64` (not `iokit/conf/files`): add `hakios.gpu.cpp` and
  `hakios_miniosurface_stub.cpp` (`optional iokitcpp`); swap the stub for
  `MiniIOSurface.cpp` only after the SweetSurface merge.
* Copy headers to `bsd/sys/hakios.board.h`, `bsd/sys/hakios.input.h`,
  `iokit/Kernel/MiniIOSurface.h`, `iokit/Kernel/MiniDrivers.h`.
* Call `hakios_adreno_init()` from `sweet_ufs_init()` after
  `sweet_gpu_init()`. It returns immediately unless `adreno=N` or `gpu=1`.
* No new CFLAGS are needed for these files; both compile with the flags
  `xnu-cc.py` borrows from the existing CI commands.

## 6. Ordered plan and effort

| # | step | effort |
| --- | --- | --- |
| 0 | port the two files + adapter + this inventory (this branch) | **done, ~1 day** |
| 1 | wire the build patch into a new numbered `xnu/patches/0119-...` on the branch only, add `/chosen hakios-board`, add `board_pil_gpu*` to the alioth boot cmdline | 0.5 day |
| 2 | one CI run + one `fastboot boot` at `adreno=1..21`, compare the step log with our probe (zap/GMU/CP), no service yet | 1-2 days |
| 3 | `adreno_keep=1` + `HakiosGPUStart()`: bring the IOKit service up; validate DRM gem/submit with a tiny userland client | 2-3 days |
| 4 | merge surface buffers: adapt `surfaceBuffer()` to `SweetSurface` (or move to MiniIOSurface), keep AppleCLCD/HID working | 3-5 days |
| 5 | port `osfmk/arm64/gic_v3_irq.c` (or a GPU-only SPI path) and enable `gpu_irq=1` | 2-3 days |
| 6 | display bridge (`MiniIOMobileFramebufferShow`/scanout) and the Mesa/`eagl.c` userland path (outside this kernel port) | 1-2 weeks |

Stop points that are honest: after step 2 the reference driver either reaches
its step 21 and draws its 2D test frame, or the log says exactly which step
fails. Only after step 4 does the GPU service have real IOSurface-backed
buffers, and only after step 6 do OpenGL ES apps render.

## 7. Files added by this port

```
hakios-port/kernel/...                 reference sources, verbatim
hakios-port/adapter/hakios_gpu_adapter.c
hakios-port/adapter/hakios_miniosurface_stub.cpp
hakios-port/build-integration.patch    proposed bsd/iokit/start changes
hakios-port/ORIGIN.md                  provenance + licenses
hakios-port/PORT-NOTES.md              this file
```
