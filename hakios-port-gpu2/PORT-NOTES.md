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
`hakios-drm: mapped handle 3: 4194304 bytes -> 0x..., probed 1024 pages, ok`.

Failure now says `HakiosGPU: map of buffer N refused (0xe00002c4): not backed for
the whole length`, or on the client, `hakios-drm: map not backed handle N: ...`.


## 8. 2026-11-27: the probe only read; the client writes

The 13:41 run (userland ul4: the probe was present) still died:
`CRASH gl_test pc 0x1ecbb1030 ... far 0x1e36cff40`, `SIGBUS BUS_ADRERR`, right
after `map type 5 -> 4194304`. The probe loop was real (`ldrb wzr, [x9,x10]` in
the disassembly) but it only **read** the first byte of each page. A mapping can
be readable and still fault on a store (read-only PTE, or the page exposed for
read but not write); the driver's next action after mapping is a store, so the
probe could pass and the first write still SIGBUS. The descriptor itself is the
right kind: `IOBufferMemoryDescriptor::inTaskWithOptions(kernel_task,
kIODirectionInOut | kIOMemoryKernelUserShared | kIOMapWriteCombineCache)`, i.e.
user-shared, in/out, length == buffer, kernel view present; the new loud line
prints those options/direction/length.

**Fix.** `hakios_drm_map` now probes every 4 KB page with **both a read and a
write of the first and last byte** (volatile, checksum consumed), inside the
same `sigsetjmp`/handler; a fault reports `map not backed at page offset N` and
unmaps. A successful map prints
`hakios-drm: mapped handle N: B bytes -> ADDR, probed P pages, ok` under
`hkdrm=1`. The kernel logs each GEM descriptor's flags/direction/length and each
map's descriptor flags/direction, so a read-only or wrong-direction descriptor
is visible next run.

## 9. 2026-11-27: one stale fence poisoned every later wait (`gGPUReported`)

The 14:48 log shows the real hang: `gpuWait(2)` returns in **147 us** with
`NOT DONE ... the GPU was reported`, after a different client's `fence 1` had
timed out earlier. `gpuWait()` broke its loop on the **global** `gGPUReported`
flag, not on this fence's patience, so the first timeout (a stale client/fence,
and `gpu_recover=1` was not booted to reset it) made every subsequent wait fail
immediately — even for a fence that would have completed. The client's submit
itself is fine: `0x46` returns a fence, the completion packet writes
`CORE_SCRATCH_ADDRESS + GPU_FENCE_AT` (0x1200040) with that number, and the
packet/ring positions are now logged.

**Fix.** `gpuWait()` no longer breaks on `gGPUReported`; each wait is bounded
only by its own (client-capped 2 s) patience, and the first check is still
`hakios_gpu_done(fence)`. `gGPUReported` remains only to rate-limit the
`hakios_gpu_report()` line; it cannot fail other clients' waits. `adreno_loud=1`
now prints:
- `wait for fence N ...; fence word at start W (last submitted L)`
- `fence N DONE ...; fence word W` / `fence N NOT DONE ...; fence word W`
- `submit -> fence N, fence word W (wanted N)`
- `submission N queued at ring A..B ... completion at 0x1200040 <- N`

The per-2 ms `the wait's deadline came first` line is gone (only the interrupt
wake is printed), so the ring is readable.

## 10. 2026-11-27: 0200 regenerated from sources, and a guard

`0200-hakios-gpu.patch` is now generated from the current sources, not edited by
hand. It still owns the same 14 files. Regeneration recipe (the one that was
verified):

```
gh run download 45973420555 -R nurako/ios-sweet -n xnu-buildtree -D /tmp/bt9
tar xzf /tmp/bt9/buildtree.tgz -C /tmp/bt9
git apply -R /tmp/runpatches/0501.patch ... 0300 ... 0200   # run's own patches
# then: copy current sources over the 0200 files and `git diff` them
```

