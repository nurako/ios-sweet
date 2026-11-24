# Roadmap: matching `xiongnemo/hakios-alioth`

That project runs stock iOS 16.5 on the same phone with most of the hardware working. It is the
reference for every subsystem below. This file records what it has, what we have, and the order
we are porting it in. Verified facts live in `NOTES.md`; this is the plan.

## What hakios-alioth has working (from its docs)

| Area | Their state | Our state |
| --- | --- | --- |
| Boot | Own UEFI loader, RAM boot, `fastboot oem` control channel, log/screenshot over fastboot | Own shim `fastboot boot`, iOS root flashed to `userdata` |
| Display | Panel driver (`bsd/dev/alioth_dsi.c`), 120 Hz pacing (`fb_vsync=2`), brightness via DCS 0x51 from CoreBrightness, auto-brightness from the SLPI light sensor | Console + AppleCLCD on the ABL splash; no panel control, fixed brightness |
| GPU | `hakios.adreno.c` + `hakios.gpu.cpp`: Adreno 650 with zap via TrustZone, GMU, SQE, CP, SMMU per-process address spaces; OpenGL ES 1/2/3 through Mesa (`eagl.c`), Metal/SceneKit checks; games at 60 fps | Staged probe through step 20 (GMU firmware, HFI, 3D core, CP); zap signature refused; no rendering, no IOKit GPU service |
| USB | `hakios.dwc3.c` / `hakios.usb.c`: device mode, `usbmux`, USB serial console, install channel | PHY + DWC3 up to `ep0`, blocked by apps-SMMU/hypervisor trap |
| Audio | `hakios.audio.c` + LPASS/WCD938x; speakers and microphone (`mic=4`), Voice Memos | None |
| Camera | `hakios.camera.c`: all four sensors, Camera.app preview, flashlight (`hakios.torch.c`) | None |
| Sensors | Sensor DSP (`slpi=1`), ambient light, motion | None |
| Wi-Fi | `lx_80211.c` layer + firmware from `fw-wifi/`; joins configured networks | None |
| Bluetooth | Working per their docs | None |
| Modem / cellular | Probe tools and firmware handling | None |
| CPU frequency | `hakios.cpufreq.c` (EPSS LUT) | Cores stay at bootloader frequency |
| Haptics | Working | None |
| Keys / touch | Working | **Working** (FT3698 touch, PM8150 keys) |
| SMP | 7 cores (`bootcpu=7 cpus=7`; 8 cores froze it twice) | **8/8 cores verified repeatedly** |

## Order

1. **GPU** (in progress): get the zap shader authenticated (patch 0111 tests the low physical
   address), then `CP_MEM_WRITE`, then a frame, then port `hakios.gpu.cpp` as the IOKit service and
   the Mesa/`eagl.c` path for OpenGL ES. This unblocks PosterBoard and every app that renders.
2. **Display**: port `alioth_dsi.c` (panel on/off, brightness, 120 Hz pacing) — needed for clean
   vsync and for power, and it removes reliance on the ABL splash.
3. **USB**: revisit with the hypervisor trap lesson (single non-inlined accesses) and their DWC3
   driver; a serial console and `usbmux` would make every later step easier.
4. **CPU frequency** (`hakios.cpufreq.c`): small, self-contained, improves everything else.
5. **Audio** (speakers, then microphone): biggest user-visible win after the GPU.
6. **Wi-Fi / Bluetooth**, then **camera / sensors / flashlight / haptics**.

Each step: port the driver as a patch series entry, validate with `tools/xnu-cc.py`, one manual CI
run, one `fastboot boot`, evidence recorded in `NOTES.md`.
