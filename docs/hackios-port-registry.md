# hackios.appaiproxy.com (iOSOnAnd) — port registry survey

Status: **research only**, 2026-11-28. Site and linked repos read with `webfetch`/GitHub API;
no build, flash or device command. Page content was treated as untrusted data. Everything below
was checked against the linked repo where possible; "site says" means unverified.

Source: <https://hackios.appaiproxy.com/> · public JSON API: `/api/devices`, `/api/forks`,
`/api/status?device=<slug>`, `/api/openapi.json` · docs: `/docs`, `/docs/sources`, `/docs/api`.

## 1. What the site is

- A **registry with an API and a thin web UI**, not a wiki and not marketing. "iOSOnAnd tracks the
  ports that run iOS on Android phones" (`/docs`). The data model is device → area status (26 areas,
  3 OneiOS-only) → repo/lineage → media/source. Every status carries a detail string and a source URL.
- **Operator not disclosed.** No author, contact or org is published; the host is `appaiproxy.com`.
  The docs describe writes made by AI coding agents through a CLI/API, with repo owners claiming their
  entries via GitHub. Trust is per row, not per site.
- **Scale at read time:** 296 phones, 600 repos (77 "main", 523 forks/ports), 6 base projects,
  17 maintainers, 1,501 status changes in 7 days. Header says "18 with Metal"; the stats page says
  "63 GPU accelerated" — two different counters, neither defined. Treat counts as marketing-grade.
- **Provenance is graded in the row text:** `reddit claim (date)` (D), `HakiOS registry:` / `hackiosx.dev`
  (third-party claim), repo README (C), maintainer status with commit/log (B), committed artifacts (A).
  Sources are OneiOS docs, r/hackios, the HakiOS ports registry, hackiosx.dev, GitHub metadata.
- **Sibling registries it cites:** <https://hakios-developers.com/> (HakiOS ports/forks/roadmap, Telegram
  `@oosexgangdevs`), <https://unixnu.com/devices/...> (UniXNU per-device porting records, authoritative
  `porting.toml`), <https://hackiosx.dev/> (community explainer + "Open problems", no per-device data).

## 2. The six base projects

| Project | What it is | Reference device / OS | GPU route |
| --- | --- | --- | --- |
| **OneiOS** | Hosted XNU (`xnuhost`) beside One UI on a rooted Galaxy; app switches sessions | S24 Ultra, iOS 27.0.1 | Vulkan/Metal traces; not a bare-metal GPU port |
| **HackiOS** | Native XNU, own EFI loader + drivers, RAM boot; ath11k Wi-Fi on a LinuxKPI layer | POCO X5 Pro (SM7325), iOS 16.5 | Mesa freedreno (GLES); native Metal in progress |
| **ios-sweet** | Native XNU with a small iBoot-stand-in shim; drivers as kernel patches | Redmi Note 10 Pro (SM7150), iOS 16 | mostly CPU; some GPU forks |
| **UniXNU** | UEFI (Mu-Silicium) → DarwinBoot → XNU; one repo per driver/SoC/device | Pad 6S Pro (SM8550), iPadOS 17/26/27 | Adreno KMD + AdrenoMetal (metal2vulkan→Turnip) |
| **Open Mapple** | XNU on MediaTek, built like a ROM from a manifest; SplitBoot dual boot | realme 8i (MT6781), iOS 16.7.16 | mapple_gpu_mali / mapple_gpu_adreno |
| **Scion** | XNU on Exynos, one tree for xnu-8796 (iOS 16) and xnu-12377 (iOS 27) | Galaxy S9/Note9 (Exynos 9810), iOS 16.5 | Panfrost GLES |

## 3. Ports with material claims (claims vs evidence)

Evidence: **A** = artifacts committed (screenshots/logs/measurements), **B** = maintainer status with a
linked source/commit, **C** = README/registry claim, **D** = Reddit/social claim only.
The tracker's full list is 600 repos; this is all alioth/SM8250 and Adreno-6xx entries plus the
projects and ports whose claims bear on our gaps. The other ~560 are forks, duplicates or
unrelated devices; the API has them.

