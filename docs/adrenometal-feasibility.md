# AdrenoMetal on alioth: feasibility

Status: **research only**. Read `UniXNU/AdrenoMetal@85832c3` (2026-11-28),
`FFT-infra/AdrenoMetal` (`fft`, 2026-11-09), `FFT-infra/Adreno650`
(2026-11-20), `FFT-infra/UniXNU-alioth` (2026-11-21) and `NWylynko/ios-flame`
(iOS 16.7.16, Adreno 640). Nothing was built, flashed or run.

**Verdict: AFTER THE GL PATH, and not as a drop-in.** AdrenoMetal is a userland
Metal device, not a kernel driver, and it does not speak our `HakiosGPU` ABI.
The stack it belongs to has drawn the SpringBoard UI twice: on Adreno 650 with
iPadOS 17.7.11 (FFT's fork), and on iOS 16.7.16 with Adreno 640 (ios-flame's
older fork of the same frontend). Nobody has published A650 + iOS 16.7.16 +
AdrenoMetal, and upstream supports neither the A650 nor iOS 16. Our submit path
must be stable before any of it is worth starting, so GL comes first.

## 1. What the repository actually is

AdrenoMetal is the **Metal frontend and bundle**, reached the way Apple's own
accelerator is: `IOServiceMatching("IOAcceleratorES")` → `MetalPluginName` →
`NSBundle` at `/System/Library/Extensions/<name>.bundle` → principal class →
`-initWithAcceleratorPort:` (`NativeAdrenoMetalPlugin.mm:1-8`). In "published"
mode (a `NativeAdrenoMetal.publish` marker file beside the bundle) `backboardd`
gets the native device, the CARenderServer composites the system UI through it,
and every other Metal process gets its own device, driver connection and shader
cache.

It is **not**: a kernel `IOAcceleratorES` provider (the repo only carries ABI
probes and an offline test provider: `OriginalAcceleratorABI.h`,
`NativeIOGPUProviderProbe.cpp`, `NativeOfflineAccelerator.cpp`); an `IOGPU`
reimplementation or an AGX command-stream translator (there is no PM4/AGX
decoder); or a GPU driver — the kernel side lives in `Adreno740` and FFT's
`Adreno650` fork.

| Piece | Where | What it does |
| --- | --- | --- |
| Metal frontend | `NativeBridgeMetalFrontend.mm` | Dynamic `_MTLDevice` subclass plus `NBBuffer`/`NBTexture`/`NBQueue`/encoders; answers the Metal API |
| AIR translator | `metal2vulkan` fork | Metal IR (AIR) → SPIR-V; full Metal object model on Vulkan |
| Vulkan driver | Mesa Turnip, `tu_knl_darwin.cc` | SPIR-V → NIR → IR3; submits through the Darwin kernel ABI |
| Kernel driver | **not in this repo** | NativeAdreno ABI v2: BOs, per-client queues/VA, fences, device info |
| Display hand-off | `GpuScanoutClient.h`, `GpuScanoutPresenter.h` | GPU blit/compute of the compositor IOSurface into the firmware framebuffer; optional (`fb-gpu=1`) |
| Shader cache | `PrimeShaders.h`, `ShaderCache/` | On-device priming and a persistent cache keyed by translator/Turnip build |

The command stream is **not AGX-specific**: AIR is device-independent and
Turnip emits Adreno IR3. What is AGX-shaped is the discovery and sandbox
surface: the `IOAcceleratorES`/`AGXAccelerator` class names, the
`AGXDeviceUserClient` connection name, open type `0x4147` (`'AG'`), the
`IOGPUFamily` base class, and the iPadOS 27 QuartzCore address fix-ups.

## 2. Requirements, as the code states them

| Requirement | Detail | alioth today |
| --- | --- | --- |
| Kernel accelerator service | Class matching `IOAcceleratorES`, property `MetalPluginName`; `AGXAccelerator`-style subclass | **missing**: `HakiosGPU` is a plain `IOService` with msm-DRM selectors |
| Kernel user client | NativeAdreno ABI: BO alloc/import/map/free, submit 16 IBs, wait fence, queues, device info; open `0x4147` | **missing**; our ABI is `kMsmGemNew`/`Submit`/`WaitFence` |
| Base class | Apple `IOAcceleratorES` (136 bytes on the iOS 17 base) or audited symbol aliases; FFT binds three addresses in a prelinked `IOGPUFamily` | **missing**; ios-flame's 57-line `IOService` stub is enough |
| GPU KMD | A6xx/A7xx init, SMMU, CP ring, GMU, fences, scanout | **partly**: A650 init/ring exist; submit still fails at 256 dwords |
| OS ABI | Upstream targets iOS/iPadOS **27** and macOS 27; FFT targets iPadOS **17.7.11**; no iOS 16 path | ours is **16.7.16 (20H392)** |
| Trust / install | Bundle in the extensions union view, trust-cache entry or permissive AMFI; FFT uses a three-module trust bundle and addon | our AMFI grants platform binaries; signing/trust unproven |
| GPU generation | Upstream: A740 only. A650 only in FFT's fork (11 branch points: A6xx interrupt mask, ring `NO_UPDATE`, `a6xx_submit` prologue, `CACHE_FLUSH_TS` fence, `CP_ME_INIT`) | A650, a6xx gen2 — the fork's target |

