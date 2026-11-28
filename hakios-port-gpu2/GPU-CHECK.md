# xiongnemo/ios-gpu-check as an oracle for the 256-dword IB stall

Upstream: <https://github.com/xiongnemo/ios-gpu-check>, MIT, pinned at
`7c73b33` (2026-11-22). One `main.m` (4585 lines), `Info.plist`,
`Entitlements.plist` (empty), `build.sh`, `mkicon.py`. The README says it is
frozen and the GPU page moved to `xiongnemo/ios-system-check`; this is still
the version written for the alioth port.

## 1. What it is — and what it is not

It is a **GL client**, not a KGSL client. It contains no `ioctl`, no
`libdrm`, no buffer allocation, no command buffer, no fence word. Its whole
interface to the GPU is:

```
OpenGLES.framework -> EAGLContext -> libhakios.gl.dylib (eagl.c)
                   -> OSMesa -> Mesa 25.0.7 / freedreno -> hakios.drm.c -> HakiosGPU
```

`libhakios.gl.dylib` registers through `-[EAGLContext getMacroContextPrivate]`
(`userland/eagl_slots.txt`), and `gl_osmesa.c` makes every `EAGLContext` an
**OSMesa** context. So on this image it would walk exactly the path `gl_test`
walks, one layer higher.

That kills the hope of a second submission pattern, but the comparison is
still useful, because it is *exact*:

| piece | reference (alioth) | this tree |
|---|---|---|
| Mesa | 25.0.7 | 25.0.7 |
| 8 mesa patches | — | identical except `osmesa-hakios-copy.patch` adds one prototype (`-Wmissing-prototypes`) |
| `hakios-drm/hakios.drm.c` | 280 lines | 375: **only** `hakios_drm_map()` differs (page probe + logging); submit/`GEM_NEW`/`GET_PARAM` identical |
| `gl_test.c` | the author's | same file + our `step`/watchdog/SIGBUS lines |

So the `CP_INDIRECT_BUFFER` the CP receives is produced by the same code in
both trees. **A client-side submission difference cannot explain the stall**;
what differs is the kernel (`0200-hakios-gpu.patch`) and the *content* of the
command stream. `ios-gpu-check` varies the content, cheaply and with names.

## 2. What it actually exercises

83 tests, each creating a **fresh context** (`my_initWithAPI` calls
`hakios_gl_create` every time, up to 8 live) and printing
`gpucheck: <id> running` before, `<id> PASS|FAIL <detail>` after, to
`/dev/console` and `Documents/gpucheck.log`. A crash records the signal; a
watchdog (8 s) records `HUNG`; the next launch skips the culprit. On our
image the automatic bottleneck is `initWithAPI` accepting only 2 and 3, so
`ctx.es1` fails immediately — ES2/ES3 are what we get.

Off-screen, no window server needed (the part worth running first):

* `ctx.es2`, `ctx.es3` — renderer/version/GLSL, limits, compressed formats,
  full extension list, sharegroup visibility (`ctx.sharegroup`).
* `es{1,2,3}.fbo.d16`, `.d24s8`, `.depth`, `.blend`, `es3.glsl300` — 64×64
  RGBA8 renderbuffer + depth, one triangle, `glReadPixels` of centre/corners.
* `es2.finish` — `glFinish` idle, then 100 full 512×512 triangles: submitted
  and finished times. **This is the direct fence oracle**: it fails if either
  takes ≥ 1 s.
* `es2.fence`, `es3.fence` — 10 draws, `glFenceSync`, `glFlush`, then
  `glClientWaitSync` with a 1 s timeout, printing which result and how long.
* `es3.mapbufferrange`, `es2.mapbuffer` — the CPU_PREP/map path that gave us
  SIGBUS.
* `es3.mrt`, `es3.instanced`, `es3.vao`, occlusion queries, `tex.*` formats,
  `es*.screen` (CAEAGLLayer + `presentRenderbuffer:atTime:`, MSAA, discard),
  GLKit, CADisplayLink, Core Image, Metal, SceneKit.

