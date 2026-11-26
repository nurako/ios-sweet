# Origin and licences

Reference: **xiongnemo/hakios-alioth**, commit
`78a91a456e50330ba3136127b911a4bbff30140f` (2026-11-26).

The repository splits its licence by directory (`LICENSE`):

* `xnu/` and everything under `xnu/files/` — Apple Public Source License 2.0
  (not used here; the kernel half of this port already lives in `hakios-port/`).
* everything else that is theirs — **MIT**. That covers `userland/src/`,
  `userland/mkeagl.py`, `tools/`, including the Mesa patches and the
  `hakios-drm` libdrm stand-in.

Files copied verbatim (MIT):

```
tools/mesa/hakios-drm/hakios.drm.c      -> hakios-drm/hakios.drm.c
tools/mesa/hakios-drm/xf86drm.h         -> hakios-drm/xf86drm.h
tools/mesa/{fd-gmem-zs-cpp,freedreno-darwin,freedreno-nomem,
            ir3-disk-cache-darwin,ir3-round-default,
            osmesa-es-profile,osmesa-hakios-copy,osmesa-import-keep}.patch
                                        -> mesa/patches/
userland/src/gl_test.c                  -> userland/gl_test.c
userland/src/gl_osmesa.c                -> userland/gl_osmesa.c
userland/src/hakios.gl.h                -> userland/hakios.gl.h
userland/mkeagl.py                      -> userland/mkeagl.py
userland/src/eagl_slots.txt             -> userland/eagl_slots.txt
```

Mesa itself is **not** vendored: `build-mesa.sh` downloads
`https://archive.mesa3d.org/mesa-25.0.7.tar.xz` (sha256
`592272df3cf01e85e7db300c449df5061092574d099da275d19e97ef0510f8a6`) and applies
the eight patches. Mesa is MIT.

Files written for this port (same MIT terms as the rest of ios-sweet's
userland):

```
build-mesa.sh, build.sh, build-userland-gpu.sh, install-root.sh
userland/com.hakios.gltest.plist
check-shims/                     declarations-only stubs for the host syntax check
userland.yml.patch               additive CI change
PORT-NOTES.md, TESTING.md, ORIGIN.md
```