Maturity: 415 commits since 2026-10-20, five contributors, 34 stars, 26 forks,
MIT, no releases, no CI, no user issues (three open PRs). Docs match the source
but describe A740/iOS 27; building it needs Xcode, Rust 1.98 and Mesa/meson.

## 3. Evidence that it can draw the UI

**Upstream** (`README.md:29`): end-to-end macOS 27.3 rendering, live window
dragging and fault-free SMMU/GPU execution on `sheng` (A740). That is
WindowServer, not SpringBoard, and it is text, not a published capture.

**Adreno 650, iPadOS 17.7.11** (FFT, donor iPad7,1): `porting.toml` records
`GPUROW24 METAL ok`, 8 GPU clients including SpringBoard and the poster
extensions, `SUPER sw=8/8/0 own=1`, `PANEL nonblack=916/1000`, `WALLPAPER
stage=5`, and an owner-confirmed desktop
(`docs/evidence/2026-11-20-rename1-desktop.md`). Limits: widgets absent,
poster extensions abort-loop without the allow-list, no Wi-Fi, one round 3.5×
slower than the CPU copy path, and later summaries say SpringBoard can lose its
Metal device at the client IOVA window. The only public A650 evidence: partial
and fragile, not a shipping result.

**iOS 16.7.16, Adreno 640** (`ios-flame`, kernel 0124): its README claims
backboardd, SpringBoard and apps render through Metal on Turnip at 20–26 fps,
with a screenshot. Closest OS/ABI match, but it uses the older `phone/metal2`
frontend and ios-flame's own kernel patches (0096/0097, 0115), not current
AdrenoMetal.

**Where the evidence stops.** No A650 + iOS 16 result exists in either project;
no A650 screenshot or video is linked from AdrenoMetal itself. FFT's records
are serial-console counters plus an owner's visual confirmation, and its status
page still calls the accelerator "staged". Treat A650 + iOS 16 as unproven.

## 4. Applicability to alioth

What matches: A650 is a6xx gen2, which Turnip supports; FFT has done the A650
kernel branch points; `HakiosGPU` already has A650 power, GMU, SMMU context,
ring, BO allocation and IOSurface wrapping. The AppleCLCD CPU copy can stay —
AdrenoMetal's GPU scan-out is optional and ios-flame reached the UI without it.

What does not match:

1. **Kernel ABI.** AdrenoMetal's Turnip backend opens `IOAcceleratorES` with
   type `0x4147` and speaks the NativeAdreno struct ABI. `HakiosGPU` speaks
   msm-DRM ioctls; the plugin cannot open, map or submit through it.
2. **OS ABI.** The plugin's shims target iPadOS 17.7.11 (`_MTLDevice` 536
   bytes, no arm64e block) and iPadOS 27 (arm64e; QuartzCore addresses
   `0x18446…`, `0x1e70…`). iOS 16.7.16 differs in QuartzCore/Metal private SPI;
   ios-flame's frontend is a separate, older port.
3. **Discovery.** Our XNU has no `IOAcceleratorES` at all. It is cheap to add
   (0096 is 57 lines, an `IOService` subclass), but alone it only makes
   `backboardd` load the bundle and get `nil` — the stage-1 self-test path.

Three ways to relate it to `HakiosGPU`:

* **A — replace the KMD.** Adopt FFT's `Adreno650` driver and AdrenoMetal fork,
  and rebase to iPadOS 17.7.11. Best-evidenced A650 route, but it replaces the
  working driver, imports FFT's init/pkd/LaunchServices repairs, and discards
  the iOS 16 work.
* **B — put a facade over `HakiosGPU`.** Add `IOAcceleratorES` +
  `MetalPluginName` and a NativeAdreno v1 user client translating BO
  alloc/import/map, multi-IB submit, fence wait and device info onto
  `hakios_gpu_*`. ios-flame's `0115-flame-gpu-v2-client-turnip.patch` is a
  ~1,000-line worked example (A640 chip ID, one ring, per-client VA window, 16
  IBs, `clientMemoryForType`); then build its iOS 16 Turnip/frontend, or
  backport AdrenoMetal's newer frontend. Keeps our OS and driver, but is still a
  substantial kernel + userland port.
* **C — upstream drop-in.** Not possible: no KMD, no ABI, no iOS 16 shims. A
  discovery stub alone changes no pixels.

