# Origin of the files in hakios-port-usb/

All reference files are copied verbatim from **xiongnemo/hakios-alioth**,
branch `alioth` (the repository's default branch), commit
`acdb175eb881e6038c8fc9d7a0ca9997f9c4984e` (2026-11-26). They are the working
USB implementation on the same phone (Xiaomi Mi 11X / Redmi K40 / POCO F3,
SM8250-AC "kona").

| Local file | Upstream path | Blob |
| --- | --- | --- |
| `kernel/bsd/dev/hakios.dwc3.c` | `devices/redmi-k40/overlays/xnu/files/bsd/dev/hakios.dwc3.c` | `971fdb8596fb48df1d48a1dc9da5b0c491d3a017` |
| `kernel/bsd/dev/hakios.dwc3.h` | same directory | `c0b6846f17fbb70df662f9edf4d231e50f6ff8b6` |
| `kernel/bsd/dev/hakios.dwc3regs.h` | same directory | `8270f66b6b713a9bf050d75e2f329933b10da5af` |
| `kernel/bsd/dev/hakios.usb.c` | same directory | `78f8e29c36c509a846296997ff0c3529033c2555` |
| `kernel/bsd/dev/hakios.dwc3.LICENSE` | same directory | `aff0557da45ae68209934ef48887a8112663ca45` |
| `kernel/iokit/Kernel/hakios.usbmux.cpp` | `devices/redmi-k40/overlays/xnu/files/iokit/Kernel/hakios.usbmux.cpp` | `ceff31cb3285d8ebd00c9e25061237077309641a` |
| `kernel/bsd/sys/hakios.board.h` | `devices/redmi-k40/overlays/xnu/files/bsd/sys/hakios.board.h` | (same tree; `hakios_board_is_alioth()`) |
| `reference-xnu-device.patch` | `devices/redmi-k40/xnu-device.patch` | `df8a294da42f98e5d7a54c651ff023251286e52e` |
| `reference-boot.args` | `devices/redmi-k40/boot.args` | `6d74081322044061da70588d4cbf59a39a8bb217` |
| `userland/src/usbmux.c` | `devices/redmi-k40/overlays/userland/src/usbmux.c` | `787523b541987561e795e9477d76ceb73462f3f0` |
| `userland/src/usbsh.c` | `devices/redmi-k40/overlays/userland/src/usbsh.c` | `154d04197a6cf81e30f249c036faaa591e17fe88` |
| `userland/com.hakios.usbmux.plist` | `devices/redmi-k40/overlays/userland/com.hakios.usbmux.plist` | `ad5680eb1faec67fa9f6ef3722d46118313212c8` |
| `userland/com.hakios.usbsh.plist` | `devices/redmi-k40/overlays/userland/com.hakios.usbsh.plist` | `6977953569e5994b4eae998e50f50a0246bbae1e` |

Their `devices/redmi-k40/overlays/userland/build.sh` (blob
`2f18bc56b2c0ec2c943bce72aa0405e41a066792`) is the source of the build flags
recorded in `PORT-NOTES.md` section 8.2; it was read, not copied, because it
builds the whole reference userland image.

## License

The upstream README puts the kernel pieces (under `xnu/` and XNU-derived) under
**APSL-2.0** with Apple's notices retained, and the device layer
(`devices/<phone>/overlays/`, `drivers/`) under the **MIT License**.
`hakios.dwc3.c`/`.h`/`regs.h` come from FFT-infra/QcomXnuUsbDebug, itself
derived from Asahi Linux m1n1 v1.4.17; its `hakios.dwc3.LICENSE` (MIT) is kept
next to the sources. Keep all upstream notices when this becomes a shipped
patch series.

`hakios-port-usb/adapter/` is new work for this tree (same license as the local
fork: see the repository `LICENSE`).
