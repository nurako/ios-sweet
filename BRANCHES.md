# Branches

One line per branch: what it carries, its feature patch number (everything
also has the baseline `0001`-`0118`), and the extra boot arguments.  The
common prefix is the usual UI line:

```
debug=0xc serial=3 cpus=8 keepsyms=1 -noprogress rd=ufsroot0 \
unentitled_ios_sim_launch=1 ignition_level=1 wdt_test=no_user_checkin \
ufsrw=1 rootrw=1 launchd_unsecure_cache=1 wdt=-1 \
sweettouch=1 sweettouchdelay=0 sweetkeys=1 sweetusb=0
```

| Branch | Carries | Feature patch | Extra boot args |
| --- | --- | --- | --- |
| `main` | Baseline iOS 16 port: display/console, UFS root, touch/keys, USB probe, GPU zap ladder up to 0118 | `0001`-`0118` | none beyond the common line |
| `hakios-gpu` | xiongnemo/hakios-alioth Adreno 650 port (GMU, SQE, zap, HakiosGPU service) | `0200-hakios-gpu.patch` | `sweetgpu=22 sweetgpukeep=1` (step ladder) or `adreno_soc=a650 adreno=22`; service: `adreno=21 adreno_keep=1` |
| `hakios-usb` | DWC3 device stack, CDC-ACM `1209:316d`, `usbmux`/`usbsh` userland, `usb=1/2/3` | `0300-hakios-usb.patch` | `usbhakios=1 usb=2` (shell/log) or `usbhakios=1 usb=3` (iPhone mux) |
| `hakios-all` | GPU and USB together (0200 + 0300), combined cmdline and expectations | `0200-hakios-gpu.patch`, `0300-hakios-usb.patch` | common line + `sweetgpu=<N> sweetgpukeep=1 usbhakios=1 usb=2` (or `usb=3`) |
| `hakios-infra` | `hakios-all` tree plus CI caching, the `userland` workflow, USB log replay, udev rule, this file | `0200`, `0300` (0300 gains `usbreplay=1`) | common line + `usbhakios=1 usb=2 usbreplay=1` (add `sweetgpu=<N> sweetgpukeep=1` for GPU) |
| `hakios-battery` | Alioth PM8150B fg-gen4 gauge / SMB5 charger readout, opt-in, compile-only | `0500-hakios-battery.patch` | `batteryhakios=1` |
| `hakios-small` | Currently the same commit/tree as `hakios-battery` (battery phase 1); kept as the small-root experiment branch | `0500-hakios-battery.patch` | `batteryhakios=1` |
| `hakios-net` | Wi-Fi kernel side ported from xiongnemo/hakios-alioth (WCN6750/ath11k path), compile-only, not booted | `0300-hakios-net.patch` (branch-local) | `wihakios=1 wifi=1 wifi_loud=1 wifi_mac=...` |
| `hakios-autorun` | SWEETBOX no-reflash install channel: mailbox, `sweet-autorun`, launchd bootstrap | `0400-sweetbox.patch` | `sweetbox=1` (first box: `sweetbox=1 sweetboxroot=1`) |
| `docs/guacamole-research` | Research only: how ios-guacamole booted iOS 27 on SM8150 and what transfers to alioth; no kernel changes | none | none (documentation) |
