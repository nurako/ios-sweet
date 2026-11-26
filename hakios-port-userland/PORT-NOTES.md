# Port notes: hakios userland GPU transport -> ios-sweet (hakios-userland)

Status: **inventory + the OpenGL ES/DRM client ported; Mesa built on a Mac only.**
Kernel side is already in this tree (`hakios-port/kernel/`, patch `0200-hakios-gpu.patch`).
This directory is the userland half from `xiongnemo/hakios-alioth` commit
`78a91a456e50330ba3136127b911a4bbff30140f` (2026-11-26), MIT for everything under
`userland/`, `tools/` and `devices/` (see `ORIGIN.md`).

Nothing here was pushed, dispatched or run on a device.

## 1. What the reference transport actually is

There are **two independent graphics paths** in the reference, plus an experimental third.

### 1.1 OpenGL ES on Adreno (the one that works)

```
iOS process (backboardd, SpringBoard, a game)
  EAGLContext / gl*            userland/src/eagl.c (this port only for CA)
    libOSMesa.8.dylib          Mesa 25.0.7: softpipe + freedreno/MSM, OSMesa frontend
      freedreno drm layer      patched Mesa src/freedreno/drm
        libdrm stand-in        tools/mesa/hakios-drm/hakios.drm.c
          IOConnectCallStructMethod(HakiosGPUUserClient, selector, ...)
            iokit/Kernel/hakios.gpu.cpp
              bsd/dev/hakios.adreno.c -> Adreno 650 ring/GMU/SMMU
```

* Mesa is cross-built for iOS 16.5 by `tools/mk-mesa.sh` (Mesa **25.0.7**, sha256
  `592272df…0f8a6`, source `archive.mesa3d.org`) with the eight `tools/mesa/*.patch`
  files this port copies under `mesa/patches/`.
* `tools/mesa/hakios-drm/` **is libdrm** for this system. `xf86drm.h` declares the
  subset freedreno uses; `hakios.drm.c` implements it. The model is literal:
  * `drmOpenWithType("msm", …)` finds the IOKit service named `HakiosGPU`,
    `IOServiceOpen(service, task, 0, &conn)`; freedreno's `fd` is a meaningless
    `dup(open("/dev/null"))`, because there is one GPU connection per process.
  * `drmIoctl(fd, request, arg)` sends `request & 0xff` as the user-client selector,
    with the Linux request structure in and out (same buffer). `IOCPARM_LEN(request)`
    is the size.
  * `drmCommandWrite/WriteRead(fd, index, …)` sends `0x40 + index`.
  * `drmGetVersion()` lies in exactly one useful way: claims DRM **1.7**, name `msm`,
    description `Adreno on Darwin`. That version is chosen deliberately; see §3.2.
  * `drmGetCap()` always 0; `drmPrimeHandleToFD`/`drmSyncobj*` are `ENOSYS`.
  * Buffers are **not** mmap'd on a device: `hakios_drm_map()` is
    `IOConnectMapMemory64(conn, handle, …)`; the kernel's `clientMemoryForType(type)`
    returns buffer number `type`. `msm_gem_info(GET_OFFSET)` is a fake handle<<32,
    because nobody maps by offset.
  * `DRM_MSM_GEM_MADVISE` (0x48) is answered in userland with `retained = 1`; the
    kernel never takes a buffer back, and freedreno asks on every bindless
    descriptor/ring buffer.
  * An IOSurface enters as a **file descriptor whose value is the IOSurface ID**:
    `drmPrimeFDToHandle(fd, surface_id, &handle)` calls selector `0x7e`
    (`hakios_drm_surface`). `hakios_drm_surface(…DESCRIBE)` asks only the geometry.
  * `hkdrm=1` writes surface/handle traffic to `/var/tmp/hkdrm.log`.

### 1.2 Window-server path (EAGL over Mesa, about IOSurfaces)