| Repo | Device (SoC) | OS | Claim on the site | Ev. |
| --- | --- | --- | --- | --- |
| `xiongnemo/hakios-alioth` | Redmi K40/POCO F3 (SM8250-AC, A650) | iOS 16.5 (20F66) | GLES UI + Metal for apps, 5 GHz Wi-Fi, BT + BT audio, audio, 4 camera sensors (one back camera per boot), sensors, modem/GPS, USB iPhone mode, 120 Hz | **A** |
| `FFT-infra/UniXNU-alioth` | alioth (SM8250-AC, A650) | iPadOS 17.7.11 | UFS root + launchd, touch, A650 Metal desktop + wallpaper; widgets missing, no Wi-Fi; SpringBoard can lose its Metal device | B |
| `MrMoxing/ios-alioth` | alioth (SM8250-AC) | iOS 16 | booted, video only, no feature list | D |
| `Ehgemus/UniXNU-apollo`, `aTechGeekDev/ios-apollo` | Mi 10T/10T Pro (SM8250) | iOS 16 | touch, GPU, Wi-Fi with internet, BT + BT audio, brightness, vibration, sleep; runs hot | D |
| `JopangJovan/hackios-xnu-kernel-umi` | Mi 10 (SM8250, A650) | — | HakiOS Mi 10 port; parent of xiongnemo's alioth port | C |
| `rui12366B/UniXNU-gts7xlwifi` | Tab S7+ Wi-Fi (SM8250-AB, A650) | iPadOS 17.7.11 | full UI via A650 KMD + AdrenoMetal, QCA6390 ath11k Wi-Fi, ADSP audio, UFS persistent Data, USB device mode | B |
| `kmu1757/UniXNU-t970` | Tab S7+ (SM8250-AB) | iPadOS 18.7 | personal research port, no recorded result | C |
| `nishant713/ios-pipa` | Pad 6 (SM8250-AC) | iPadOS 16 | touch, buttons, brightness, BT, Wi-Fi, partial GPU | D |
| `GFander/UniXNU-kebab` | OnePlus 8T (SM8250) | — | port by name; base for an OP8 5G UW boot with A650 GPU | D |
| `UniXNU/UniXNU-sheng` | Pad 6S Pro (SM8550, A740) | iPadOS 17/26/27 | native Metal driver composites the system UI through the A740 | B |
| `FFT-infra/Adreno650` (MIT) | A650 KMD fork of Adreno740 | — | A650 branch points; native XNU Adreno driver (README still says A740) | C |
| `UniXNU/AdrenoMetal` | A740 (A650 only in FFT fork) | iPadOS 27 | Metal frontend over metal2vulkan + Turnip; full UI on sheng | B |
| `RigoLigoRLC/unixnu-adreno6xx` | Tab S7 FE (SM7325, A642L) | iPadOS 17 (UniXNU) | A6xx startup, Turnip fill/compute/triangle with zero faults; 8-job ring, 500 ms timeout | B |
| `zzweiqing/UniXNU-nabu` | Pad 5 (SM8150, A640) | iPadOS 16 | interactive SpringBoard, A640 GPU composition via metal2vulkan + Turnip | B |
| `coreycusick/ios-guacamole` | OnePlus 7 Pro (SM8150, A640) | iOS 16 / 27.2 | iOS 16 GPU + BT audio; iOS 27.2 and macOS 27.2 boot | B |
| `NWylynko/ios-flame` | Pixel 4 (SM8150, A640) | iOS 16 | Metal via metal2vulkan/Turnip, Wi-Fi, SSH | C |
| `DenialOfGravity/ios-redfin` | Pixel 5 (SM7250, A620) | iOS 16.7.16 | native Metal, 90 Hz, Touch ID, Wi-Fi, camera, Venus video | B |
| `rafsanbasunia/ios-garnet` | POCO X6 (SM7435, A710) | iOS 16.5 | Metal, Wi-Fi, speakers, LTE data; BT without audio | D |
| `DC28088/ios-sweet` | Redmi Note 10 Pro (SM7150) | iOS 16 | Metal, Wi-Fi, BT, calls, sound; iOS 26.6.2 boots with touch | D |
| `andyleenz/pixel3-ios` | Pixel 3 (SDM845, A630) | iOS 16.7.16 | GPU UI near 60 fps, Wi-Fi, Safari | B |
| `HeliumStudio-Dev/hackios-xnu-kernel` | Redmi K20 Pro (SM8150, A640) | iOS 16.5 | GLES (no Metal), 5 GHz WPA3 Wi-Fi, Safari | C |
| `oosexgang/hakios-metal` | A6xx/A7c+ (chip 0x06030500) | iOS 16.5 | native Metal in C++ over the msm-DRM/HakiosGPU ABI, AIR→NIR→ir3, no Vulkan | C |
| `akshaynexus/iOSPlus10` | OnePlus 10 Pro (SM8450, A730) | iOS 16.7.16 | Metal2Vulkan GPU, Wi-Fi, BT, audio, haptics; camera broken | B |
| `akshaynexus/OneiOS` | S24 Ultra (SM8650, A750) | iOS 27.0.1 | hosted SpringBoard sessions with return to One UI | B |
| `jesvi-eulah/Jesvi-iOS` | Galaxy S20 (Exynos 990) | iOS 16.5 | Wi-Fi, LTE/VoLTE, BT, cameras, GPS, sensors, Metal GPU | D |
| `open-mapple/xnu_device_realme_spaced` | realme 8i (MT6781, Mali-G57) | iOS 16.7.16 | Wi-Fi, haptics, Files, video, torch; GPU/display partial; SplitBoot | B |
| `PixOS-Project/pixelios-kernel` | Pixel 6a (Tensor G1) | iOS 16.7.16 | GPU ~50 fps, Wi-Fi with internet, BT pairing; no audio/camera/cellular | D |
| `mateusseiboth/darwin-lisa` | Mi 11 Lite 5G NE (SM7325, A642L) | iOS 26.5.2 | boots from flash, Metal plug-in on Mesa ir3, touch, Wi-Fi | D |
| `taynotfound/ios-rain` | Redmi 10C | iOS 16 | Metal GPU, touch, internet, sound | D |
| `AdyaGMD/ios-spes` | Redmi Note 11 (SM6225) | iOS 16 | GPU, Safari, Wi-Fi, buttons | D |

