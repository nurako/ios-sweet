# hakios-all: GPU + USB in one kernel

Branch `hakios-all` carries both ported subsystems:

* `xnu/patches/0200-hakios-gpu.patch` — Adreno 650 driver, HakiosGPU,
  SweetSurface bridge, GIC SPI 332.
* `xnu/patches/0300-hakios-usb.patch` — hakios-alioth DWC3 gadget, CDC-ACM
  serial log, `/dev/hakios-usb`, usbmux service and the `usb=3` tcp peer hunk.

`0300` is regenerated against the tree with `0200` already applied, so the two
apply **in this order** onto blacktop xnu `6639065` + patches `0001..0118`.
Neither patch modifies `bsd/dev/sweet_gpu.c`.

## What was resolved by hand

Both branches supplied the same helpers:

* `loader_log_putc()` / `loader_log_tee` / `loader_log_tee_total` — now defined
  once in `bsd/dev/hakios_gpu_adapter.c`; every byte goes to the 64 KiB
  loader/USB ring and to the persistent sweet console ring.
* `hakios_board_is_alioth()` / `hakios_board_panel_height()` — taken from
  `bsd/dev/hakios.board.c` (0200); the USB adapter no longer defines them.
* `0300` no longer adds `bsd/sys/hakios.board.h` (0200 already does).
* `sweet_ufs_init()` now calls `hakios_usb_init()` **before**
  `hakios_adreno_init()`, so the gadget is up while the GPU ladder runs.

## Boot cmdline (both on)

```
debug=0xc serial=3 cpus=8 keepsyms=1 -noprogress rd=ufsroot0 \
unentitled_ios_sim_launch=1 ignition_level=1 wdt_test=no_user_checkin \
ufsrw=1 rootrw=1 launchd_unsecure_cache=1 wdt=-1 \
sweettouch=1 sweettouchdelay=0 sweetkeys=1 sweetusb=0 sweetgpu=0 \
board_pil_gpu=0x8681a000 board_pil_gpu_size=0x2000 \
usbhakios=1 usb=2 \
adreno=22 adreno_keep=1 adreno_pause=0 gpu_irq=1
```

Use the same ADT build as the GPU port (the `/sweet-gpu` blobs plus
`/chosen hakios-board = "alioth"`).

## Ordering / hazards

* USB is initialised first by the combined `sweet_ufs_init()` hook. No GPU
  delay is needed; `sweetgpudelay` belongs to the old `sweetgpu=N` probe
  (which is off here). If you ever re-order the hooks, or use `sweetgpu=N`,
  set **`sweetgpudelay=20`** so the gadget enumerates before the GPU touches
  its power domains.
* `sweetusb=0` keeps the old probe off; `sweetgpu=0` keeps the old GPU probe
  off. `usbhakios=1` is the USB master switch, `adreno=N` the GPU one.
* USB takes the controller and starts its kernel thread before the GPU ladder;
  the GPU ladder blocks the boot thread for its steps/watch, but the USB
  thread keeps streaming.
* `board_pil_gpu*` must stay for the current alioth firmware; a wrong zap
  region stalls the phone.
* `gpu_irq=1` attaches GIC SPI 332; `gpu_irq=0` still works (polling), so a
  USB-only or mixed test can drop it.

## What to expect on the host

`/dev/ttyACM0` appears as `1209:316d`; read it with
`tools/sweet-usb-console.sh` (or `cat`). The stream contains:

```
usb: level 2: a look, then the controller for the kernel
usb: THE CONTROLLER IS THE KERNEL'S: a serial port (1209:316d ...)
adreno: steps up to 22 ...
adreno: ... THE 3D CORE WRITES OUR MEMORY ON COMMAND
adreno: 22: A PICTURE DRAWN BY THE GPU IS ON THE PANEL ...
HAKIOS GPU: GIC SPI 332 level attached, ...
adreno: THE 3D CORE'S INTERRUPT (GIC 332, level) ...
HakiosGPU: service published ...
```

GPU step lines reach the USB ring because `hakios.adreno.c` logs through
`say()` -> `loader_log_putc()`. `IOLog()` lines from the IOKit service (for
example the 5-second `HakiosGPU:` statistics) go to the console/sweet ring,
not the USB tee, unless a later adapter forwards `sweet_log_copy()`.

## Verification done here

Scratch tree = upstream blacktop `6639065` + `0001..0118`:
`git apply --check 0200` then `git apply --check 0300` both pass, and the
result compiles the union with `tools/xnu-cc.py` against CI run `45735232511`:
`hakios.adreno.c`, `hakios.board.c`, `hakios_gpu_adapter.c`, `hakios.gpu.cpp`,
`hakios_miniosurface_stub.cpp`, `hakios.usb.c`, `hakios.dwc3.c`,
`hakios_usb_adapter.c`, `hakios.usbmux.cpp`, `sweet_ufs.c`, `tcp_usrreq.c`
— **0 failed**. No boot yet.