`userland/src/eagl.c` (3 685 lines in `userland/src/`, 7 346 lines in the newer
K40 overlay) replaces a handful of `EAGLContext` methods so CoreAnimation's GL
renderer runs on OSMesa. Surfaces are still ordinary IOSurfaces:

* `-texImageIOSurface:…` and `-renderbufferStorage:fromDrawable:` create/import an
  IOSurface; `hakios_gl_surface_texture()` calls
  `glEGLImageTargetTexture2DOES(GL_TEXTURE_2D, (void *)IOSurfaceGetID(surface))`.
* Mesa's OSMesa frontend was patched (`freedreno-darwin.patch`) to implement
  `get_egl_image` / `validate_egl_image`; `osmesa_surface_resource()` describes the
  surface with selector `0x7e`, then `resource_from_handle()` turns the surface ID
  into a `drmPrimeFDToHandle` import. **The GPU draws directly into the IOSurface's
  pages** — no copy when the surface is GPU-addressable.
* Presentation is **not a DRM page flip**. An application's `CAEAGLLayer` gets
  `-[CALayer setContents: IOSurface]` on the main thread inside a CATransaction
  (`eagl.c`, `app_present`). The existing window server then reads that IOSurface and
  `MiniIOMobileFramebuffer` flips it. `HakiosGPU` has no atomic/page-flip ioctl and
  needs none.
* `gl_test` does **not** use this path: it renders to a Mesa texture, reads the pixels
  back with `glReadPixels`, and calls `kHakiosShow` (0x7f) to have the kernel copy
  them to the panel. That is a deliberately dumb test of "the GPU really drew",
  not the production presentation path.

### 1.3 Metal/AIR (not part of the GL transport; deferred)

`tools/mesa/metal/` + `tools/mesa/metal/*.patch` build `libhakios.air.dylib` and
`air_metal_test`; `tools/mesa/air/` is an AIR (LLVM bitcode) -> NIR frontend.
`userland/src/metal_test.m` proves where iOS's Metal lookup stops. This is a
different, much larger project (AIR reader + `_MTLDevice`/`IOGPU` graph + ABI) and
is **not** required for OpenGL ES. The reference itself does not use it for the
working GPU path. Not ported.

### 1.4 Ioctl/message map (Linux msm_drm.h numbers)

| sel | request | struct |
| --- | --- | --- |
| 0x09 | `DRM_IOCTL_GEM_CLOSE` | `{u32 handle, pad}` |
| 0x40 | `MSM_GET_PARAM` | `msm_param{pipe,param,u64 value,len,pad}` |
| 0x41 | `MSM_SET_PARAM` | `msm_param` (name/debug only) |
| 0x42 | `MSM_GEM_NEW` | `{u64 size,u32 flags,u32 handle}` |
| 0x43 | `MSM_GEM_INFO` | `{u32 handle,info,u64 value,len,pad}` |
| 0x44 | `MSM_GEM_CPU_PREP` | `{u32 handle,op,timespec}` |
| 0x45 | `MSM_GEM_CPU_FINI` | no-op |
| 0x46 | `MSM_GEM_SUBMIT` | bos/cmds arrays + fence |
| 0x47 | `MSM_WAIT_FENCE` | `{u32 fence,flags,timespec,u32 queueid}` |
| 0x48 | `MSM_GEM_MADVISE` | `{u32 handle,madv,u32 retained}` |
| 0x4a | `MSM_SUBMITQUEUE_NEW` | `{u32 flags,prio,id}` |
| 0x4b | `MSM_SUBMITQUEUE_CLOSE` | queue id |
| 0x4c | `MSM_SUBMITQUEUE_QUERY` | faults counter |
| 0x7e | **ours** `kHakiosSurface` | `hakios_surface` (IOSurface → buffer) |
| 0x7f | **ours** `kHakiosShow` | `hakios_show` (CPU pixels → panel; test only) |