All alioth repos the tracker knows: `xiongnemo/hakios-alioth`, `FFT-infra/UniXNU-alioth`,
`MrMoxing/ios-alioth`, and UniXNU forks `bangbang0822`, `songchiyu`, `Taishang1024`, `yang232138`,
`fjcx555` (all "device repo only", no independent result).

## 4. New to us, ranked by open problem

1. **(a)(b)(c) `oosexgang/hakios-metal`** — <https://github.com/oosexgang/hakios-metal>, moved into
   `hakios-xnu-kernel/hakios-metal/` (MIT, 41★). Metal's command model directly on `HakiosGPU` via
   msm-DRM, PM4 + a6xx encoders checked against Mesa XML, compute/blit/first draw. This is the same
   kernel ABI we have, unlike AdrenoMetal (Vulkan/Turnip, NativeAdreno ABI). It also names our hang
   exactly: a dispatch that never finishes sets **no fault bit**; the wait timeout is the only signal,
   and `gpu_recover=1` detects it (~2 s) and resets the GPU in ~0.1 s, reporting the hanging line. Read
   before any AdrenoMetal work.
2. **(e)(f)(c) `rui12366B/UniXNU-gts7xlwifi`** — <https://github.com/rui12366B/UniXNU-gts7xlwifi>.
   Same SoC family and GPU as alioth (SM8250-AB, A650), iPadOS 17.7.11: **QCA6390 Wi-Fi via Linux
   ath11k + a wpa_supplicant service**, ADSP audio (GLINK/SMEM/SMP2P/QMP), persistent UFS Data
   container, USB device mode with Apple's stack. The only non-HakiOS QCA6390+SM8250 working Wi-Fi
   found in this survey; its README is a per-area state table, not a marketing claim.
3. **(a)(b) `xiongnemo/hakios-alioth` — `docs/ru/metal.md` and `bsd/dev/hakios.adreno.c`**.
   The repo is already our reference, but two artifacts are not in our docs: (i) the exact Metal
   discovery contract — `IOAcceleratorES` → `MetalPluginName`/`MetalPluginClassName` → bundle →
   `_MTLDevice` subclass → `initWithAcceleratorPort:` — plus proof the port publishes an **empty
   `IOAcceleratorES` named "sgx"** so CoreAnimation does not wait 30 s, deliberately without the two
   properties; (ii) the per-client SMMU switch lives in `bsd/dev/hakios.adreno.c`
   (`space_switch`/`ring_switch`, `CP_SMMU_TABLE_UPDATE 0x53`), not in `drivers/gpu`, which is the
   file our 11-27 diff read. That path is a direct lead for the 256-dword stop under per-client spaces.
4. **(a)(c) `UniXNU/AdrenoPM4`** — <https://github.com/UniXNU/AdrenoPM4> (MIT). Small PM4 packet
   encoding kit + A740 command helpers used by the native submission path; a second opinion on our
   packet builder and parity/opcode tables.
5. **(a)(c) `RigoLigoRLC/unixnu-adreno6xx`** — <https://github.com/RigoLigoRLC/unixnu-adreno6xx> (MIT,
   A642L). A worked A6xx submission/completion model: 8 jobs in the hardware ring, per-queue FIFO,
   10 ms service poll, 500 ms hardware timeout, fault retention until CP/GMU DMA stops. Useful for
   reasoning about our stall/fence timeouts even though the chip is A642L.
6. **(b)(c) `FFT-infra/Adreno650`** — <https://github.com/FFT-infra/Adreno650> (MIT). The A650 KMD
   branch points (interrupt mask, ring `NO_UPDATE`, `a6xx_submit` prologue, `CACHE_FLUSH_TS` fence,
   `CP_ME_INIT`) if we ever adopt the FFT/iPadOS stack; already summarised in
   `docs/adrenometal-feasibility.md`.
