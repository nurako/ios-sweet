# End-to-end test: a client process draws on the Adreno and shows it

This is the M0 test from `PORT-NOTES.md`. It proves that an ordinary iOS process
can open `HakiosGPU`, get Mesa/freedreno to build and submit a frame, read the
result back, and put it on the panel. It does **not** yet test the
CoreAnimation/IOSurface presentation path (that is M1).

## 0. What you need

* The combined kernel (`hakios-all`: GPU `0200` + USB `0300`) and the ADT with
  `/sweet-gpu`, built as in `hakios-port/COMBINED.md`.
* A root/userdata image with the built `libOSMesa.8.dylib` + `gl_test`.
* Boot with the combined cmdline, in particular:

```
gpu=1 adreno=22 adreno_keep=1 adreno_pause=0 gpu_irq=1 \
usbhakios=1 usb=2
```

`adreno_keep=1` is not optional: `hakios_gpu_ready()` is false without it and
every request except `kHakiosShow` is refused with `kIOReturnNotReady`.
`usb=2` gives the CDC-ACM port (`1209:316d`, `/dev/ttyACM0`) and `usbsh`.

## 1. Build the two binaries (macOS, not this Linux box)

```sh
cd hakios-port-userland
IOS_SDK=~/theos/sdks/iPhoneOS16.5.sdk ./build-mesa.sh
IOS_SDK=~/theos/sdks/iPhoneOS16.5.sdk ./build.sh
# -> out/libOSMesa.8.dylib, out/gl_test
```

Or take them from the `hakios-userland` CI artifact produced by
`build-userland-gpu.sh` (`userland.yml.patch`).

The library's install name is `/var/local/lib/libOSMesa.8.dylib` by default.
If you change `INSTALL_LIBDIR`, build both binaries again (dyld records the
absolute path).

## 2. Install into the root image

Mount or unpack the iOS root, then:

```sh
cd hakios-port-userland
./install-root.sh /path/to/mounted/root
# optional launchd job:
JOBS=1 ./install-root.sh /path/to/mounted/root
```

This writes:

```
/var/local/lib/libOSMesa.8.dylib
/usr/local/bin/gl_test
/System/Library/LaunchDaemons/com.hakios.gltest.plist   (JOBS=1)
```

Then rebuild/flash the userdata image the usual way (`tools/mkiosroot.sh` and
the shim/ADT flow in `NOTES.md`).

## 3. Or install with SWEETBOX (no reflash)

SWEETBOX's root allowlist includes `/usr/local/bin/`, `/var/local/lib/` and
`/System/Library/LaunchDaemons/` (see `ios-sweet-autorun/docs/sweetbox.md`).
The parent directories must already exist in the root; create
`/usr/local/bin` and `/var/local/lib` once if they do not.

From `ios-sweet-autorun`:

```sh
python3 tools/sweet-box.py pack /tmp/gpu.bin \
  ROOT/usr/local/bin/gl_test=../ios-sweet-userland/hakios-port-userland/out/gl_test \
  ROOT/var/local/lib/libOSMesa.8.dylib=../ios-sweet-userland/hakios-port-userland/out/libOSMesa.8.dylib \
  ROOT/System/Library/LaunchDaemons/com.hakios.gltest.plist=../ios-sweet-userland/hakios-port-userland/userland/com.hakios.gltest.plist

# phone in recovery, adb available:
python3 tools/sweet-box.py apply /tmp/gpu.bin
```

Boot with `sweetbox=1 sweetboxroot=1` plus the GPU/USB args above.

Caveat: a new launchd plist is only picked up if the launchd cache sees it.
For a first test, skip the job and run the binary over `usbsh` (next section).

## 4. Run it

### 4.1 Over the USB console (recommended; stdout comes back to the host)

```sh
tools/sweet-usbsh.sh '/usr/local/bin/gl_test 8'
```

Or interactively open the port with any terminal (`screen /dev/ttyACM0 115200`)
and type the same command at the `usbsh` prompt.

Expected program output (values vary):

```
gl_test: Mesa, ...; Adreno ... (or freedreno/FD650); OpenGL ES 3.2 Mesa 25.0.7
gl_test: 1080 x 2400 drawn in NN ms, read back in NN ms; error 0; ...
        ... N of M pixels inside the triangle ...
gl_test: the picture is on the panel (0x0), for 8 seconds
```