`msm_gem_submit_cmd` requires `type == MSM_SUBMIT_CMD_BUF` and `nr_relocs == 0`
(softpin; our kernel rejects relocations, as intended).

## 2. Inventory: what is where, and what it costs

Copied verbatim from the reference (line/byte counts of the copies here):

| file | lines | bytes | role |
| --- | ---: | ---: | --- |
| `hakios-drm/hakios.drm.c` | 280 | 8 354 | libdrm stand-in over `HakiosGPU` |
| `hakios-drm/xf86drm.h` | 76 | 3 486 | the libdrm API freedreno sees |
| `userland/gl_test.c` | 367 | 16 073 | triangle → readback → panel (0x7f) |
| `userland/gl_osmesa.c` | 115 | 3 769 | EAGL↔OSMesa adapter (deferred build) |
| `userland/hakios.gl.h` | 33 | 1 641 | its interface |
| `userland/mkeagl.py` | 184 | 8 659 | generates `eagl.c`'s GL slot table |
| `userland/eagl_slots.txt` | 414 | 12 407 | EAGLContext dispatch offsets |

`mesa/patches/` (eight, all needed for the GL path):

| patch | bytes | what it does |
| --- | ---: | --- |
| `freedreno-darwin.patch` | 11 994 | meson uses `src/hakios-drm` as libdrm; `bo_map`→`IOConnectMapMemory`; IOSurface import; `CLOCK_MONOTONIC_RAW`; no sysinfo; no disk shader cache; OSMesa EGL-image hook; GPU screen selection; `osmesa_surface_resource()` |
| `freedreno-nomem.patch` | 3 771 | buffer refused → drop caches, retry 30 s; heap block NULL handled |
| `fd-gmem-zs-cpp.patch` | 1 538 | CCU/UCHE flush before a framebuffer-reading draw |
| `ir3-disk-cache-darwin.patch` | 1 311 | no build-id → no ir3 disk cache |
| `ir3-round-default.patch` | 6 646 | ir3 rounding default |
| `osmesa-es-profile.patch` | 1 320 | `OSMESA_ES_PROFILE` (ES 1/2/3 contexts) |
| `osmesa-hakios-copy.patch` | 2 050 | `OSMesaHakiosCopy()` GPU blit for CAEAGLLayer |
| `osmesa-import-keep.patch` | 3 813 | keep a surface import for 100 ms so re-import reuses the buffer |

**Deliberately not copied** (sizes from the same commit):

| source | size | why deferred |
| --- | ---: | --- |
| `userland/src/eagl.c` | 168 776 B / 3 685 lines (K40 overlay: 295 488 B / 7 346) | ObjC/EAGL window-server replacement; needs IOSurface, CA, the generated slot table; second milestone |
| `userland/src/alioth_metal.m`, `alioth_mps.m`, `alioth_drawable.m` | 497 KB + 27 KB + 31 KB | Metal/MPS object graph; Metal is out of scope |
| `tools/mesa/metal/`, `tools/mesa/air/` | ≈1.5 MB | AIR→NIR + `libhakios.air.dylib`; experimental, not GL |
| `tools/mesa/*.patch` air variants | 10 KB + 0.6 KB | only used by the Metal build |
| `userland/build.sh` (reference) | 46–68 KB | replaced by the small scripts here, not blindly copied |

## 3. Our kernel vs the reference: what is already there, what is missing

### 3.1 Provided by our `hakios.gpu.cpp` (verified by reading the ported file)

All of §1.4: 0x09, 0x40–0x48, 0x4a–0x4c, 0x7e, 0x7f. It also has:
`MSM_INFO_GET_OFFSET/GET_IOVA/GET_FLAGS/SET_NAME`, all `MSM_SUBMIT_BO_*`,
`GPU_SUBMIT_BOS=8192`, `GPU_SUBMIT_CMDS=128`, `MSM_SUBMIT_FENCE_FD_OUT`,
16 KB-page rounding, write-combined IOSurface memory, per-client GPU address space
(`gpu_spaces=1`), SMMU/GPU recovery, IRQ-driven waits (`gpu_irq=1`), the surface
push/seed logic, and the IOSurface→GPU-buffer cache (`b->surface` reuse) the
reference's newer K40 overlay also has.

