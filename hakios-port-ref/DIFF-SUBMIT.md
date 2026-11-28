# The client submit path: our port against the working reference

Systematic diff for the **1 KiB (256-dword) IB stall**: the CP starts the client IB,
`CP_IB1_REM_SIZE` goes 1736 -> 1480 and freezes, `CP int 0x1`
(`A6XX_CP_INT_CP_OPCODE_ERROR`), the fence word never lands.

Sources fetched 2026-11-28:

| what | where | lines |
| --- | --- | --- |
| **the working phone's driver** (Redmi K40 / POCO F3, alioth, Adreno 650) | `xiongnemo/hakios-alioth`, **branch `alioth`**, `devices/redmi-k40/overlays/xnu/files/bsd/dev/hakios.adreno.c` | 5410 |
| same, service | `.../iokit/Kernel/hakios.gpu.cpp` | 1888 |
| same, boot arguments | `.../devices/redmi-k40/boot.args` | 1 |
| `main`'s copy (the **642L/Yupik** variant, not this phone) | `drivers/gpu/hakios.adreno.c` / `hakios.gpu.cpp` | 3852 / 1218 |
| Mi 10 (umi, a650) device copy | `devices/xiaomi-mi-10/overlays/xnu/files/...` | 4119 / 1246 |
| Linux (what the reference itself ports) | `torvalds/linux` `a6xx_gpu.c`, `a6xx_catalog.c`, `adreno_pm4.xml`, `a6xx.xml` | — |
| Mesa 25.0.7 (what produces the IB) | tarball, `src/gallium/drivers/freedreno/a6xx/`, `src/freedreno/...` | — |

The task named `main`'s `drivers/gpu/...`; that file is the **POCO X5 Pro
(Adreno 642L)** variant. The phone here is alioth, and the working build is
`devices/redmi-k40` on branch **`alioth`** (the `main` path 404s for it). That is
the reference used below. Our tree is `hakios-port/kernel/...` on
`hakios-gpu2`.

Reproduce the diff:

```
curl -sfL -o /tmp/alioth.adreno.c https://raw.githubusercontent.com/xiongnemo/hakios-alioth/alioth/devices/redmi-k40/overlays/xnu/files/bsd/dev/hakios.adreno.c
diff -u /tmp/alioth.adreno.c hakios-port/kernel/bsd/dev/hakios.adreno.c
```

That diff is **303 lines and almost all of it is diagnostics**; the same for
`hakios.gpu.cpp` (668 lines, all safety/diagnostics except the flush loop in
§4). The submit path was already a verbatim port. What follows is item by item.

---

## 1. IB setup

### 1.1 `CP_RB_CNTL`, `CP_RB_BASE`, ring size — **same**

Reference (`alioth.adreno.c`):

```
2722  #define CP_RB_CNTL_VALUE        (12u | 2u << 8 | 1u << 27)      /* 2^12 pairs of words; do not copy the read position to memory */
3145      put(&gpu, "cp_rb_cntl", CP_RB_CNTL, CP_RB_CNTL_VALUE);
```

Ours: `hakios.adreno.c:2725` (identical define) and `:3150` (identical write);
`CORE_RING_ADDRESS 0x01000000`, `CORE_RING_SIZE 0x8000`, `RING_WORDS 8192` on
both sides. **No `CP_RB_WPTR_DELAY`, `CP_RB_VMID`, 64-bit/base form.**

### 1.2 `CP_IB1_BASE` / `CP_IB1_BUFSZ` / `CP_IB2` — **same (neither programs them)**

Neither driver ever writes `CP_IB1_BASE`, `CP_IB1_BUFSZ`/`CP_IB1_REM_SIZE` or
`CP_IB2_*`. They exist only as read-only diagnostics:

```
ref 3790  #define CP_IB1_BASE             GPU_WORD(0x0928)
ref 3791  #define CP_IB1_REM_SIZE         GPU_WORD(0x092a)
ref 5002      (uint64_t)rd(gpu.base + CP_IB1_BASE + 4) << 32 | rd(gpu.base + CP_IB1_BASE), rd(gpu.base + CP_IB1_REM_SIZE),
```