Compared with `gl_test` (ES2, one texture, one FBO, one triangle,
`glFinish`, `glReadPixels`, `0x7f`), that adds: ES3 cores, native fences as a
separate path from `glFinish`, MRT (several render targets in one draw),
buffer mapping, MSAA resolve, 30-frame present loops, and repeated
context/screen create+destroy. No compute queues (its `metal.compute` is
Metal, which our image does not have), and no new `MSM_SUBMIT` types.

## 3. Build recipe

The app is trivial to build; the SDK is the only requirement. Both wrappers
here take our usual `IOS_SDK` / `CLANG` and do not touch the workflow.

```
git clone https://github.com/xiongnemo/ios-gpu-check /tmp/opencode/ios-gpu-check
IOS_SDK=$THEOS/sdks/iPhoneOS16.5.sdk \
  hakios-port-userland/tools/gpu-check/build-gpu-check.sh
# -> /tmp/opencode/ios-gpu-check/build/GPUCheck.ipa
```

It is a single clang invocation plus `ldid -S Entitlements.plist`:
`-target arm64-apple-ios15.0 -fobjc-arc -framework UIKit Foundation
CoreFoundation CoreGraphics QuartzCore OpenGLES GLKit CoreImage
-weak_framework Metal SpriteKit SceneKit`. Nothing else, no Mesa headers.

**Running it is the blocker, not building it.** It needs (a)
`libhakios.gl.dylib`, which `hakios-port-userland/build.sh` deliberately does
not build yet ("needs userland/eagl.c, deferred"), and (b) LaunchServices /
backboardd to launch an app bundle — our current job model is a CLI binary
from launchd. Until the EAGL shim ships, the IPA would install but every
`initWithAPI:` would return nil.

## 4. What to run today: `gpucheck-cli`

`tools/gpu-check/gpucheck-cli.c` keeps the last four links of the chain (it
links `out/libOSMesa.8.dylib` directly, as `gl_test` does) and runs the
off-screen tests that matter, with upstream's shapes:

```
ctx.es2, ctx.es3, es2.fbo.d16, es2.finish, es3.fence, es3.mapbufferrange
```

Each prints `gpucheck-cli: <id> running` first and `PASS`/`FAIL` with the
detail; an 8 s `SIGALRM` prints `HUNG in <id>` and exits 124, so a killed run
still names the operation. Build (needs `build-mesa.sh` first):

```
IOS_SDK=... hakios-port-userland/tools/gpu-check/build-gpucheck-cli.sh
# -> hakios-port-userland/out/gpucheck-cli
```

Run it the same way as `gl_test` (a `ProgramArguments` launchd job, or
`usbsh`), then read `/dev/console`:

```
gpucheck-cli: start (watchdog 8 s per test; unbuffered)
gpucheck-cli: es2.fbo.d16 running
gpucheck-cli: es2.fbo.d16 PASS 64x64, the middle is red
...
```

## 5. How to read it against the current failure

Today: `CP_IB1_REM_SIZE` 1736 → 1480 = exactly 256 dwords = 1 KiB fetched,
then `CP int 0x1` (opcode error) and no fence.

* If `es2.fbo.d16` **also** stops after 256 dwords, with a different IB length
  and different shaders, the boundary is not in the stream content: the CP's
  IB fetch/`CP_IB1_BASE` handling in `submit()` is the suspect (the number is
  the fetch chunk, not a packet the client emitted).
* If it **passes**, the driver handles a small stream and the difference is
  what `gl_test` puts beyond 1 KiB (readback blit, larger FBO, depth/stencil
  state). Diff `IB 0 at ..., N words` and the first 40 ring dwords between
  the two runs; the packet at dword 256 is then the one to decode.
* `es2.finish` and `es3.fence` separate "submit never completes" from
  "`glFinish` waits on something else": the fence test does not call
  `glFinish` at all.

## 6. Files added

```
hakios-port-userland/tools/gpu-check/gpucheck-cli.c        the off-screen CLI
hakios-port-userland/tools/gpu-check/build-gpucheck-cli.sh builds it
hakios-port-userland/tools/gpu-check/build-gpu-check.sh    builds upstream's IPA
hakios-port-gpu2/GPU-CHECK.md                              this file
```

Nothing else is wired in: no workflow step, no launchd job, no boot arg.
`gpucheck-cli.c` was syntax-checked on the host but not built against the SDK
(no SDK on this machine), so the first CI run is its first real compile.
