# hakios-gpu2: making the Mesa client path observable and bounded

Branch `hakios-gpu2` (from `hakios-integrate`). Nothing here is on by default: no
boot arg, no new kernel log line, and the launchd job still runs `gl_test` only
when `/var/tmp/run-gl-test` exists.

## 1. The client call sequence (what `gl_test` makes happen)

`gl_test` links the iOS build of Mesa 25.0.7 (`libOSMesa.8.dylib`) and the
`hakios-drm` stand-in for libdrm. The first interactions, in order, are:

| # | `gl_test` / Mesa call | libdrm shim | `HakiosGPU` selector | kernel work |
|---|---|---|---|---|
| 1 | `OSMesaCreateContextAttribs` | `drmOpenWithType("msm")` | `IOServiceOpen(..., type 0)` | `HakiosGPUUserClient::start`, `hakios_gpu_space_new()` |
| 2 | screen/pipe setup | `drmGetVersion`, `drmGetCap` | none | shim only (claims DRM 1.7 / `msm`) |
| 3 | `fd_device`/`msm_pipe` | `drmCommandWriteRead` | `0x40 MSM_GET_PARAM`, `0x4a SUBMITQUEUE_NEW` | params, queue id |
| 4 | first `fd_bo_new` (ring, then textures) | `drmIoctl` | `0x42 MSM_GEM_NEW` | memory, SMMU pages, handle |
| 5 | `fd_bo_map` | `hakios_drm_map` | `IOConnectMapMemory64` → `clientMemoryForType` | maps the buffer into the process |
| 6 | `glFinish` (draw) | same | `0x46 MSM_GEM_SUBMIT` | ring submit, fence N |
| 7 | `glFinish` (wait) | same | `0x44 MSM_GEM_CPU_PREP` / `0x47 MSM_WAIT_FENCE` | waits for a fence |
| 8 | `glReadPixels` | same | another submit + prep + `0x43 GEM_INFO` | read back |
| 9 | panel copy | same | `0x7f kHakiosShow` | copies pixels to the panel |
| 10 | teardown | same | `0x09 DRM_GEM_CLOSE` | frees buffers |

The first interaction that could block **before any output** was
`OSMesaCreateContextAttribs` (step 1–4: open the service, allocate and map the
first buffers). Its output was also lost because stdout was fully buffered.
The first interaction with an explicit *wait* is `0x44 MSM_GEM_CPU_PREP`, and
that is where a real defect was found: the kernel waited for
`hakios_gpu_last()` — the GPU's newest submission from **any** client — instead
of the fence of the named buffer. One unfinished (or hung) submission would make
an unrelated client's first map wait out the whole patience and then fail.

## 2. What was changed

### 2.1 `gl_test` (userland)

* `setvbuf(stdout/stderr, NULL, _IONBF, 0)` at the top of `main`.
* `signal(SIGALRM, ...)` + `alarm(20)`; the handler writes
  `gl_test: WATCHDOG: no progress at step N` to fd 1 and 2 and `_exit(124)`.
* Every phase is announced **before** it can block:
  `gl_test: step N: ...` (start, context, MakeCurrent, glGetString, texture,
  framebuffer, shaders, draw/finish, readback, panel, done). `fill` gets a
  3× (60 s) alarm because it draws many frames.

### 2.2 Kernel (`iokit/Kernel/hakios.gpu.cpp`, `bsd/dev/hakios.adreno.c`)

Opt-in tracing, boot arg `adreno_loud=1`:

* one line per external method with selector and key parameters, and one with
  the return value, handle/fence and time in the kernel
  (`HakiosGPU: loud: request 0x46 GEM_SUBMIT ... -> 0x0 in N us: fence N`);
* every `gpuWait()` says the fence, the requested patience, and either
  `fence N DONE after N us` or `fence N NOT DONE ...`;
* the Adreno submit path says whether the completion packet asks for the
  interrupt (`CP_EVENT_IRQ`) or the fence word is polled, and the wake path
  says whether `CP_EVENT_IRQ`/`CP_CACHE_FLUSH_TS` woke the wait.

Bounds (always on, not only under `adreno_loud`):

* client-triggerable waits (`0x44`, `0x47`) are capped to
  `GPU_CLIENT_PATIENCE_MS = 2000` ms (was up to 5000);
* `0x44` now waits on the **named buffer's** fence, falling back to the global
  last fence when the buffer has never been submitted;
* entering a buffer into the SMMU has a `GPU_MAP_BUDGET_MS = 250` ms wall-clock
  budget; a slower buffer is rolled back and refused instead of holding
  `gGPULock` indefinitely. An unknown/bad handle returns `kIOReturnBadArgument`.