## 5. Integration plan sketch (only after the GL path is stable)

**Phase 0 — finish the submit path (no Metal).** Fix the CP stop at 256 dwords
and the later fence timeouts in `hakios.adreno.c`/`HakiosGPU`; Metal and GL ride
the same ring. ios-flame's 0115 `a6xx_submit` wrapper (CCU invalidate, per-IB
`CP_INDIRECT_BUFFER`, `CACHE_FLUSH_TS` fence) is a reference, not a proven fix.

**Phase 1 — offline build.** Build the pinned `metal2vulkan` bridge and Turnip
Darwin for iOS 16, run the frontend host checks, translate the iOS 16
QuartzCore `.metallib` offline. Gate: every CA kernel translates; no writes.

**Phase 2 — discovery only.** Add the 57-line `IOAcceleratorES` stub, publish
`MetalPluginName`, install the bundle in the extensions union view. Gate:
`backboardd` loads it, `initWithAcceleratorPort:` runs, returns `nil`, UI
unchanged. Boot-arg gated and removable.

**Phase 3 — one device, one process.** Implement the NativeAdreno v1 facade
(BO alloc/import/map, submit 16 IBs, fence, A650 GMEM/UBWC info) and run the
plugin's known-image self-test in a non-UI process. Gate: correct pixels, no
GPU hang, clean close.

**Phase 4 — backboardd.** Give the render server the device and let
CoreAnimation composite; keep the AppleCLCD CPU copy. Gate: SpringBoard home
screen and Settings stable, no DeviceLost, cadence measured against the CPU.

**Phase 5 — optional GPU scan-out and posters.** Only after Phase 4 is stable;
this is where FFT's allow-list, IOVA-window and poster-abort problems live.

## 6. Risks

* **Kernel ABI fragility.** NativeAdreno records, per-client VA windows and
  open-type filtering are a new user-client surface; a bad pointer or IOVA is a
  panic, not an error. Our driver also reports a hung GPU and stays stopped;
  FFT has hang/restart work we do not.
* **OS drift.** The plugin's private Metal/QuartzCore shims are version
  specific; iOS 16.7.16 support is a backport, not a flag.
* **Memory and clients.** FFT measured SpringBoard near 1.7 GiB of GPU IOVA and
  posters hitting the 8-open cap; a naive aperture refuses clients or exhausts
  the pool. The bundle + Turnip + Rust bridge also need trust and sandbox
  admission.
* **Licensing and cost.** AdrenoMetal is MIT, `metal2vulkan` GPL-2.0+ OR
  LGPL-3.0, Turnip MIT; a static plugin is GPL-2.0+ in practice. This is a
  kernel-ABI port plus a userland build plus an OS-ABI backport.

## 7. Recommendation: AFTER THE GL PATH

Do not start AdrenoMetal now. Finish the GL/submit bring-up first; it is the
prerequisite for every Metal phase and the cheapest place to find the remaining
CP/cache bugs. Then, if the goal is GPU-composited SpringBoard on iOS 16,
pursue **option B**: an `IOAcceleratorES` + NativeAdreno-v1 facade over
`HakiosGPU`, with ios-flame's iOS 16 Turnip/frontend as the base and
AdrenoMetal's newer frontend as the upstream to backport. If rebasing the image
to iPadOS 17.7.11 becomes acceptable, **option A** (FFT's A650 + AdrenoMetal)
is the best-evidenced route. Do not attempt upstream AdrenoMetal as-is on iOS
16.7.16 / `HakiosGPU`: no iOS 16 support, no A650 support, no driver to open.

## 8. Sources

* <https://github.com/UniXNU/AdrenoMetal> — README, AGENTS, plugin and ABI
  headers, `GpuScanout*`, commits to `85832c3`; plus the `adreno-metal` and
  `adreno740` pages on unixnu.com for interfaces and validation claims.
* <https://github.com/FFT-infra/UniXNU-alioth> — `porting.toml` GPU section;
  evidence `2026-11-20-rename1-desktop.md`,
  `2026-10-30-gpu-client-windows-and-wallpaper.md`,
  `2026-11-06-gpu-handoff-presents-but-slower.md`; `board.toml`;
  `scripts/build-adreno650.py`. <https://github.com/FFT-infra/Adreno650> —
  `NativeAdrenoAccelerator.cpp`, `NativeAdrenoPublish.cpp`, `NativeAdrenoABI.h`.
* <https://github.com/NWylynko/ios-flame> — README, `METAL-NEXT.md`, patches
  `0096`, `0097`, `0115`, `phone/metal2/`, `phone/turnip/NativeAdrenoABI.h`.
* Local: `hakios.gpu.cpp`, `hakios.adreno.c`, `NOTES.md` 2026-11-27/28 (submit
  path), `docs/splitboot-feasibility.md` (style and evidence rules).