The renderer string must **not** contain `softpipe` or `llvmpipe`. If it does,
Mesa fell back to software (`OSMESA_SOFTWARE=1`, or `drmOpenWithType` failed).

The panel shows a dark-blue frame with a red/green/blue triangle for ~8 s; the
window server may draw over it as soon as it produces its next frame, which is
fine.

### 4.2 From the launchd job

`com.hakios.gltest` runs `/usr/local/bin/gl_test 8` at load and sends stdout to
`/dev/console`. It is simplest to use it to prove "a process at boot can do
this", but its output is then in the console/sweet ring rather than the USB
stream.

## 5. The lines that prove each step

### 5.1 GPU service present (kernel console / sweet ring)

```
HakiosGPU: service published (class HakiosGPU), user client HakiosGPUUserClient
HakiosGPU: IOServiceMatching("HakiosGPU") will find this service; open it with type 0
```

From the boot ladder (already verified on the phone, not caused by `gl_test`):

```
adreno: steps up to 22 ...
adreno: ... THE 3D CORE WRITES OUR MEMORY ON COMMAND
adreno: 22: A PICTURE DRAWN BY THE GPU IS ON THE PANEL ...
HAKIOS GPU: GIC SPI 332 level attached ...
adreno: THE 3D CORE'S INTERRUPT (GIC 332, level) ...
```

### 5.2 A client submitted work to the GPU (kernel log)

`gl_test` creates GEM buffers (0x42), maps them (IOConnectMapMemory), builds a
ring and submits (0x46), waits on a fence (0x47). The kernel logs the first four
submissions and a five-second summary:

```
HakiosGPU: submission 1: N command buffers, the first at 0x..., M words
...
HakiosGPU: N submissions in 5000 ms: N command buffers and N buffers named, N KB out of the cache ...
```

If the IOSurface path is exercised (M1, not this test), the same stats mention
surfaces:

```
HakiosGPU: buffers: ... N surfaces out of the cache ...
HakiosGPU: surfaces pushed for: the seed moved ... mapped by the program ...
```

A refusal is loud and specific (and is the line to report):

```
HakiosGPU: <proc>: request 0x42 refused (0xe00002c2): a new buffer of N bytes, flags 0x...
HakiosGPU: request 0x.. (N bytes) is not known here
```

### 5.3 The GPU actually drew (program output + panel)

`gl_test` waits with `glFinish()` (which is a submit + fence wait), reads the
pixels back with `glReadPixels`, counts the pixels inside the triangle, and prints
non-zero draw/read times. The panel copy is `kHakiosShow` 0x7f (kernel
`MiniIOMobileFramebufferShow`), so seeing the triangle proves the pixels the GPU
wrote came back through the DRM client.

### 5.4 USB console

The USB console carries the `usb:` lines and, when you run `gl_test` through
`usbsh`, the program's `gl_test:` stdout. Kernel `IOLog("HakiosGPU: ...")` lines
go to the console and the 4 MiB persistent ring, not the USB tee (see
`hakios-port/COMBINED.md`, "What to expect on the host"). Read them back with:

```
# next boot:
sweetlogdump=262144 sweetloggrep=HakiosGPU sweetlogdumpwait=120 ufslogsecs=1
```

or `tools/sweet-log-pull.sh` / `tools/sweet-log.py`.

## 6. Failure map

| symptom | likely cause |
| --- | --- |
| `gl_test: no OpenGL ES context` | `libOSMesa.8.dylib` missing/wrong install name, or dyld did not find `/var/local/lib` |
| renderer says softpipe/llvmpipe | `OSMESA_SOFTWARE=1` in environment, or 0x7e/0x42 open failed |
| `no GPU service in this kernel` | booted without `adreno_keep=1`, or GPU ladder did not reach `HakiosGPUStart()` |
| `request 0x42 refused ... NotReady` | same: `hakios_gpu_ready()` is false |
| `request 0x46 refused` / `not taken` | submission too large (`nr_cmds>128`, `nr_bos>8192`) or relocation (`nr_relocs != 0`); this port uses softpin and must not send relocations |
| picture drawn but no `gl_test:` text over USB | program was started by launchd, output went to `/dev/console`; read the sweet ring |