7. **(e) `UniXNU/QcaBluetooth`** — WCN7850 BT over a Skywalk UART pipe; not QCA6390, but the closest
   public XNU transport shape for the same vendor family (xiongnemo uses HCI over UART at 921600).
8. **(b) `open-mapple/mapple_gpu_adreno`** — <https://github.com/open-mapple/mapple_gpu_adreno> (MIT).
   Metal backend over Mesa **freedreno** (not Turnip) through an msm-style client (`sweetgpuabi=1`);
   mock-tested only, but it is a third architecture for Metal-on-Adreno and closer to our msm ABI.
9. **(f) `open-mapple/mapple_splitboot`** — userdata GPT front/back carve + chainboot menu. Already
   assessed and deferred in `docs/splitboot-feasibility.md`; the site adds nothing new.
10. **Tooling: the API itself** — `/api/forks?limit=500`, `/api/devices`, `/api/status?device=poco-f3`
    give a machine-readable watchlist for new alioth/SM8250/A650 entries without scraping the UI.

## 5. Contradictions and corrections to our working assumptions

1. **Metal is not required for a GPU-composited UI on iOS 16.** xiongnemo's SpringBoard/backboardd
   composite through its own `EAGLContext` on Mesa/freedreno; the port states plainly that the home
   screen and compositor draw with OpenGL ES, and Metal is only for installed apps. Our framing
   ("no `IOAcceleratorES`/Metal, so no GPU-composited UI") is wrong: the compositor path is GLES, and
   that is the path our 256-dword stall is actually blocking. Metal is an apps feature, not the UI
   prerequisite.
2. **Wi-Fi on alioth is not an unsolved hardware problem.** A same-board port measures 5 GHz WPA2 at
   309–426 Mbit/s with `ath11k` under a LinuxKPI layer, plus BT audio; our `hakios-net` already ports
   that kernel side compile-only. The UniXNU alioth port's "no Wi-Fi" is a different stack failing at
   PCIe DBI step 10 (and its catalog driver is ath12k, not ath11k) — not evidence about the chip.
3. **`IOAcceleratorES` is not merely "missing".** In the reference it exists as an intentionally empty
   service named "sgx": without any service of that class, CoreAnimation waits ~30 s per process before
   falling back. The real gap is the two string properties, a bundle whose class subclasses `_MTLDevice`,
   and the AIR→NIR compiler — not the IOKit class itself.
4. **Our earlier reading of the reference missed the per-client switch.** `docs/alioth/status.md`
   claims an address space per client (6 clients, 33,012 switches, no faults); our 2026-11-27 note
   found none in `drivers/gpu`. Both are true at different layers: the switching is in
   `bsd/dev/hakios.adreno.c`, gated by `gpu_spaces`, with an optional `gpu_ring_switch=1` path where the
   CP performs `CP_SMMU_TABLE_UPDATE`. Re-read that file before concluding the reference has "one space".
5. **Site aggregates are unreliable.** "18 with Metal" vs "63 GPU accelerated"; a "Xiaomi 17 Pro Max,
   iOS 16.5, no repo" row; a device page listing iOS 18.7.10 for a project whose README says 16.7.16.
   Use per-row sources, never the counters.
6. **Community docs lag the code.** hackiosx.dev's "Open problems" says "no project has Bluetooth yet"
   while iOSOnAnd and xiongnemo report BT pairing and BT audio. Cite the repo, not the explainer.

## 6. Method

- Site pages read: `/`, `/?tab=repos`, `/device/poco-f3`, `/stats`, `/docs`, `/docs/sources`, `/docs/api`.
- JSON pulled read-only: 296 devices, 600 forks, all statuses for `poco-f3`.
- Repos opened/verified: `xiongnemo/hakios-alioth` (README, `docs/alioth/status.md`,
  `docs/alioth/boot-args.md`, `docs/ru/metal.md`, `tools/mk-ath11k.sh`, `LICENSE`,
  `bsd/dev/hakios.adreno.c`, `iokit/Kernel/hakios.gpu.cpp`), `FFT-infra/UniXNU-alioth`,
  `rui12366B/UniXNU-gts7xlwifi`, `UniXNU/AdrenoMetal`, `oosexgang/hakios-metal`,
  `RigoLigoRLC/unixnu-adreno6xx`, `open-mapple/mapple_gpu_adreno`, `open-mapple/mapple_splitboot`.
- Sibling registries read: `hakios-developers.com`, `unixnu.com/devices/alioth`, `hackiosx.dev`
  (projects, compatibility, how-it-works, future).