Verification performed:
- `0200` applies to the run's pre-0200 baseline (after reversing 0501..0200);
- every one of its 14 post-images equals the current tree/sources;
- `0300`, `0400`, `0500`, `0501` (that run's copies) still apply **sequentially**
  after it;
- it does not touch `bsd/dev/sweet_gpu.c`.

sha256 of the patched files (compare a future CI tree against these):

```
6fd7d0e649b92785d3d6a7bd24bd08453ab01e2f02c973e5da498df248ddf71d  bsd/dev/hakios.adreno.c
a2b42452f98a2fc4b1f429ec021a53b583a32bf0e0bf84e48da7018ff2054282  iokit/Kernel/hakios.gpu.cpp
```

### The guard

```
tools/check-patch-sources.sh [--quiet] [PATCH...]
```

It reconstructs every file each patch **creates** from the patch's `+` lines
and compares it with this repo's source copy (`hakios-port/kernel/...`), exits
1 and names the differing files otherwise. Default: 0200, 0300, 0400, 0500,
0501. Current result: `9 file(s) match their sources, 9 skipped` (the skipped
ones are patch-only drivers and config files with no second copy).

It is not wired into `.github/workflows/xnu.yml`: that job applies patches to a
cached tree and does not keep a pre-0200 baseline to extract against. Run it
locally before committing any change to `hakios-port/kernel/**` or
`hakios-port/adapter/**`; it needs no build tree.

## 11. 2026-11-27: the client ring is kicked; the command buffer was not visible

The loud lines show the client path does exactly what the internal path does:
`gpu_submit()` appends to the same `core_ring` and `ring_send()` writes
`CP_RB_WPTR = ring_at` (the internal `ring_run()` only adds `hold()` and a RPTR
poll). The completion packet is `CP_EVENT_WRITE CACHE_FLUSH_TS` at
`CORE_SCRATCH_ADDRESS + GPU_FENCE_AT`; that page is one of the blocks
`hakios_gpu_space_new()` maps into **every** client space, so there is no SMMU
context mismatch: the client's buffers and the scratch page are in the same
space the core is switched to.

The suspect is the **command buffer's contents**: Mesa writes them through the
client's mapping, and `submit()` skipped the cache pass for ordinary buffers
(`!b->seen || !gGPUCached`), trusting write-combining. If the mapping is not
actually WC (or the core's view races the store buffer), the core fetches a
stale/zero IB, faults on it and never reaches our completion packet. The fence
word stays at 0 and the client waits out its patience.

**Fix.** `submit()` now pushes every named buffer (command buffers first, all
BOs) to memory with `hakios_gpu_to_memory()` before the ring is sent, and logs
the byte count under loud. No SMMU remap was needed. Also:
- `gpuWait()` already got the real unit; the ~209 ms exits were the old global
  `gGPUReported` break (removed in the previous commit), while the 2.06 s line
  is the true 2 s wait. A 60 s cap was added so a client cannot overflow the
  nanosecond multiply.
- a blocking `0x44 CPU_PREP` that does not land now returns `kIOReturnTimeout`
  (ETIMEDOUT), not `kIOReturnBusy`; NOSYNC still returns Busy. The wait is
  bounded, so `gl_test`'s 20 s alarm can run once the syscall returns.
- loud now prints ring base/size, RPTR/WPTR before and 1 ms after the kick,
  CP fault/status, the client space/context/root and the fence page address.

Expected proof (new lines):

```
adreno: loud: ring processor: base 0x..., 8192 words; RPTR N, WPTR N; about to send N..M; space 0x... context 0 root 0x...
adreno: loud: submission 1 queued ... completion at 0x1200040 <- 1 ...; RPTR now N, WPTR now M
adreno: loud: submission 1, 1 ms on: RPTR N+..., status 0x1, CP fault 0x0 ...; fence word 1
HakiosGPU: loud: fence 1 DONE after ... us (waited yes); fence word 1
gl_test: step 9: glFinish returned
```

If RPTR does not move and CP fault stays 0, the next check is the IB payload
itself (address/size) rather than the ring kick.

## 12. 2026-11-27: submissions 3+ stop after the CP's page tables move

Fences 1-2 land (word 2), then 3-4 are queued (`last submitted 4`) and the word
stays 2. The CP is no longer fetching: the ring has words after the point the
core last read, and the writer only wrote `CP_RB_WPTR` **once**, while the core
was still busy with 2. Two gaps are now closed:

- `ring_send()` ends with `dsb sy` after `CP_RB_WPTR`, so the pointer cannot
  reach the core before the ring words do.
- after sending, `gpu_submit()` checks `CP_RB_RPTR`; if the core has not taken
  the pointer at all (it was between submissions when the doorbell was written),
  it writes `CP_RB_WPTR` again, three tries 200 us apart. The client's wait stays
  the real bound.
- `space_switch()` used to wait only for the fence **word** before changing the
  SMMU tables; it now also waits until `CP_RB_RPTR == ring_sent`, so no queued
  IB of the old space can be fetched under the new client's tables (an SMMU
  fault there stops the CP before its completion packet).
- waits are per client: `clientClose` waits for `fLastFence` (this client's last
  submission), and `CPU_PREP` of a never-submitted buffer is done instead of
  waiting for the world's last fence. A repeated `NOT DONE` for one fence is
  logged once and then at most once a second.

New loud lines per submit: `IB i at 0x..., N words`, `ring tail: at:word ...`
(the last 8 dwords), `RPTR/WPTR` before and 1 ms after the kick, `CP status`,
`CP fault`, `CP int`, `protect`, and the client space/context/root.

Expected for a second and third completion:
```
adreno: loud: submission 3 ... completion at 0x1200040 <- 3 ...; RPTR now N, WPTR now M
adreno: loud: submission 3, 1 ms on: RPTR M, status 0x1, CP fault 0x0 ...; fence word 3
HakiosGPU: loud: fence 3 DONE after ... us (waited yes); fence word 3
adreno: loud: submission 4 ... completion at 0x1200040 <- 4 ...
HakiosGPU: loud: fence 4 DONE after ... us (waited yes); fence word 4
```
If RPTR reaches M but the word stays 2, the completion packet itself is being
executed in a space where 0x1200040 is not the scratch page; the space/root line
then names the mismatch.

## 13. 2026-11-27: the readback's empty indirect buffer

Readback sequence from Mesa's freedreno: `0x42 GEM_NEW` for the 16 KB staging
BO, `0x43 GEM_INFO`, `IOConnectMapMemory64` (map type N), `0x44 CPU_PREP` for the
render target, then a `0x46` submit (the blit/copy), then `0x47`/`0x44` waits.

The readback submit names a **zero-length command buffer** (Mesa asks for a
fence around a flush). We turned every `MSM_SUBMIT_CMD_BUF` into
`CP_INDIRECT_BUFFER` with `words = size/4`, so that one became an indirect
buffer of **length 0**: the core follows a packet that is not there and never
reaches the completion packet, so the fence word stops at the previous value
(2) while `last submitted` moves on (4). This is why it looked like a readback
wait that ignored its cap: the submit was made, but the core was stuck.

**Fix.** `submit()` now skips `size == 0` command buffers (loud:
`command buffer N is empty: no indirect buffer`). If nothing non-empty remains,
it returns `kIOReturnBadArgument` without consuming a fence. This also avoids
`CP_INDIRECT_BUFFER` with a zero length on any other path.

The readback wait is bounded as before (client waits 2 s, returns
`kIOReturnTimeout`); a submit-only BO with `fence == 0` is treated as done (no
wait on another client's last fence), and `clientClose` waits only this client's
`fLastFence`. New loud diagnostics for the next run: every BO (handle, GPU IOVA,
size, flags), the first 16 dwords of each IB, and one poll line every 100 ms with
the fence word and `CP_RB_RPTR`.

Expected final lines:
```
HakiosGPU: loud: command buffer 0 is empty: no indirect buffer
HakiosGPU: loud: IB 0 at 0x..., 42 words: ...
HakiosGPU: loud: fence 3 DONE after ... us (waited yes); fence word 3
gl_test: 1080 x 2400 drawn in ... ms, read back in ... ms; error 0; ... pixels inside the triangle
gl_test: the picture is on the panel (0x0), for 8 seconds
```

## 14. 2026-11-28: the zero-length-IB skip was the regression (reverted)

Build A (shared-space fixes, without `02ab450`) drew the triangle; Build B
(with it) completed but read back zeros. `02ab450`'s only behaviour change was
to drop `size == 0` command buffers and to refuse a submission left with no
non-empty IB. That was wrong: a zero-length `MSM_SUBMIT_CMD_BUF` is a valid
no-op indirect buffer (a fence-only submit); removing it from the stream made
the draw/fence sequence incomplete, the CP stopped at RPTR 147, and both
`glFinish` and the readback hit the 2 s timeout and returned zeros.

Both changes are reverted: every `MSM_SUBMIT_CMD_BUF` is emitted exactly as
Build A did, including a 0-length one, and there is no `count == 0` refusal.
The diagnostics from that commit are kept (they do not affect behaviour):
`cmd i: buffer, offset, size bytes/words, type, relocs`, every BO (handle,
GPU IOVA, size, flags), the first 16 IB dwords, one fence-word/RPTR poll per
100 ms, and a new handover line:

```
HakiosGPU: loud: handover: ring_at N, ring_sent N, CP_RB_RPTR N, CP_RB_WPTR N
```

Expected on the next boot: the triangle is drawn again, and the first submit
shows `cmd 0: ... size 0 bytes (0 words)` if a fence-only buffer follows the
real one, with RPTR advancing past 147 after the handover.

## 15. 2026-11-28: the CP rejects the client-only timing packets

The handover line shows the first client submission starts at ring word 123.
Its first packet is `ring_time(fence, 0)` = `CP_REG_TO_MEM` (0x3e), followed by
`CP_REG_WRITE` (type 4) for `CP_SCRATCH_REG2`; neither opcode is used by the
internal probe (its path ends at `CP_ME_INIT`/`CP_MEM_WRITE`/2D blits). The CP
consumed the whole ring (RPTR 147) and raised `CP int 0x1` =
`A6XX_CP_INT_CP_OPCODE_ERROR`, so the rejection is one of those first
client-only packets, not the IB doorbell or the fence address.

**Fix.** The client submit no longer emits `ring_time()` (start/end stats
counters) or the `CP_SCRATCH_REG2` write. The fence still comes from the
`CP_EVENT_WRITE` CACHE_FLUSH_TS packet; drawing and the readback are unaffected
(the stats are simply not updated for client submissions). The 1 ms probe now
reads `CP_SQE_STAT_ADDR = 1` / `CP_SQE_STAT_DATA` when `CP int & 1` and prints
`CP opcode error: SQE stat data 0x... (possible opcode)`, as Linux's
`a6xx_cp_hw_err_irq` does.

Expected:
```
adreno: loud: submission 1 ... 1 ms on: RPTR 147, status 0x1, CP fault 0, CP int 0, protect 0; fence word 1
HakiosGPU: loud: fence 1 DONE after ... us (waited yes); fence word 1
gl_test: 1080 x 2400 drawn in ... ms, read back in ... ms; error 0; ... pixels inside the triangle
```
If CP int 1 persists, the SQE line names the exact opcode to remove next.

## 16. 2026-11-28: the pipeline is busy, not the ring; invalidate the UCHE

`RBBM_STATUS 0xe51005` decodes (a6xx.xml.h) to `GPU_BUSY_IGN_AHB |
GPU_BUSY_IGN_AHB_CP | HLSQ_BUSY | SP_BUSY | VPC_BUSY | PC_DCALL_BUSY |
CP_BUSY | CP_AHB_BUSY_CX_MASTER`. With RPTR == WPTR and no HW/opcode fault,
the CP has fetched the ring and is **executing the IB** (a draw); it is stuck
before the fence because `gpu_exact=1` puts `CP_WAIT_FOR_IDLE` after the IB and
the SP/HLSQ/PC never go idle. The processor-side page-table switch
(`space_switch`) changes TTBR0 and TLBI, but the **UCHE (shader cache)** still
holds lines of the previous space; Linux's `a6xx_set_pagetable` emits
`CP_EVENT_WRITE CACHE_INVALIDATE` for exactly this reason, and our ring switch
does too. The submit path did not.

**Fix.** Before the IBs, the submit emits `CP_EVENT_WRITE CACHE_INVALIDATE`
(EVENT_CACHE_INVALIDATE 49), so the SP fetches the client's shaders. The 20 ms
probe now prints `CP_IB1_BASE`, `CP_IB1_DWORDS`, `CP_IB1_REM_SIZE`, RPTR,
status and the fence word every 1 ms, and the 1 ms status is decoded by block.

Expected:
```
adreno: loud: submission 1, 1 ms on: ... status 0x1 ...; fence word 1
HakiosGPU: loud: fence 1 DONE after ... us (waited yes); fence word 1
gl_test: 1080 x 2400 drawn in ... ms, read back in ... ms; error 0; ... pixels inside the triangle
```
If `CP_IB1_REM_SIZE` never decreases while `CP_IB1_BASE` is 0x204…, the IB was
not fetched after all; the new line names that case.

## 17. 2026-11-28: port the reference submit; shared space by default

The reference `hakios.adreno.c` (github xiongnemo/hakios-alioth, `drivers/gpu/`
and the Mi 10 overlay copy) has exactly this submit, verbatim:

```
ring_time(fence, 0);
CP_EVENT_WRITE 1  EVENT_INVALIDATE_DEPTH
CP_EVENT_WRITE 1  EVENT_INVALIDATE_COLOR
for each cmd: CP_INDIRECT_BUFFER_PFE (0x3f) count 3: addr_lo, addr_hi, words
if (gpu_exact) CP_WAIT_FOR_IDLE
ring_time(fence, 1); CP_REG_WRITE scratch2 = fence
CP_EVENT_WRITE 4  CACHE_FLUSH, fence page, 0, fence
```

It does **not** split an IB at 256 dwords or any boundary; `words` is the
client's `cmd.size / 4`, as ours. The difference is the **address space**: the
reference maps every buffer into the one shared SMMU space, while we defaulted
to one space per client. An IB that contains an indirect reference past dword
256 is then fetching a BO that is in the shared tables but not in the client's;
the CP stops with the opcode error and `REM_SIZE` frozen. So port the reference
arrangement: `gpu_spaces` now defaults to **0** (shared space), `gpu_spaces=1`
still opts into per-client spaces. The submit is restored to the reference's
packet order (timing/scratch packets included); our dc-civac polling and IRQ
bit remain. The loud `ring tail` prints 40 dwords, so the preamble and the IB
packets are visible in one look.

Expected:
```
adreno: loud: submission 1 ... 1 ms on: ... CP int 0 ...; fence word 1
HakiosGPU: loud: fence 1 DONE after ... us (waited yes); fence word 1
gl_test: 1080 x 2400 drawn in ... ms, read back in ... ms; error 0; ... pixels inside the triangle
```
If it still stops at 256 dwords with CP int 1, the IB itself contains a
secondary indirect buffer (the tail dump shows it), not a kernel packet-order bug.

## 18. 2026-11-28: systematic diff against the *working* alioth branch

The reference named in the task (`drivers/gpu/...` on `main`) is the **POCO X5
Pro / Adreno 642L** variant. The working phone's driver is on branch `alioth`,
`devices/redmi-k40/overlays/xnu/files/{bsd/dev/hakios.adreno.c,iokit/Kernel/hakios.gpu.cpp}`.
Full item-by-item comparison, with quotes and line numbers:
`hakios-port-ref/DIFF-SUBMIT.md`.

Outcome: our port is that file plus diagnostics (303 diff lines; gpu.cpp 668,
all safety/diagnostics). The submit was already verbatim. Differences found and
what was done:

* `ring_time(gpu_fence, 1)` and `ring_register(CP_SCRATCH_REG2, gpu_fence)` were
  missing after `CP_WAIT_FOR_IDLE` (alioth:4775-4776). **Restored** in
  `gpu_submit()`; the ring is now the reference's packet for packet.
* `gpu_spaces` default: the working `alioth` build uses **1** (per-client,
  `alioth:4175`); the 2026-11-28 commit's "reference is shared" was true only of
  `main`'s rewrite. Left at 0 (that removes the first-submit-in-a-new-space
  failure), but noted in the diff: shared space still stops at the IB.
* Reference's kept-GPU run is `gpu=1` -> steps **1..21** (no step 22 frame
  probe). Our `sweetgpu=22` runs step 22 and hands over at ring 123 (logs:
  `tmpwork/hkr.log:7810`, `hko.log:18120`) without resetting the ring or
  re-sending `CP_ME_INIT`. Next boot: `gpu=1 gpu_irq=1 adreno_loud=1`, then the
  same with `gpu_sleep_test=1`.
