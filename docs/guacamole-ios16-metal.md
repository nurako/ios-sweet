# ios-guacamole `ios16`: Metal on Adreno 640 and what transfers to alioth

Status: **research only** (2026-11-28). Read [`coreycusick/ios-guacamole`](https://github.com/coreycusick/ios-guacamole)
branch `ios16`, commit `29e3cf3` (2026-11-20; status snapshot 2026-11-10; README says
"RETIRED TO FOCUS ON IOS 27.2"). Nothing was built, installed or run. Paths below are
relative to that branch unless prefixed `our:`. The earlier iOS 27 reading is
`research/guacamole-ios27.md` on branch `docs/guacamole-research`.

**Verdict: it is a real, device-tested Metal compositor on iOS 16 — as a bundle over
metal2vulkan + Turnip and a NativeAdreno-v1 *facade* over the existing msm-style GPU
core, not an AGX driver.** It supplies the exact pieces
`our:docs/adrenometal-feasibility.md` listed as missing for iOS 16: an `IOAcceleratorES`
discovery service, `MetalPluginName` properties, a NativeAdreno user client, and an
iOS 16.7.16 frontend bundle. It is still **A640-only** and the facade is written against
their `redwood_gpu_*` KPI, not our `hakios_gpu_*`. **It does not change the ordering:
finish the GL/submit path first.** It does turn the Metal step from research into a
known port.

## 1. What "Metal acceleration" means on this branch

`README.md:28` states it plainly:
> `OpenGL ES: Mesa 25.0.7 freedreno behind iOS's EAGLContext; CoreAnimation in backboardd
> renders on the GPU. Metal: SweetMetal2 (metal2vulkan + Turnip) for backboardd, WebKit and
> selected apps (/var/local/mtl2-clients)`

So there are two GPU paths, and "Metal acceleration" is the second: GL composites
CoreAnimation in `backboardd` through freedreno/`EAGLContext`; Metal replaces that with
SweetMetal2 for the processes listed in `/var/local/mtl2-clients` (currently `backboardd`,
WebKit GPU/WebContent, Telegram and the tests).

The decisive log line is `NOTES.md:2223`:

> `backboardd composes with Metal, NOT libsweet-gl: 0195's eagl.c log lines never print
> (harmless).`

This is **not** an AGX/IOGPU driver, PM4/AGX translator or GPU scan-out. The display is
still an `AppleCLCD`/IOMobileFramebuffer service copying CoreAnimation's IOSurfaces to the
panel; 0149/0150 optionally do that copy with a `CP_BLIT`. Pixels reach the panel through
the same class of path we already have.

## 2. Architecture

```
Metal.framework (per process)
  └─ CAMetalContextCreate polls IOServiceMatching("IOAcceleratorES")
       └─ IOAcceleratorES (SweetFramebuffer.cpp, child of AppleCLCD, name "sgx")
            MetalPluginName     = "SweetMetal2"
            MetalPluginClassName= "SweetMTL2Device"
            kIOUserClientClass  = "SweetAcceleratorUserClient"
            + boot arg sweetmtl=2 selects this instead of the empty stub
  └─ Metal loads /System/Library/Extensions/SweetMetal2.bundle
       NSPrincipalClass = SweetMTL2Device
       -initWithAcceleratorPort: -> UniXNU's NativeBridgeMetalFrontend.mm (2,909 lines)
         └─ libnative_metal_bridge.a (Rust ABI over metal2vulkan; Metal AIR -> SPIR-V)
              └─ libvulkan_freedreno.dylib (Mesa Turnip, tu_knl_darwin.cc)
                   └─ SweetAcceleratorUserClient (IOKit)
                        └─ RedwoodGPU / bsd/dev/sweet_gpu.c (msm-style ring, GMU, SMMU)
```

Key source facts:

* **Discovery is a stub, not a driver.** Patch `0088` adds a 3-line `IOAcceleratorES :
  IOService` class and publishes it from `AppleCLCD::start`, because QuartzCore polls the
  class name 300 × 100 ms and otherwise stalls 30 s per process. One **without** plugin
  properties "is found and then passed over by Metal (MTLRegisterDevices)", so the stub
  alone changes no pixels.
* **The facade is a separate user client.** Patch `0144` sets the properties and
  `kIOUserClientClassKey = "SweetAcceleratorUserClient"` on that stub. The client is 609
  lines of **NativeAdreno ABI v1** (`SweetGPUABI.h`): BO alloc/map/free/import, 16 IBs per
  submit, fence wait, queues, device info; open type `0x4147` (`'AG'`) or `2`; a tunnelled
  `{'NTNL', method, payload}` form through selector 0.
* **Memory model.** `BoAlloc` takes 64 KB chunks from a GPU pool in RAM XNU does not
  manage (write-combined CPU, non-cacheable GPU); `BoImport` pins the caller's IOSurface
  pages and the client does its own cache maintenance. Each connection gets a GPU-VA
  window (512 MB system, 256 MB otherwise; 64 GB after `0148`).
* **Submit and display.** `Submit` wraps the IBs with an `a6xx_submit`-style prologue and
  a CP timestamp fence; `sweet_gpu_submit_v2(iova[], dwords[], n)` has the shape of our
  `hakios_gpu_submit(addresses, words, count)`. 0145 holds the panel swap until the GPU's
  last submit (max six vsyncs), so half-drawn CA frames are not shown.

## 3. Versions, device support and evidence

| Item | Value |
| --- | --- |
| OS / kernel | iOS **16.7.16 (20H392)**, **iPhone X (D22)** userland; XNU **8796** built from Apple source + SWEET patches 0001-0266 |
| Device | OnePlus 7 Pro (`guacamole`), **SM8150**, 8 GB, UFS 3.0, 1440×3120 |
| GPU | **Adreno 640**, a6xx, KGSL/msm-family core in `bsd/dev/sweet_gpu.c` |
| Metal stack | SweetMetal2: UniXNU frontend + metal2vulkan `720ef1ce` + Mesa `85fda3b3` Turnip/darwin |
| Bundle | `-mios-version-min=16.0`, arm64, iOS 16 SDK, ad-hoc signed, in `/System/Library/Extensions/SweetMetal2.bundle` |
| Branch | Metal work 2026-11-06..11-11; retired 2026-11-12; license commit 2026-11-20 |

What is demonstrated (owner reports + on-device logs, no CI for userland):

* SpringBoard/lock screen, Settings, Photos, Wallet, Safari pages, stock apps; landscape
  games (Subway Surfers, Angry Birds 2) render through Metal; WebKit pages drawn in
  WebContent.
* `mtltest` PASSes device creation, blit fill, `newLibraryWithSource`, compute pipeline
  and a 4096-element compute (0 wrong words); `surftest`/`cgtest` cover IOSurface textures
  and `CGIOSurfaceContext` against the CPU (`NOTES.md:2880-2885`).
* Frame rate in swipes rose **25 → 37-44 fps** after 0149-0156; GPU 55-82% busy at
  585 MHz; game stretches at ~60 fps (`docs/guacamole.md:230-246`).
* Maturity limits: `backboardd` can lose its Turnip device (`DeviceLost`) under ring
  pressure; a looping shader in Subway Surfers' daily wheel freezes the GPU until 0238's
  reset/recovery; posters/compute are partial; GLES-only games (Angry Birds Classic) crash
  because `libsweet-gl` is window-server-only. README calls the port "experimental, not a
  usable phone OS". **No screenshot, video or CI exists**; evidence is owner reports plus
  `dmesg`/`mtl2.log` counters — strong engineering evidence, not a reproducible benchmark.

## 4. Comparison with `docs/adrenometal-feasibility.md`

| Requirement there | This branch |
| --- | --- |
| Kernel service matching `IOAcceleratorES` with `MetalPluginName` | **provided** (0088, 0144/0145); plain `IOService` child of AppleCLCD |
| NativeAdreno user client (BOs, 16 IBs, fences, device info, open `0x4147`) | **provided** (0144, 609 lines, ABI v1) |
| Base class / prelinked IOGPUFamily bind | **not needed**: the stub is a plain `IOService`; Metal only reads properties and opens the named user client |
| iOS 16 OS ABI | **provided**: built with the iOS 16 SDK against iOS 16.7.16 QuartzCore/Metal private SPI |
| GPU / KMD | **Adreno 640**, a6xx, KGSL/msm-family core in `bsd/dev/sweet_gpu.c` / RedwoodGPU — not AdrenoMetal's NativeAdreno v2 |

So this is the same lineage as `NWylynko/ios-flame` (our doc's iOS 16 reference), one
generation later and much better documented: a 2,909-line frontend instead of ios-flame's
older `phone/metal2`, plus the facade source and exact build scripts. It is **not**
upstream AdrenoMetal's newer frontend and does not make that work on iOS 16. It closes the
"no iOS 16 `IOAcceleratorES`/frontend implementation to copy" gap, not the "no A650" gap.

## 5. Transferability to alioth

### Adopt nearly as-is (userland, OS-version-compatible)

| Item | Why |
| --- | --- |
| `userland/metal2/{SweetMetal2.mm,NativeBridgeMetalFrontend.mm,Info.plist,build.sh,test/}` | The complete iOS 16 bundle; device-agnostic apart from reported name and a few a6xx limits |
| `userland/metal2/bridge/` + `tools/build-m2v-bridge.sh` | Thin Rust ABI + metal2vulkan pin `720ef1ce` and patches; builds a static iOS arm64 lib |
| `userland/turnip/NativeAdrenoABI.h`, `userland/turnip/patches/`, `tools/build-turnip-ios.sh` | Mesa `85fda3b3` + UniXNU darwin backend; Turnip already knows a650 |
| `userland/turnip/v2test.cpp` | Small, dependency-free ABI smoke test — port this first |
| `xnu/patches/0088`, `0144` (`SweetAccelerator.cpp`, `SweetGPUABI.h`), `0145` | The discovery stub, facade skeleton and present-fence fix |

### Must be adapted (alioth)

1. **KPI names and semantics.** 0144 calls `redwood_gpu_ready/address/parameter`,
   `sweet_gpu_pool_alloc`, `sweet_gpu_window_alloc/map_at/unmap_at`, `sweet_gpu_submit_v2`,
   `sweet_gpu_wait_fence_ns`, `sweet_gpu_timestamp`. Ours are `hakios_gpu_ready`,
   `hakios_gpu_address(_free)`, `hakios_gpu_map(_in)`, `hakios_gpu_submit(_in)`,
   `hakios_gpu_done`, `hakios_gpu_last`. We already have per-client spaces
   (`gpu_spaces=1`, `hakios_gpu_space_new/map_in/submit_in`), the same concept as their
   windows.
2. **BO allocation.** Their pool is RAM XNU never maps, because a write-combined alias of
   a cacheable physmap page loses data on A640. Either provide the same uncached pool or
   prove our GEM/`clientMemoryForType` mappings are WC/non-cacheable on A650; measure with
   `v2test`, do not assume.
3. **Device info is A640.** 0144 reports `chip_id = 0x06040001`, GMEM 1 MiB at
   `0x100000`, `highest_bank_bit = 15`, `ubwc_swizzle = 6`, UBWC v3. A650's chip ID, GMEM
   size/base, bank bit and UBWC version must come from our `hakios.adreno.c`; Turnip keys
   its a6xx generation off these.
4. **VA aperture.** Their 64 GB (0148) fixed backboardd exhausting 512 MB while importing
   app layers. Our aperture is roughly `0x01100000-0xf0000000` (~3.7 GB): enough for a
   SpringBoard-only phase, possibly not for a Telegram-like app.
5. **Frequency/power.** 585 MHz, DDR/SH0 BCM votes and the +2 GB pool are SM8150 tables;
   alioth's A650 OPPs/GMU are already in our driver — reuse ours.
6. **Present.** 0145's `redwood_gpu_last()` is `hakios_gpu_last()`; our
   `MiniIOMobileFramebuffer` can hold the copy until `hakios_gpu_done(fence)`. 0149's
   `CP_BLIT` present is optional and needs a650 re-derivation.

### Not transferable

A640 GPU init/zap/GMU/SQE sequences, their physical pool ranges and highmem layout,
display timing (1125×2436 → 1440×3120), 585 MHz bins, and the `sweetgpu=11` stage machine.
Those are `sweet_gpu.c` board code, not the Metal design.

### The real precondition

Their Metal path rides the same ring as GL. It only became usable after 0174 (wait for
ring space instead of refusing), 0238 (hang reset/recovery) and 0145 (present after the
GPU's fence). Our driver still stops at the first 256-dword IB and has no equivalent
hang recovery. Porting the facade before that would give us a second client on a broken
submit path.

## 6. Integration sketch for alioth

**Phase 0 — GL/submit (unchanged, blocking).** Fix the 256-dword CP stop, fence timeouts
and cache maintenance; add reset/recovery at least as good as 0238. Gate: a >256-dword IB
and a multi-IB submit complete, and a stuck shader does not need a reboot.

**Phase 1 — offline userland build (safe in parallel).** Fetch Mesa `85fda3b3`, UniXNU's 8
patches and metal2vulkan `720ef1ce`; build Turnip-darwin, the bridge and the bundle with
the iOS 16 SDK. Run only `m2vtest`/host selftests. Gate: links, ad-hoc signs, `mtltest`
passes offline. No device writes.

**Phase 2 — discovery only.** Port 0088 (~30 lines): an `IOAcceleratorES` child of our
framebuffer with no plugin properties. Gate: `backboardd` stops its 30 s poll, UI
unchanged, boot-arg removable.

**Phase 3 — NativeAdreno facade + `v2test`.** Port `SweetGPUABI.h` and the 609-line user
client to `hakios_gpu_*`; accept type `0x4147`; WC/non-cacheable BO pool; A650 device info;
per-connection VA window. Gate: `v2test` CPU write/read, `CP_MEM_WRITE` and imported-buffer
tests pass, no hang.

**Phase 4 — one Metal process.** Install the bundle with `MetalPluginName=SweetMetal2` /
`SweetMTL2Device`; run `mtltest` non-UI. Gate: correct pixels, clean close, no DeviceLost.

**Phase 5 — backboardd.** List only `backboardd` (and maybe `com.apple.WebKit.GPU`) in
`/var/local/mtl2-clients`; set the three `CAEnable*` prefs to NO; keep the CPU panel copy
and 0145's fence. Gate: home screen/Settings stable, cadence vs the GL path, no starvation.

**Phase 6 — optional.** `CP_BLIT` present, more clients, 2× rendering. Their
DeviceLost/IOVA-window/poster problems live here; do not start here.

## 7. Risks

* **Two clients, one ring.** backboardd + Turnip + our display can starve a 32 KB ring as
  theirs did; without ring waiting and recovery we get DeviceLost or a frozen phone.
* **Cache model.** A640 does not snoop; their `sys_dcache_flush` override and WC pool are
  load-bearing. Our GL path already shows cache-sensitive pixel corruption on a650;
  assume no coherence until tested.
* **Private SPI drift / trust.** The frontend is built for 16.0+ and tested on 16.7.16
  (our exact userland), but every shimmed Apple selector is a version bet. Ad-hoc bundle
  loading in the Extensions union view is unproven on our AMFI.
* **Licensing.** Frontend/bridge MIT, Turnip MIT, metal2vulkan GPL-2.0+ OR LGPL-3.0; a
  static bundle is GPL-2.0+ in practice. Keep sources/patches, not binaries, in git.
* **A650 unknowns.** Nobody has published A650 + iOS 16 + this stack; FFT's A650 is iPadOS
  17.7.11 and partial. Ours would be first — budget bring-up time.

## 8. Recommendation

**Keep "finish GL first, then Metal".** This branch does not change the ordering: Metal
uses the same CP ring and fences as GL, and its own history shows Metal only becoming
stable after the submit-ring, fence and hang-recovery fixes we have not finished. It
changes the *cost and uncertainty* of the Metal phase:

* the iOS 16 frontend, bundle layout, build scripts and NativeAdreno-v1 facade are now a
  concrete, device-tested reference, not a backport guess;
* our `hakios_gpu_*` KPI already has per-client spaces, map/unmap and multi-IB submit, so
  the facade is a translation port, not a new driver;
* the A640-specific parts are confined to device info, pool placement and power tables,
  which we replace with alioth's.

Do **not** adopt this branch's kernel tree, GPU bring-up or display code, and do not
expect A650 support to come from it. Safe parallel action: Phase 1 (offline build) while
Phase 0 is fixed; the next device-facing step remains the GL/submit path.

## 9. Sources

* <https://github.com/coreycusick/ios-guacamole> — branch `ios16`, commit `29e3cf3`:
  `README.md`, `docs/guacamole.md` (Metal 192-249), `NOTES.md` (Metal 2199-2909, 0238,
  0174), `xnu/patches/{0088,0144,0145,0148-0156,0238}`, `userland/{metal2,turnip}/`,
  `tools/build-{m2v-bridge,turnip-ios}.sh`.
* `our:docs/adrenometal-feasibility.md`; `our:research/guacamole-ios27.md` (branch
  `docs/guacamole-research`); `our:xnu/patches/0200-hakios-gpu.patch`;
  `our:hakios-port-gpu2/PORT-NOTES.md` (submit stop).
* Lineage: `NWylynko/ios-flame` (iOS 16, A640 SweetMetal2), `UniXNU/UniXNU` (Turnip
  darwin backend), `steelbrain/metal2vulkan`, Mesa freedreno/Turnip.