* existing bounds are unchanged: `gpuWait` never exceeds its patience,
  `space_switch`/`gpu_submit` wait at most 500 ms/2 s, the panel `fb_swap_async`
  guard at most 50 ms, and every `gpWait` drops `gGPULock` while sleeping.

Patch `0200-hakios-gpu.patch` was regenerated. It still applies after `0119`,
`0300` still applies after it, and it does not modify `bsd/dev/sweet_gpu.c`.

## 3. Expected proof lines

Healthy run (ring or serial console):

```
GLTEST: start
gl_test: step 1: start (unbuffered; watchdog 20 s); opening the GPU service and making the DRM screen
gl_test: step 2: OSMesaCreateContextAttribs returned ...
gl_test: Mesa, ...; Adreno ... / freedreno/FD650; OpenGL ES 3.2 Mesa 25.0.7
HakiosGPU: loud: request 0x42 GEM_NEW 10485760 bytes, flags 0x...
HakiosGPU: loud: request 0x42 -> 0x0 in ... us: handle N
HakiosGPU: loud: request 0x46 GEM_SUBMIT ... -> 0x0 in ... us: fence N
adreno: loud: submission N queued: ... completion interrupt asked for (CP_EVENT_IRQ)
adreno: loud: fence N: the 3D core's interrupt woke the wait
HakiosGPU: loud: fence N DONE after ... us (waited yes)
gl_test: step 9: glFinish returned
gl_test: 1080 x 2400 drawn in ... ms, ...
gl_test: the picture is on the panel (0x0), for 8 seconds
GLTEST: exit 0
```

A hang now names itself:

```
GLTEST: start
gl_test: step 6: ...
gl_test: WATCHDOG: no progress at step 6 (see the previous gl_test: step line)
GLTEST: exit 124
```

If the last step is 1–4, the block is in open/screen/buffer allocation; if it is
6–8, it is a submit or fence; if it is 9, it is the panel copy.

## 4. Reading a run

Boot once with `adreno_loud=1` (keep the existing GPU args, e.g.
`sweetgpu=22 sweetgpukeep=1 gpu_irq=1`), create `/var/tmp/run-gl-test`, run the
job. After it has written (the ring writer flushes every `sweetlogsecs`, default
10 s; use `ufslogsecs=1` for tests), reboot with:

```
sweetlogdump=4194304 sweetloggrep=gl_test sweetlogdumpwait=60 ufslogsecs=1
```

That prints the previous session's ring tail while holding the screen for 60 s.
For the job markers use `sweetloggrep=GLTEST`; for the kernel side use
`sweetloggrep=loud` (or `sweetloggrep=HakiosGPU`). One substring per boot.

**Filter caveat.** `sweetloggrep` has been unreliable in recent dump boots
(some printed the whole ring). If everything comes out, capture the normal
serial/USB console instead (`tools/sweet-usb-console.sh`, or `screen`) and grep
on the host:

```
sweetlogdump=4194304 sweetlogdumpwait=60 > console.txt
grep -E 'GLTEST|gl_test|HakiosGPU: loud|adreno: loud' console.txt
```

Do not trust a filter result that prints no `SWEET LOGDUMP: end`; the whole-ring
case is a dump, not a filter working.

## 5. Next two steps

1. Boot `adreno_loud=1`, run the launchd job, and read the step where a hang
   stops (or confirm `GLTEST: exit 0` and the pixel/panel lines). If it stops in
   the first buffer, the new `HakiosGPU: loud: request 0x42` / SMMU-budget lines
   name the buffer and the refusal.
2. With a real context reached, run `/usr/local/bin/gl_test fill` through `usbsh`
   and compare the `gl_test: fill:` timings against the kernel's five-second
   `HakiosGPU: ... submissions in ...` line; then move to the IOSurface (0x7e)
   path for the window server.

## 6. 2026-11-27: the second `illegal PA` (0x5800000) and the shell-less job

**Caller.** In the kernel artifact named in the new report
(`gh run download 45876690142 ... -n xnu-kernel`, `__TEXT` at
`0xfffffe0007004000`) the supplied caller `0xfffffe0007b0ce7c` (written with an
extra `f`) is inside `kperf_kcallstack_sample.cold.3`. In the **pre-guard**
kernel 45778296613 the same address is exactly
`phystokv_range.cold.1 + 0x48`, the return from `bl panic` at `+0x44`. So the
panic string is from a kernel without the `copypv()` guard; the gpu2 kernel puts
that site at `0xfffffe0007b11de4/de8`. The panic site itself is
`phystokv_range()` reached from `copypv()` -> `flush_dcache64()` ->
`flush_dcache(phys=TRUE)` (or the internal `phystokv_range` of
`bcopy_phys_internal()`), i.e. a client-derived "physical" address.