The IB1/IB2 engines are formed by the **CP itself** from the single
`CP_INDIRECT_BUFFER` packet (Linux `a6xx_submit` does the same,
`a6xx_gpu.c:526-533`; it only adds `CP_SET_MARKER` IB1LIST start/end when
*preemption* is enabled, `a6xx_gpu.c:519-522,566-567`, which neither driver
enables):

```
ref 4766-4772  for (uint32_t i = 0; i < count; i++) {
                   ring_command(CP_INDIRECT_BUFFER, 3);
                   ring((uint32_t)addresses[i]);
                   ring((uint32_t)(addresses[i] >> 32));
                   ring(words[i]);
               }
ours 4783-4788  identical
```

So the register holds the same value on both sides (`BLKSZ`=2, `RB_BUFSZ`=12,
`NO_UPDATE`=bit 27, per Linux's `MSM_GPU_RB_CNTL_DEFAULT`), and no field of it
can be the difference.

### 1.3 `CP_IB1_PREAMBLE_*` — **does not exist on a6xx; missing in both**

`a6xx.xml` (Mesa 25.0.7 `src/freedreno/registers/adreno/a6xx.xml`) has **no**
`CP_IB1_PREAMBLE` register at all; the only "preamble" names are shader
`EARLYPREAMBLE` bits (`a6xx.xml:3703,3829,3856,3895,3980,4114`). The working
reference programs nothing of the kind, and Linux's `a6xx_submit` does not
either. **There is nothing to add here.**

### 1.4 The IB stream itself — **same source in both trees**

The IB comes from Mesa 25.0.7 (both trees build `25.0.7`, `build-mesa.sh:27`,
reference `tools/mk-mesa.sh:42`) through the same `gl_test` and the same
`hakios.drm.c`. `CP_INDIRECT_BUFFER` size is `cmd.size / 4` on both sides
(reference `hakios.gpu.cpp:1530-1544`, ours `hakios.gpu.cpp:1730-1735`). So the
CP receives the same 1736-dword stream on the same phone.

---

## 2. CP microcode and `CP_ME_INIT`

### 2.1 SQE load — **same**

```
ref 2851  microcode = image_file("fw", gpu_firmware_name(GPU_FW_SQE), &size);
ref 2854  !block_new(&core_space, &core_sqe, CORE_SQE_ADDRESS, (uint32_t)size - 4, PTE_CORE | PTE_READ_ONLY) ||
ref 2858  memcpy((void *)core_sqe.memory, microcode + 4, size - 4);       /* the file's first word is not microcode */
ours 2856/2858/2863  identical
```

`CORE_SQE_ADDRESS 0x01100000`, `CP_SQE_INSTR_BASE` write, `CP_SQE_CNTL = 1`
(`ref 3147-3152`, ours identical). The image is the phone's own `a650_sqe.fw`
(both pull `a650_*` from `/vendor/firmware`); our copy is
`research/alioth-gpu/a650_sqe.fw`, 31632 bytes, microcode version word
`0x016dd093` -> `0x093`. Linux requires `>= 0x095` for a650
(`a6xx_gpu.c:1034-1044`) — the vendor kgsl runs it anyway, and **the reference
runs the same phone's file**, so this is not a port difference (recorded because
it is the one firmware fact worth knowing).

### 2.2 `CP_ME_INIT` — **bit for bit the same**

```
ref 3177-3187                                  ours 3183-3192
ring_command(CP_ME_INIT, 8);                   ring_command(CP_ME_INIT, 8);
ring(0x0000002f);                              ring(0x0000002f);
ring(0x00000003);   /* contexts */             ring(0x00000003);
ring(0x20000000);   /* error detection */      ring(0x20000000);
ring(0); ring(0); ring(0); ring(0); ring(0);   ring(0) x5
```

