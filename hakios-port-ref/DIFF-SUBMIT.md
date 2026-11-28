# Reference submit / per-client table update: byte comparison

## Linux a6xx_set_pagetable (drivers/gpu/drm/msm/adreno/a6xx_gpu.c)

```
OUT_PKT7(ring, CP_SET_PROTECTED_MODE, 1); OUT_RING(ring, 0);
OUT_PKT7(ring, CP_SMMU_TABLE_UPDATE, 4);
OUT_RING(ring, CP_SMMU_TABLE_UPDATE_0_TTBR0_LO(lower_32(ttbr)));
OUT_RING(ring, CP_SMMU_TABLE_UPDATE_1_TTBR0_HI(upper_32(ttbr)) |
                CP_SMMU_TABLE_UPDATE_1_ASID(asid));
OUT_RING(ring, CP_SMMU_TABLE_UPDATE_2_CONTEXTIDR(0));
OUT_RING(ring, CP_SMMU_TABLE_UPDATE_3_CONTEXTBANK(0));
OUT_PKT7(ring, CP_EVENT_WRITE, 1); OUT_RING(ring, CACHE_INVALIDATE);
OUT_PKT7(ring, CP_SET_PROTECTED_MODE, 1); OUT_RING(ring, 1);
```

Our attempted sequence (`gpu_table_update=1`) uses opcodes 0x5f and 0x53 and
four payload words, but word 3 is `core_space.context`; Linux puts
`CONTEXTBANK(0)` there (the context is the ASID in word 1). The device rejected
it with CP opcode error at IB dword 256, so it is **off by default**.

`CP_SET_PROTECTED_MODE` also belongs only around the SMMU update; it must not
remain on for the IB. Check with a working emitter before defaulting.

## Reference `hakios_gpu_submit` (working alioth build)

```
ring_time(fence, 0)
CP_EVENT_WRITE 1 EVENT_INVALIDATE_DEPTH
CP_EVENT_WRITE 1 EVENT_INVALIDATE_COLOR
for each cmd: CP_INDIRECT_BUFFER (0x3f), count 3: addr_lo, addr_hi, words
if (gpu_exact) CP_WAIT_FOR_IDLE
ring_time(fence, 1)
CP_REG_WRITE (type 4) CP_SCRATCH_REG2 <- fence
CP_EVENT_WRITE 4 CACHE_FLUSH, fence page +0x40, 0, fence
ring_send (CP_RB_WPTR)
```

No IB splitting: `words` is `cmd.size / 4` (Linux `submit_cmd.size / 4`).
`CP_SCRATCH_REG2` is 0x0885 (type-4 register write).
