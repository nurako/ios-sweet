# Origin of the files in hakios-port/

All files below are copied verbatim from **xiongnemo/hakios-alioth**, branch
`alioth` (the repository's default branch), commit
`b6f69dfbb9a02c5441e3e7343f7ca660e9494859` (author date 2026-11-25).
They are the reference implementation of the working Adreno 650 stack on the
same phone (Xiaomi Mi 11X / Redmi K40 / POCO F3, SM8250-AC "kona").

| Local file | Upstream path | Blob |
| --- | --- | --- |
| `kernel/bsd/dev/hakios.adreno.c` | `devices/redmi-k40/overlays/xnu/files/bsd/dev/hakios.adreno.c` | `654f84e78a86f08664773f6e5e4163682c5649cf` |
| `kernel/bsd/dev/hakios.board.c` | `devices/redmi-k40/overlays/xnu/files/bsd/dev/hakios.board.c` | `cafdc4619b1d1270c6fbb79a869ef578701b873a` |
| `kernel/bsd/sys/hakios.board.h` | `devices/redmi-k40/overlays/xnu/files/bsd/sys/hakios.board.h` | `aee9b3c1e00b77a5370fd18ecff73aa4ac399e6a` |
| `kernel/bsd/sys/hakios.input.h` | `devices/redmi-k40/overlays/xnu/files/bsd/sys/hakios.input.h` | `f54a1ca7ea7bef1856a5dae802810250110d5274` |
| `kernel/iokit/Kernel/hakios.gpu.cpp` | `devices/redmi-k40/overlays/xnu/files/iokit/Kernel/hakios.gpu.cpp` | `332c97d799d17ce3de3113c3182341b560506443` |
| `kernel/iokit/Kernel/MiniIOSurface.h` | `devices/redmi-k40/overlays/xnu/files/iokit/Kernel/MiniIOSurface.h` | `175177b9cb7c325beebfb02926cadab68a55ffba` |
| `kernel/iokit/Kernel/MiniIOSurface.cpp` | `devices/redmi-k40/overlays/xnu/files/iokit/Kernel/MiniIOSurface.cpp` | `9009762731d35e58956743884304115337ff323f` |
| `kernel/iokit/Kernel/MiniDrivers.h` | `xnu/files/iokit/Kernel/MiniDrivers.h` | `1a35381fc1752035520b5688dd82b1c60ba7a970` |
| `reference-xnu-device.patch` | `devices/redmi-k40/xnu-device.patch` | (build integration reference) |
| `reference-gpu-conf.txt` | `drivers/gpu/conf` | `931c63af23f661246df0fde66e6e95b4d7a9fc47` |

## License

The upstream README states two licenses:

* the kernel pieces (under `xnu/` and derived from XNU) are a derivative work of
  Apple's XNU under the **Apple Public Source License 2.0** (APSL-2.0), with
  Apple's notices retained in the files;
* the device layer and the rest of the project (including
  `devices/<phone>/overlays/` and `drivers/`) are under the **MIT License**.

The GPU files copied here live under `devices/redmi-k40/overlays/xnu/files/`;
the upstream README classifies the device layer as MIT. `MiniIOSurface.*` and
`MiniDrivers.h` come from `xnu/files/` but, like the rest of the kernel, are
XNU-derived and carry APSL-2.0 obligations. Keep the upstream copyright and
license notices when these files become part of a shipped patch series. The
reference files themselves carry descriptive headers but no SPDX line, so this
note is the record of where they came from.

`hakios-port/adapter/` is new work for this tree (same licenses as the local
fork: see the repository LICENSE).
