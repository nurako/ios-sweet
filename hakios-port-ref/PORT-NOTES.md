# 2026-11-27 (hakios-ref): the Adreno submit path against xiongnemo/hakios-alioth

The reference paths named in the task no longer exist on `main`
(`devices/redmi-k40/...` is 404).  The same two files are in the tree as:

* `drivers/gpu/hakios.adreno.c` (4110 lines, current `main`)
* `drivers/gpu/hakios.gpu.cpp` (1246 lines, current `main`)
* `devices/xiaomi-mi-10/overlays/xnu/files/{bsd/dev/hakios.adreno.c,iokit/Kernel/hakios.gpu.cpp}`
  (the device copy; same mechanics, 4119/1246 lines)

The `devices/redmi-k40` snapshot at commit `b6f69df` (the source of our
`hakios-port/` import, see `hakios-port/ORIGIN.md`) is a different, older
variant: it has `gpu_spaces`, `gpu_space_new()`, `space_switch()` and
`hakios_gpu_submit_in()`.  Current `main` has none of those and keeps every
client in one address space.  That is the difference that matters here; quoting
current `main` line numbers below.

## 1. Ring setup and kick

Reference (`drivers/gpu/hakios.adreno.c`):

```
2404  #define CORE_RING_ADDRESS       0x01000000u
2405  #define CORE_RING_SIZE          0x8000u         /* Linux's; 8192 words */
2446  #define CP_RB_CNTL_VALUE        (12u | 2u << 8 | 1u << 27)      /* 2^12 pairs of words; do not copy the read position to memory */
2512  ring_send(void)
2513  {
...
2520      ring_sent = ring_at;
2521      wr(gpu.base + CP_RB_WPTR, ring_at);
2522  }
```

`CP_RB_CNTL_VALUE` is Linux's `MSM_GPU_RB_CNTL_DEFAULT` for its 32 KiB ring:
`BUFSZ(ilog2(32768/8)) = 12`, `BLKSZ(ilog2(32/8)) = 2`, plus `NO_UPDATE`
(`drivers/gpu/drm/msm/msm_gpu.h`).  We already had the same 0x8000 size and the
same value (`hakios.adreno.c:2722`); no `CP_RB_WPTR_DELAY`, no 64-bit/base form
of `CP_RB_WPTR`, and **no `dsb` after the kick, no re-kick loop** in the
reference.

Our gpu2 additions had added `settle()` after the `CP_RB_WPTR` write, a
three-try re-kick loop in `gpu_submit()`, and an `RPTR == ring_sent` drain in
`space_switch()`.  None is in the reference.  Removed:
`ring_send()` now ends at the single `CP_RB_WPTR` write
(`hakios.adreno.c:2799-2800`), and `gpu_submit()` calls `ring_send()` once
(`hakios.adreno.c:4780`).

## 2. Submission shape

Reference (`hakios.adreno.c:3485-3493`):

```
    for (uint32_t i = 0; i < count; i++) {
        ring_command(CP_INDIRECT_BUFFER, 3);
        ring((uint32_t)addresses[i]);
        ring((uint32_t)(addresses[i] >> 32));
        ring(words[i]);
    }
```

So: one `CP_INDIRECT_BUFFER` (0x3f) packet of three dwords (64-bit IOVA, word
count), one per command buffer, in order; `CP_INDIRECT_BUFFER_PFD` is not used,
IB2 is not programmed (the report reads `CP_IB1_BASE/CP_IB2_BASE` only), and the
3D core forms IB1/IB2 itself.  `hakios.gpu.cpp:954-959` builds the same
`addresses[]`/`words[]` from `MSM_SUBMIT_CMD_BUF` (`size / 4`, `submit_offset`
added to `b->address`).

Ours was already identical (`hakios.adreno.c:4758-4763`).  No change.

## 3. Fence and completion

Reference:

```
3174  #define GPU_FENCE_AT            0x40            /* in the scratch page */
...
3497      ring_time(gpu_fence, 1);
3498      ring_register(CP_SCRATCH_REG2, gpu_fence);
3499      ring_command(CP_EVENT_WRITE, 4);
3500      ring(EVENT_CACHE_FLUSH);
3501      ring(CORE_SCRATCH_ADDRESS + GPU_FENCE_AT);
3502      ring(0);
3503      ring(gpu_fence);
```

The TS target is the kernel's own scratch page
(`CORE_SCRATCH_ADDRESS 0x01200000` + 0x40 = `0x1200040`), not a client BO, and
the value is the sequence number; `++gpu_fence` with zero skipped is at
3480-3481.  `EVENT_CACHE_FLUSH` (0x04) is bit 0 of the event, so the write
passes the cache.  Completion is polled by cleaning+invalidating the word
before reading it:

```
3384  hakios_gpu_done(uint32_t fence)
3386      volatile uint32_t *word = (volatile uint32_t *)(core_scratch.memory + GPU_FENCE_AT);
3388      to_memory((vm_offset_t)word, 4);
3389      return (int32_t)(*word - fence) >= 0;
```

`to_memory()` is `dc civac` over the line then `dsb sy` (1286-1292).  The
reference has no interrupt path; waiting is `hakios.gpu.cpp:190-213` asking every
`GPU_ASK_AGAIN_US` (50 us).  Our driver keeps the optional `gpu_irq=1` wake as a
diagnostic, but the fence page, seqno, cache flush and invalidate are the same.
No change.

## 4. Space switching / SMMU — the actual divergence

Current reference has one address space for everything
(`hakios.gpu.cpp:24-27`):

```
 * Not here yet: interrupts (waiting is asking again five times a millisecond), more than one
 * program's worth of care (every client's buffers are in the one address space; a client that
 * goes takes its own away), recovery of a GPU that has stopped answering ...
```