* No `CP_IB1_PREAMBLE_*` exists on a6xx (a6xx.xml: only shader EARLYPREAMBLE
  bits) — nothing missing. No `CP_PROTECT`/`GPR0`/`SET_MODE`/`SET_PROTECTED_MODE`
  in the working reference either; protection faults are CP int bit 4, not
  bit 0, so not added. Flush discipline is stronger than the reference's (we
  push every BO; it pushes only surfaces and cached buffers); allocation flags
  are identical (`0x4001011b` = write-combined).
* Loud diagnostics extended so the next run answers the 1 KiB question:
  64 IB dwords instead of 16, every `CP_INDIRECT_BUFFER` in the first 256 with
  its target/length, and `CP_ROQ_AVAIL_IB1` (0x949) in the 1 ms probe.

## 18. 2026-11-28: per-client space needs the ring's table update

Per-client run: the CP executes 448 of 1736 IB dwords, `CP_IB1_REM_SIZE 1288`,
`CP_ROQ_AVAIL_IB1 247` (ROQ full), `RBBM_STATUS 0xe51005` (HLSQ/SP/VPC/PC + CP
busy), no fault. The stop is **inside the IB**, at a draw command the front end
cannot drain: the CP's ROQ filled and it stopped feeding, so the fence behind
`CP_WAIT_FOR_IDLE` never ran. The IB offset is `1736 - 1288 = 448`.