The service is `HakiosGPU : IOService`, `kIOUserClientClassKey =
"HakiosGPUUserClient"`, registered only when `hakios_gpu_ready()` (i.e.
`adreno_keep=1` and the GPU ladder reached the end). **Open type is 0**, as the
kernel logs: `HakiosGPU: … open it with type 0`. (The handoff's "open type 8" is
not used by the DRM client; `IOServiceOpen` with 0 is what both the reference and
this port do.)

### 3.2 Is anything missing for Mesa 25.0.7?

**No, not for the msm/freedreno path.** `drmGetVersion` advertises minor **7**.
Mesa 25.0.7 gates features on these minors (`freedreno_drmif.h`):

```
GMEM_BASE=3  SUBMIT_QUEUES=3  SOFTPIN=4  SUSPENDS=7  CACHED_COHERENT=8  VA_SIZE=9
```

At 7, Mesa uses submit queues, softpin, GMEM base and suspend detection; it does
**not** probe `MSM_PARAM_VA_SIZE` (9) or `MSM_BO_CACHED_COHERENT` (8). Our
`hakios_gpu_parameter()` answers GPU_ID/GMEM_SIZE/CHIP_ID/MAX_FREQ/TIMESTAMP/
PRIORITIES/GMEM_BASE/HIGHEST_BANK_BIT/UBWC_SWIZZLE/MACROTILE_MODE and returns
false for VA_START/VA_SIZE, deliberately: addresses are the kernel's to choose.
`CHIP_ID` is non-zero (Redwood `0x06030500`, UMI `0x06050002`), so
`msm_pipe_new()` accepts the pipe. `GPU_ID` may be 0; that is allowed when
`CHIP_ID` is set.

The only requests our kernel does **not** implement are ones this transport never
issues: dma-buf (`drmPrimeHandleToFD`), syncobj/timeline, `VA_START/VA_SIZE`,
cached-coherent allocations, and DRM mode/atomic/page-flip. Presentation is
IOSurface→window-server, not DRM.

### 3.3 Genuinely missing (on both sides)

| missing | side | consequence |
| --- | --- | --- |
| `MetalPluginName` / `MetalPluginClassName` on an `IOAcceleratorES`, plus a `HakiosMetal.bundle` | kernel | Metal stays nil. Intentional; the reference leaves it nil too. OpenGL ES does not care. |
| `eagl.c`, `ca_probe.c`, `libhakios.gl.dylib` | userland | no window-server/CoreAnimation acceleration yet; only the `gl_test`/OSMesa path is ported. |
| AIR→NIR frontend | userland | no Metal shader support. Out of scope. |
| runtime proof that our MiniIOSurface/SweetSurface accepts a *SpringBoard* surface through 0x7e | both | the kernel code exists; it has not been exercised by this userland port. `gl_test` exercises GEM + submit + 0x7f, not the IOSurface path. |
| a Mac/iOS SDK on this Linux box | build | `build-mesa.sh`/`build.sh` are written but cannot run here. |

## 4. Ordered plan

**M0 (first on-screen milestone, everything here except Mesa is ready).**
1. On macOS: `IOS_SDK=…/iPhoneOS16.5.sdk ./hakios-port-userland/build-mesa.sh`.
2. `./build.sh` → `out/gl_test`.
3. Install `libOSMesa.8.dylib` + `gl_test` in the root (or SWEETBOX, see
   `TESTING.md`), boot the combined image with `gpu=1 adreno_keep=1 gpu_irq=1
   usb=2`, run `/usr/local/bin/gl_test 8`.