**Value.** `0x5800000` = 88 MiB is below `gPhysBase = 0x1_00000000`; it is not
DRAM, not a GPU IOVA (that window starts at `0x20000000`), not a GEM handle and
not a SweetSurface offset. It is consistent with a **truncated high-bank PA**
(`0x1_05800000` -> `0x05800000`) or a low user/mapping address used as a PA.
The lower stack is absent, so the producer cannot be named from the string.

**Why the guard missed it.** Two reasons. (a) The image that panicked was the
pre-guard one (caller resolves there). (b) The old guard only ran inside
`copypv()` and only when `cppvPsrc`/`cppvPsnk` said the address was physical; a
caller of `flush_dcache64(..., TRUE)`/`clean_dcache64()` directly, or a caller
whose flags did not name the address physical, bypassed it. `pmap_valid_address`
alone is not the right predicate for `phystokv_range`: it is `pa_valid()`'s
managed range, not the linear-map test.

**Fix.** Validate at the first primitive, with the same bounds `phystokv_range`
uses (`gPhysBase`/`real_phys_size`), in addition to `pmap_valid_address`:
`flush_dcache()` and `clean_dcache()` skip a `phys=TRUE` address outside the
linear map; `bcopy_phys_internal()`/`bzero_phys()` choose the CPU copy window
for it; `copypv()` only flushes addresses that pass both tests. `newBuffer()`
prints `HakiosGPU: a buffer's physical address 0x... is not kernel memory;
refused` (or the scan-out variant) for the first 16 refusals and always under
`adreno_loud=1`; `submit()`/`show()` log bad client pointers the same way.

**Job.** iOS `/bin` has no shell, so `com.hakios.gltest` is now plain
`ProgramArguments = ['/usr/local/bin/gl_test','8']` plus
`EnvironmentVariables = {DYLD_LIBRARY_PATH=/usr/local/lib, GL_TEST_LAUNCHD=1}`.
`gl_test` checks `/var/tmp/run-gl-test`, unlinks it and prints `GLTEST: start`
when `GL_TEST_LAUNCHD` is set; without the sentinel it exits 0 immediately. A
manual `/usr/local/bin/gl_test` run does not need the sentinel.

## 7. 2026-11-27: GEM mmap -> SIGBUS on the first touch

**Path today.** Mesa's freedreno `msm_bo_map()` is patched to call
`hakios_drm_map(dev->fd, bo->handle, bo->size)`, which is
`IOConnectMapMemory64(connection, handle, mach_task_self(), &address, &mapped,
kIOMapAnywhere)`. The kernel side is `HakiosGPUUserClient::clientMemoryForType`:
`buffer(type)` (type == the 1-based GEM handle) returns `b->memory`, the
`IOBufferMemoryDescriptor` that `gemNew()` made in kernel_task with
`kIODirectionInOut | kIOMemoryKernelUserShared | kIOMapWriteCombineCache`, and
`*options = 0`. IOKit then calls `memory->createMappingInTask(clientTask, 0,
kIOMapAnywhere)`; the map length is `memory->getLength()`, which is the rounded
GEM size. That descriptor is real wired DRAM (the same pages `newBuffer()` passed
to `hakios_gpu_phys_ok()` and the SMMU), so the ioctls are not lying.

**Why SIGBUS.** The client mapped successfully but IOKit left holes / a short
user mapping, so the first store in the driver hit an unbacked PTE (BUS_ADRERR).
The old map code trusted the success return and never checked the returned
`address`/`mapped` length.

**Fix.**
- `clientMemoryForType` now validates: buffer exists, `memory != NULL`,
  `memory->getLength() >= b->size`, and **every page has a physical segment**
  (`gpuBufferMappable()`). Otherwise it returns `kIOReturnNoSpace` and logs why;
  a successful map logs `HakiosGPU: loud: map type %u -> %llu bytes ...`.
- `hakios_drm_map()` rejects `address == 0`, `mapped < size`, and probes one byte
  per 4 KB under a temporary `SIGBUS`/`SIGSEGV` handler; a fault becomes a clean
  `MAP_FAILED` with `hakios-drm: map not backed ...` on stderr, not a crash.
- `gl_test` installs `SIGBUS`/`SIGSEGV` handlers that print
  `gl_test: FAULT: signal N at 0x... at step M` and exit `128+N`.

Expected successful map lines (kernel, `adreno_loud=1`):

```
HakiosGPU: loud: map type 2 -> 16384 bytes (buffer 16384), address from IOKit
HakiosGPU: loud: map type 3 -> 4194304 bytes (buffer 4194304), address from IOKit
```
and on stderr with `hkdrm=1` the address the client got:
`hakios-drm: mapped handle 3: 4194304 bytes -> address 0x..., mapped 4194304, result 0x0`.

Failure now says `HakiosGPU: map of buffer N refused (0xe00002c4): not backed for
the whole length`, or on the client, `hakios-drm: map not backed handle N: ...`.