Linux `a6xx_cp_init` (`a6xx_gpu.c:901-928`) is the same eight words. Sent once,
at core start, not per submission, on both sides.

---

## 3. RBBM / CP cache and protection

| register / packet | reference | ours | verdict |
| --- | --- | --- | --- |
| `RBBM_INTERFACE_HANG_INT_CNTL` | `3128  put(..., 1u<<30 \| 0x1fffff)` | same | same |
| `CP_APRIV_CNTL` | `3135  1<<6\|1<<5\|1<<3\|1<<2\|1<<1` | same | same |
| `CP_CHICKEN_DBG` | `3132  1` | same | same |
| `RBBM_INT_0_MASK` | written only by `gpu_irq_on()`: `3506  wr(..., RBBM_INT_CACHE_FLUSH_TS)` | `3512` identical | same |
| `CP_PROTECT_CNTL` / `CP_PROTECT_REG_n` | **never written**; `CP_PROTECT_STATUS` read only (`2700`, `2822`, `3161`, `5000`) | never written | **missing in both** |
| `CP_SET_PROTECTED_MODE` | never emitted | never emitted | missing in both |
| `CP_SET_MODE` in the ring | never emitted | never emitted | same (Mesa's IB emits `CP_SET_MODE 0` itself, `fd6_emit.cc:1104`) |
| `RBBM_GPR0_CNTL` | never used | never used | missing in both |
| `CP_EVENT_WRITE` before the IBs | `INVALIDATE_DEPTH (0x18)`, `INVALIDATE_COLOR (0x19)` (`4761-4765`) | same (`4778-4782`) | same |
| UCHE `CACHE_INVALIDATE (49)` | only in `ring_switch()` (`4303`, `gpu_ring_switch=1`, **off**) | same (`4324`) | same |
| `CP_SCRATCH_REG2` write | `4776  ring_register(CP_SCRATCH_REG2, gpu_fence)` | **was absent**, restored 2026-11-28 (§7) | *differs, fixed* |

Linux does program the a650 protection table (`a6xx_catalog.c:543-584`
`a650_protect_regs[]`, 48 entries; `a6xx_gpu.c:723-745`
`a6xx_set_cp_protect()` sets `CP_PROTECT_CNTL` and `CP_PROTECT(0..47)`), but the
**working reference deliberately leaves it out** ("less what only matters once it
draws (clock gating, the protection of registers against user programs'
commands, counters)", `alioth.adreno.c:2666-2670`), and its games run. A
protection violation raises `CP_INT_CP_REGISTER_PROTECTION_ERROR` (bit 4), never
`OPCODE_ERROR` (bit 0), so adding the ranges **cannot** explain or fix this
stall and could add a new fault. **Not implemented, on purpose** — see §8.

---

## 4. Memory / flush discipline per submit

### 4.1 The primitive — **same**

```
ref 1287-1292  to_memory(): for (line = start & ~63; line < start + size; line += 64) "dc civac"; dsb sy
ours 1287-1292  identical (byte for byte)
```

`hakios_gpu_to_memory()` is a thin wrapper on both sides
(ref `hakios.adreno.c:3377`, ours `:3441`).

### 4.2 Buffer allocation — **same**

```
ref hakios.gpu.cpp:1162  IOBufferMemoryDescriptor::inTaskWithOptions(kernel_task,
                             kIODirectionInOut | kIOMemoryKernelUserShared |
                             (gGPUCached ? 0 : kIOMapWriteCombineCache), size, PAGE_SIZE);
ours hakios.gpu.cpp:1326  identical
```

The loud log shows descriptor flags `0x4001011b`: cache field `0x40000000` =
`kIOWriteCombineCache << kIOMapCacheShift` (**write-combined**,
`IOMapTypes.h:44-62`), so both the kernel and client mappings are
normal-non-cacheable and CPU writes reach DRAM without a `dc civac`. `gGPUCached`
defaults to 0 on both sides.

### 4.3 Which buffers are flushed — **differs (ours is stronger)**

Reference `submit()` flushes **only IOSurface-backed buffers** (and only when
their seed moved or their interval expired) plus buffers when `gpu_cached=1`;
non-surface command buffers are not pushed:

```
ref hakios.gpu.cpp:1471-1526
    for (each bo) { if (b->surface) { conditional push } else if (!b->seen || !gGPUCached) continue;
                    hakios_gpu_to_memory(b->kernel, b->size); }
    hakios_gpu_to_memory(NULL, 0);          /* barrier */
```

Ours adds a second loop that pushes **every** named BO, command buffers
included (`hakios.gpu.cpp:1698-1714`, "What the program wrote through its mapping
must be in memory…"). Whole `b->size`, not the first page. This is strictly more
cache maintenance than the reference does; it cannot cause a stall.

### 4.4 `prepare`/`complete` — **missing in both**

Neither tree calls `IOMemoryDescriptor::prepare()`/`complete()` or any
`kIODirection*` sync call (grep on both); the only direction use is
`kIODirectionInOut` at allocation and `IOSubMemoryDescriptor::withSubRange`.
Nothing to port.

### 4.5 What the CP sees of the IB memory

Both map the BO page by page into the same SMMU tables, 4 KiB pages:
`ref newBuffer hakios.gpu.cpp:1013-1032`, ours `:1180-1194`. The reference maps
`phys != 0`; ours adds `hakios_gpu_phys_ok()` and a 250 ms budget, which refuse
the **whole** buffer if one run fails — never a partial mapping. The IB in the
loud log is at `0x20488000`, 4 KiB aligned, 1736 dwords = 6944 B, inside a
16 KiB BO — two 4 KiB pages, both mapped.

---

## 5. Boot arguments and probe steps — **this is where the working and our runs differ**

Reference's own `boot.args` (one line, `devices/redmi-k40/boot.args`):

```
gpu=1 ... gpu_sleep=1 gpu_recover=1 ... gpu_push_write=0 gpu_irq=1 gpu_push_gpuonly=1 gpu_wrap=1
```

and `hakios_adreno_init()` turns that into:

```
ref 5303-5317
    if (!PE_parse_boot_argn("adreno", &last_step, ...)) {
        if (!(PE_parse_boot_argn("gpu", &only, ...) && only) || !start_by_itself()) return;
        by_itself = true;
        last_step = 21;                          /* <-- stops BEFORE the frame probe */
        skip_steps = umi_a650 ? 0 : (1<<10|1<<11|1<<12);
        pause_ms = 0; watch_seconds = 0;
        keep = 1;
    }
```

Ours has the same code (`hakios.adreno.c:5383-5394`), but **our runs used
`sweetgpu=22 sweetgpukeep=1`**, which runs **step 22, `step_frame()` (the 2D fill)
before the handover**. The reference never runs step 22 in a kept GPU.

Evidence in our own logs (`tmpwork/hkr.log`, `hko.log`): the first client submit
begins at **ring word 123** (`hkr.log:7810`, `hko.log:18120`), which is exactly
what the 2D fill of step 22 leaves behind (`step_frame()` writes ~107 ring words);
with the reference's `gpu=1` the first client submit would start at ring ~16
`CP_ME_INIT` plus `CP_SET_SECURE_MODE` and `CP_MEM_WRITE` from `step_core_start()`/
`step_core_commands()`). The keep path then only clears the scratch page; it does
**not** reset the ring or re-send `CP_ME_INIT`:

```
ref 5352-5360, ours 5431-5455: if (keep && done >= 21 && core_runs) { gpu_free[0]...; bzero(core_scratch, 4096); }
```

A sleep/wake cycle does reset it (`gpu_wake_core()` sets `ring_at = ring_sent = 0`
and re-runs steps 14-17,20,21), and the
reference exposes exactly that as a boot arg (`gpu_sleep_test=N`, `ref 5355-5360`).
This is the cheapest discriminator available on the next boot.

### 5.1 `gpu_spaces` — **differs, and our commit's premise was inverted**

```
ref alioth.adreno.c:4175     uint32_t value = 1;     /* per-client space by default */
ours hakios.adreno.c:4190    uint32_t value = 0;     /* shared */
```

The branch's 2026-11-28 commit changed the default to 0 "because the reference
runs one space". That is true of `main`'s `drivers/gpu` rewrite, but **not of the
working `alioth` build**: its `boot.args` passes no `gpu_spaces`, so it takes
`value = 1` and switches TTBR0 per client. (The real per-client failure seen in
`tmpwork/hkr.log:8070-8072` is the **first submit into a newly created space**;
submissions in the boot-time space worked. `gpu_spaces=0` removed that specific
failure, and the shared-space runs still stop later, see §8.)

### 5.2 Other defaults — **same**

`gpu_exact = 1` (`ref 3805`, ours `3814`), `gpu_cached = 0`, `gpu_irq` only when
passed, `gpu_wrap` 0 in both trees but set to 1 by the reference's boot args
(ours defaults it to 1, `hakios.gpu.cpp:263`).

---

## 6. Other submit-path differences

* **End of the submission** — reference has, after `CP_WAIT_FOR_IDLE`:

  ```
  ref 4775  ring_time(gpu_fence, 1);
  ref 4776  ring_register(CP_SCRATCH_REG2, gpu_fence);
  ```

  Ours had dropped both on 2026-11-28 when the CP was thought to be refusing the
  timing packets. They are after the IB and the `CP_WAIT_FOR_IDLE`, so they
  cannot be the 1 KiB stop, but they are part of the reference's ring and have
  been **restored** (§7).
* **Kick** — reference: `ring_send()` ends at the single `CP_RB_WPTR` write
  (`ref 2796-2797`). Ours adds `settle()` (`:2801`) and a 3-try WPTR re-write loop
  in `gpu_submit()` (`:4827-4838`). Ours only; harmless (writes after the core
  already has the pointer).
* **Space switch** — reference waits for the fence only (`ref 4251-4268`); ours
  additionally waits for `RPTR == ring_sent` (`:4278-4282`). Ours only; disabled
  with `gpu_spaces=0`.
* **Ring window** — `gpu_ring_switch=1` (CP_SMMU_TABLE_UPDATE in the ring,
  `ref 4290-4307`, ours `4308-4325`) is off by default in both. Not in play.
* **Diagnostics we added and the reference lacks**: `CP_SQE_STAT_ADDR/DATA`
  decode on `CP int & 1` (`:4853-4860`), the 1 ms IB1 probe (`:4864-4871`),
  `hakios_gpu_report()` decode, `gpu_recover`, patience cap, the 64-dword IB dump
  and nested-IB walk in `hakios.gpu.cpp:1760-1790`.
* **Service side** — same ioctl semantics; `gemInfo` returns `b->address` for
  `MSM_INFO_GET_IOVA` on both (`ref hakios.gpu.cpp:1362-1380`, ours `:1530-1548`),
  which is what Mesa puts into relocations (including nested IBs).

---

## 7. What was changed in this pass

1. `hakios.adreno.c:4798-4799` — restored the reference's two end-of-submit
   packets (`ring_time(gpu_fence, 1)`, `ring_register(CP_SCRATCH_REG2,
   gpu_fence)`). The ring is now the reference's packet for packet (plus loud
   prints, which are conditional).
2. `hakios.adreno.c:2705,4868` — the loud probe also reads
   `CP_ROQ_AVAIL_IB1` (bits 16-31), because `CP_IB1_REM_SIZE` excludes what the
   prefetcher already holds in the ROQ (`crashdec.c`: `rem += CP_ROQ_AVAIL_IB1
   >> 16`). That separates "the CP consumed 256 dwords" from "the prefetcher
   took 256 dwords and failed on the first".
3. `hakios.gpu.cpp:1760-1790` — the loud IB dump now prints **64** dwords
   (was 16) and walks the first 256 for type-7 `CP_INDIRECT_BUFFER` packets,
   printing each target and length. Freedreno chains the gmem ring to its restore
   and draw rings (`fd6_emit.cc:1151-1163`, `fd6_gmem.cc:866,996`); if the stop is
   at a nested IB, its target address is now in the log.

`xnu/patches/0200-hakios-gpu.patch` was regenerated from the sources and
`tools/check-patch-sources.sh` says `9 file(s) match their sources, 9 skipped`.
Both files compile (`xnu-cc.py` over a buildtree): `0 of 2 files failed`.

---

## 8. Ranked: what can explain a 1 KiB IB stall

1. **The handover state: step 22 ran before the GPU was kept.**
   The reference's working run is `gpu=1` -> steps 1..21, keep; ours is
   `sweetgpu=22` -> step 22's 2D fill runs and the ring is handed over at word
   123 with the CP fresh from an `CP_BLIT`/`RB_2D_*`/`CP_SET_MARKER(12)` sequence
   and **without** re-running `CP_ME_INIT` or resetting the ring. This is the
   only difference that changes what the CP has executed immediately before the
   client's first IB; every packet-level difference is either identical or after
   the IB. **Cheap test: boot `gpu=1 gpu_irq=1 adreno_loud=1` (no `sweetgpu`), or
   add `gpu_sleep_test=1`, which resets the ring and re-runs steps 20/21 before
   handover.** If the stall disappears with either, this is it.
2. **How the IB is presented to the prefetcher, not its dwords.**
   256 dwords is one CP IB1 prefetch/ROQ chunk, `CP_SQE_STAT_DATA` was 0 (a zero
   word read as an opcode), and `CP_IB1_REM_SIZE` counts only delivered words.
   Our ring and IB packets now match the reference byte for byte, so a
   *remaining* difference has to be in the address translation or the physical
   pages of the IB BO, not the stream. The new dump (§7.3) plus the ROQ count
   (§7.2) decides this on the next run: if the stop is at a nested
   `CP_INDIRECT_BUFFER`, its target is the thing to check in the SMMU tables; if
   the first 64 dwords themselves are wrong, it is the IB BO's mapping/cache.
   Note: both sides are write-combined (`0x4001011b`), and ours flushes *more*
   than the reference, so a stale-cache explanation would have to come from
   somewhere other than this source diff.
3. **Per-client SMMU space.** The working reference actually defaults to
   `gpu_spaces = 1` (`alioth.adreno.c:4175`), and its own logs show the failure
   mode we hit first: the **first submission in a newly created space** stops the
   CP (`hkr.log:8070-8072`, `RPTR` reached `WPTR`, IB fetched, `CP int 0x1`). We
   keep `gpu_spaces=0` because that failure is gone, but shared space does not
   fix the later stop (`hko.log:18120` is a shared-space run with the same IB),
   so this is a second bug, not the 1 KiB one.

Below those: 4. the two missing end-of-submit packets (fixed; cannot cause an
opcode error — they are after the IB), 5. `CP_PROTECT`/preamble/GPR0/SET_MODE
(absent in the working reference; a6xx has no IB preamble registers; protection
faults are bit 4, not bit 0).

## 9. Next boot

```
gpu=1 gpu_irq=1 adreno_loud=1            # steps 1..21, keep; reference-exact handover
```

If it still stops, the same boot with `gpu_sleep_test=1` (reset before handover),
and read:

* `adreno: loud: submission N, k ms on: IB1 base … rem … (ROQ …)` — ROQ > 0 means
  the prefetcher took the 256, not the SQE;
* `HakiosGPU: loud: IB 0 at …, 64 words: …` and the `CP_INDIRECT_BUFFER at +k ->
  0x…` lines — the packet and target at the stop;
* `adreno: loud: CP opcode error: SQE stat data …`.

Do not add `CP_PROTECT`/preamble registers to chase this: neither exists in the
working reference, and neither can produce `CP_INT_CP_OPCODE_ERROR`.