4. Success = `gl_test` prints a non-softpipe renderer, a non-zero draw time, and
   the pixel readback; the panel shows the triangle; the kernel log has
   `HakiosGPU: submission N: … command buffers`, `HakiosGPU: N submissions in …`,
   and `adreno:`/`HakiosGPU: service published`.

**M1 (window server).** Port `eagl.c` + `ca_probe.c` (and `mkeagl.py` already
here), build `libhakios.gl.dylib`, install it under the name CoreAnimation
loads, verify `hakios-gl:` lines and a CoreAnimation frame drawn into an
IOSurface (0x7e reuse should show `surfaces`/`given_again` in the kernel stats).
This is the milestone that proves the real presentation path.

**M2 (applications).** The `app_*` half of `eagl.c` (CAEAGLLayer → IOSurface
ring, `OSMesaHakiosCopy`), then a stock GL app.

**M3 (optional).** AIR/Metal only if wanted; a separate project.

## 5. What was ported vs deferred, and what was checked here

Ported: the full DRM/libdrm client, the eight Mesa patches, the pinned Mesa
build recipe, `gl_test`, the small EAGL/OSMesa adapter sources and generator,
build/install/CI scripts and the launchd job.

Deferred: `eagl.c` and the CA window-server library, Metal/AIR, and the reference's
large `build.sh` (replaced by focused scripts).

Checks actually run on this Linux host (clang 23, no iOS SDK):

* `clang -fsyntax-only -Wall -Wextra` on `hakios-drm/hakios.drm.c`,
  `userland/gl_test.c`, `userland/gl_osmesa.c`, using the declarations-only stubs
  in `check-shims/`. **DRM and OSMesa adapter: clean. gl_test: clean except four
  `%llu`/`uint64_t` format warnings that are Linux-only** (`uint64_t` is
  `unsigned long` here, `unsigned long long` on Darwin; the source's format is
  right for the target). Reproduce with `./check-host.sh`.
* `bash -n` on every script; `python3 -m py_compile userland/mkeagl.py`;
  `git apply --check` of `userland.yml.patch` against the real `userland.yml`.
* Downloaded `mesa-25.0.7.tar.xz` from `archive.mesa3d.org`, verified the pinned
  sha256, extracted it, and applied the eight `mesa/patches/*.patch` **in the
  script's order: all eight apply cleanly** (`patch -p1`, no fuzz).
* **Not run:** any real iOS compile or link, Mesa configure/ninja, `ldid`, or a
  boot. Those need macOS + the iPhoneOS16.5 SDK; `build-mesa.sh` states the exact
  commands.

## 6. Build recipe and CI

`build-mesa.sh` mirrors the reference's `tools/mk-mesa.sh` with the AIR step
removed: Mesa 25.0.7, the eight patches, `src/hakios-drm`, cross file
`arm64-apple-ios`, `-Dgallium-drivers=softpipe,freedreno -Dfreedreno-kmds=msm
-Dosmesa=true -Dllvm=disabled -Degl=disabled -Dgbm=disabled -Dvulkan-drivers=`.
Output install name defaults to `/var/local/lib/libOSMesa.8.dylib` (SWEETBOX's
allowlist accepts `var/local/lib/`; override with `INSTALL_LIBDIR=/usr/local/lib`).

`build-userland-gpu.sh` is the CI entry point; `userland.yml.patch` adds exactly
one dependency step and one build step to `.github/workflows/userland.yml`,
leaving the existing usbsh/usbmux and sweet-autorun steps untouched. It copies
`gl_test`, `libOSMesa.8.dylib` and `exported-gl.txt` into the existing
`artifacts/` upload.

## 7. End-to-end test

See `TESTING.md`: combined-image boot arguments, root-image and SWEETBOX install,
how to run `gl_test`, and the exact kernel/USB-console lines that prove a client
submitted work and the GPU drew/presented it.