`CP_SMMU_TABLE_UPDATE` was missing from the ring in the per-client path: only
this processor wrote TTBR0 (and TLBI). Linux's `a6xx_set_pagetable` and the
metal reference put `CP_SET_PROTECTED_MODE 0`, `CP_SMMU_TABLE_UPDATE` (0x53),
`CP_EVENT_WRITE CACHE_INVALIDATE`, `CP_SET_PROTECTED_MODE 1` before the IB. That
is now emitted whenever `gpu_spaces=1`:

```
CP_SET_PROTECTED_MODE 1: 0
CP_SMMU_TABLE_UPDATE 4: ttbr_lo, ttbr_hi|asid, 0, context
CP_EVENT_WRITE 1: CACHE_INVALIDATE
CP_SET_PROTECTED_MODE 1: 1
```

`gpu_spaces` defaults to 1 (device evidence: it executes and draws white
pixels); `gpu_spaces=0` remains the shared fallback. The 20 ms probe now prints
`IB1 0x… dwords N rem R (at IB dword N-R)`, and the recover watch prints
`HakiosGPU: loud: watch: ... recovering` before `hakios_gpu_recover()`, so a
hung client leaves a line even when the reset is refused.

Expected after the table update:
```
adreno: loud: submission 1 ... 20 ms on: IB1 0x… dwords 1736 rem 0 (at IB dword 1736); ... fence word 1
HakiosGPU: loud: fence 1 DONE after ... us (waited yes); fence word 1
gl_test: 1080 x 2400 drawn in ... ms, read back in ... ms; ... pixels inside the triangle (≈26%)
```
If REM_SIZE still freezes at 448, dump the dword there from the IB BO (the ring
tail and first 16 IB dwords are already printed) and compare it with Mesa's
expected draw packet.

## 19. 2026-11-28: table update off by default; UCHE invalidate before the IB

The ring `CP_SMMU_TABLE_UPDATE` sequence made the CP opcode-error again (it
stopped at IB dword 256), so it is not trusted: `gpu_table_update=1` gates it,
default **0**. `hakios-port-ref/DIFF-SUBMIT.md` records the Linux bytes and the
suspect fields: our word 3 was `core_space.context` where Linux writes
`CONTEXTBANK(0)` (the ASID is in word 1), and the protected-mode pair is not
proven on this core.

With it off, the default is the d1a9d38 behaviour: no CP error, ~448 IB dwords,
white corner. The remaining wedge is a front end that never drains (ROQ full,
HLSQ/SP/VPC/PC busy). A single, byte-verified
`CP_EVENT_WRITE 1 CACHE_INVALIDATE` is now emitted **before** the IBs, and loud
prints `preamble: CACHE_INVALIDATE at ring A..B` so its order is visible.

On a timeout the wait now prints `IB rem`, `ROQ_AVAIL_IB1`, and
`hung at IB dword N of M; dwords A..B: k:word ...` (eight around the stop) from
the first IB's kernel mapping, plus the existing recover-watch line.