There is no `space_switch()`, `gpu_space_new()`, `space_load()` or
`hakios_gpu_submit_in()` in either reference file; buffers are mapped with
`hakios_gpu_map()` into the same tables (`hakios.adreno.c:3349`,
`hakios.gpu.cpp:633`), and `hakios_gpu_submit()` is called directly
(`hakios.gpu.cpp:959`).

Our import (redmi-k40 `b6f69df`) had the per-client experiment on by default.
On the phone the first submission **in a newly created client space** stopped
the command processor.  The loud log (`tmpwork/hkr.log:8070-8072`,
`tmpwork/hkt.log:4062-4073`) is unambiguous:

```
adreno: loud: submission 3 queued at ring 195..195: 1 command buffers, completion at 0x1200040 <- 3 ...; RPTR now 171, WPTR now 195
adreno: loud: submission 3, 1 ms on: RPTR 195, status 0x800005, CP fault 0, CP int 0x1, protect 0; fence word 2
```

`RPTR` **did** reach the new `WPTR` (195); `CP int 0x1` is
`A6XX_CP_OPCODE_ERROR` (`a6xx_reg.h`: bit 0 of `CP_INTERRUPT_STATUS`).  The CP
was not missing the doorbell: it fetched the ring and stopped on a packet in
the new space's IB (`CP_IB1_REM_SIZE`: 1480 of 1736 words left).  The new space
was created at `root 0x1da743000` right before this submission; the earlier
client was in `root 0x105ae6000`.

Fix: `gpu_spaces` now defaults to **0** (`hakios.adreno.c:4179-4185`), so
`hakios_gpu_space_new()` returns NULL, `fSpace` is NULL, every client's buffers
map into `core_space`, and the core's TTBR0 is never moved behind a submission
— exactly the current reference.  `gpu_spaces=1` still selects the old
experiment for anyone who wants to debug it.  The `space_switch()` RPTR drain
was removed as well (`hakios.adreno.c:4262-4272`), so the per-client path is
the reference's fence-only wait if it is ever turned on.

## 5. Things the reference has that we lacked, and the reverse

* `CP_PROTECT` ranges: **not used** by the reference (`CP_PROTECT_STATUS` is
  only read in reports, e.g. 3518); we do not add any.
* `CP_ME_INIT`: once, at core start (`2792 ring_command(CP_ME_INIT, 8)`), not
  per submission; ours is the same.
* `RBBM_GPR0` bookkeeping: **not used** by the reference.
* `CP_RB_WPTR_DELAY`, `CP_RB_VMID`, IB2 programming: **not used**.
* The one reference mechanic we now use **less** of is the old per-client
  space; the one we added is a diagnostic the reference lacks: on a stuck
  submission `hakios_gpu_report()` now decodes `CP_INTERRUPT_STATUS` bit 0 and
  reads `CP_SQE_STAT_ADDR/DATA` (Linux `a6xx_cp_hw_err_irq`) to name the
  refused opcode (`hakios.adreno.c:2701-2703, 5015-5019`).  That is what proves
  the next failure is in the IB and not in the ring.

## What changed

* `hakios-port/kernel/bsd/dev/hakios.adreno.c`
  * `gpu_spaces` default 1 -> 0; comment at 4159-4169 now says one space, as the
    reference.
  * `ring_send()`: removed `settle()` after `CP_RB_WPTR`.
  * `gpu_submit()`: removed the three-try `CP_RB_WPTR` re-kick loop.
  * `space_switch()`: removed the `RPTR == ring_sent` drain; fence wait only.
  * `hakios_gpu_report()`: decode `CP_INTERRUPT_OPCODE` and print
    `CP_SQE_STAT_DATA`.
* `hakios-port/kernel/iokit/Kernel/hakios.gpu.cpp`: unchanged; with `fSpace ==
  NULL` it already maps and submits into the shared space.
* `sweet_gpu.c`: untouched.

## Expected proof on a third and fourth submission

With `adreno=22 adreno_keep=1 gpu_irq=1 adreno_loud=1` and no `gpu_spaces`:

```
adreno: loud: ring processor: base 0x1000000, 8192 words; RPTR 195, WPTR 195; about to send 195..208; space 0x0 context 0 root 0x...
adreno: loud: submission 3 queued at ring 195..219: 1 command buffers, completion at 0x1200040 <- 3, interrupt asked for (CP_EVENT_IRQ); RPTR now 195, WPTR now 219
adreno: loud: submission 3, 1 ms on: RPTR 219, status 0x1, CP fault 0, CP int 0, protect 0; fence word 3
HakiosGPU: loud: fence 3 DONE after ... us (waited yes); fence word 3
adreno: loud: submission 4 ... completion at 0x1200040 <- 4 ...
adreno: loud: submission 4, 1 ms on: ... CP int 0 ...; fence word 4
HakiosGPU: loud: fence 4 DONE after ... us (waited yes); fence word 4
```

There should be **no** `adreno: gpu: a client has a space of its own` line.
If a space line still appears, `gpu_spaces=1` was passed.

## Verification

* `XNU_CC_CLANG=/usr/bin/clang python3 tools/xnu-cc.py <ci.log> /tmp/opencode/bt-ref
  bsd/dev/hakios.adreno.c iokit/Kernel/hakios.gpu.cpp` -> `0 of 2 files failed`.
* `tools/check-patch-sources.sh` -> `9 file(s) match their sources, 10 skipped`.
* On a CI tree copy: reverse `0501..0200`, then apply `0200, 0300, 0400, 0500,
  0501` in order -> all `git apply --check` pass; patched
  `bsd/dev/hakios.adreno.c` sha256 =
  `6ff2562d8479eeda97a57a92421987cc35de3a5b9d83b70fe11b3b0241d1f8a4`.
