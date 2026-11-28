# Splitboot on alioth: feasibility

Status: **research only**. Nothing flashed, nothing written to the phone, no
device commands beyond the documented read-only `getvar` values. Measured
facts come from `phone/` dumps, `docs/persistent-boot.md` and `NOTES.md`
(2026-11-28).

**Verdict: DEFER.** The mechanism is real and needs *no* bootloader
replacement, but the splitboot code is MediaTek-only. The alioth equivalent is
a GPT **front**-carve plus a menu inside our existing shim, and the only new
brick risk on this phone is the first GPT write. The design is recorded below
so it can be picked up later without re-research.

## 1. What mapple_splitboot actually does

Four parts, none of them in the bootloader:

1. **GPT carve** (`installer/split.c` `split-carve`, `tools/gpt-carve.py`).
   Shrinks `userdata` from its **end** by `split_size` (22 GiB on the realme
   8i) and adds one entry, `xnusys`, type Linux filesystem data
   (`0FC63DAF-8483-4772-8E79-3D69D8477DE4`). Both GPT copies are rewritten, their CRCs recomputed
   and the result read back and checked (header CRC, entry CRC, no overlap,
   every other entry byte-identical). It also zeroes the first 64 MiB of
   `userdata`, all of `metadata`, the first MiB of `xnusys`, its saved-area
   header and its last MiB. No `sgdisk`; the tool edits the raw sectors.
2. **iOS root in `xnusys`** (`tools/mkdatavol.py`, `var-store-read.py`).
   A raw HFS+ volume image flashed with `fastboot flash xnusys`; the menu
   checks it before offering iOS (`mtkroot.h`: HFS+ header at 1 KiB, alternate
   header 1 KiB before the volume end, same block size/count/create date, and
   128 MiB of tail room).
3. **Boot menu chained into Android's own boot image** (`tools/chainboot.py`,
   `mtk/loader/{splitmenu.h,fbdiag.c,splitboot.h}`). The boot image's kernel
   becomes gzip of: `[menu program, padded to 0x40000] + [Android's own
   uncompressed Image]`. MediaTek LK decompresses the kernel to **0x40080000**
   and enters the program there; the program draws the menu, reads volume/power
   through the MTK PMIC, then either relocates Android's `Image` back to
   0x40080000 and jumps, or boots XNU. The stock boot image is saved in
   `xnusys`'s last 128 MiB for an exact restore.
4. **Uninstall** (`split-uninstall`): restores the GPT and the saved boot only
   while `boot` is still the chained image (SHA-256 checked), zeroes data.

Boot settings are not in the bootloader either: `mp_menu_default`,
`mp_menu_secs`, `mp_menu_pmic` are read from a boot-args record in `xnusys`'s
last MiB.

**Explicitly not used:** A/B slots (the realme 8i is non-A/B), dynamic
partitions / `super`, lk2nd, patched `aboot`/ABL, `fastboot oem`, `ffbm`, or a
custom bootloader menu. The bootloader stays stock and unlocked; it simply
loads a boot image whose "kernel" is the menu. The website's own status line
says *"only the boot menu has run on a phone; the install steps are untested"*.

## 2. Requirements mapped onto alioth

| Requirement | alioth | Verdict |
| --- | --- | --- |
| Unlocked bootloader, unsigned boot image accepted | `oem device-info`: unlocked yes, critical yes, `verifiedbootstate=orange` | yes |
| Recovery that can write the whole disk and run tools | OrangeFox over `recovery`, `adb` | yes |
| GPT editable on the data LUN | LUN 0 (`/dev/block/sda`), 4 KiB sectors, 64 entries at LBA 2 | yes, but see §4 |
| Shrinkable data partition | `userdata` 0x2B8C00 + 0x1AC4B MiB (~107 GiB) | yes |
| Room for a second OS | 16 GiB iOS HFS at userdata start; `super` 8.5 GiB intact; ~87 GiB left after a 20 GiB carve | yes |
| Boot image that ABL will run arbitrary code from | our v2 shim, 18 MB, in a 192 MiB `boot_b` | yes, proven |
| Kernel load address for chaining | **0x80080000** on alioth (`base 0x80000000 + 0x80000`), not MTK's 0x40080000 | known, different |
| Display before the OS | shim `console.c` already paints the panel | yes |
| Volume/power keys before the OS | **no key driver in the shim** (keys live in XNU, `sweetkeys=1`) | work item, ~50 lines |
| Android system still installable | `super` and stock `boot_a` (v3, so `vendor_boot_a` too — confirm `getvar partition-size:vendor_boot_a`) untouched; README: a recovery format-data or fastboot ROM returns Android | yes |
| `metadata` present for the zeroing step | yes | yes |

## 3. What transfers, what does not

**Transfers:** the design (carve + menu in the boot image + saved boot for
undo), the "no bootloader change" property, and the safety discipline (both GPT
copies, read-back, no-overlap, save the old boot, SHA-256 before restoring).

**Does not transfer:** the code. `fbdiag.c`/`mtkloader.c` poke MTK display
(OVL/DSI), MTK PMIC keys and MTK UART; `KERNEL_PA` is 0x40080000 and
`chainboot.py` hardcodes a 32 MiB `boot` limit. None of it compiles or runs on
SM8250. The *chain idea* maps 1:1 onto what we already do: ABL starts our shim
as the kernel at 0x80080000 with MMU off and `x0` = DTB.

**The carve direction is wrong for us.** On the realme, Android's data is at
the start of `userdata` and iOS takes the end. On alioth the iOS HFS+ volume
already occupies the **first 16 GiB** of `userdata`. An end-carve plus "let
Android set up again" (what splitboot does) hands the first 16 GiB back to
Android, which formats it: the iOS root is destroyed. The alioth layout has to
be a **front carve**:

```
old:  [ userdata ................................................. 107 GiB ]
new:  [ darwin 20 GiB ][ userdata ................................  87 GiB ]
      ^ HFS+ volume, 16 GiB, unchanged bytes      ^ Android formats this
```

`darwin` gets type Apple HFS (`48465300-0000-11AA-AA11-00306543ECAC`) and
`userdata`'s *start* moves. Our kernel already boots a root by GPT name
(`ufsroot=`), so no shim change is needed for the root itself; what is missing
is tooling (splitboot's `gpt-carve.py` only shrinks at the end and refuses to
move a start) and the 5 MiB at the end of `userdata` (log ring + SWEETBOX
mailbox) must move into `darwin`, or it ends up inside Android's data.

**The menu on alioth is cheaper than porting mtkloader.** Our shim is already
the program ABL enters, with a framebuffer and console. Add a 5 s menu, read
the two volume keys through PM8150 GPIO, and on "Android" write the A/B slot
suffix into `misc` and PSCI-reset: ABL then boots stock `boot_a` with its own
v3/vendor_boot path. That is `fastboot set_active a` implemented on the phone.
No Android kernel chaining, no 192 MiB image gymnastics, no MTK code. The cost
is that returning from Android to iOS still needs a PC (`fastboot set_active
b`) unless a second menu is added to `boot_a`.

## 4. Risk, and whether the escape hatch holds

| Operation | Failure | Consequence | Escape |
| --- | --- | --- | --- |
| GPT rewrite (both copies) | bad CRC/overlap, or both copies lost | ABL cannot find `boot` **or** `recovery`; fastboot may start but has no partition table to flash | **EDL only**, and Xiaomi EDL may require authorisation. This is the only true brick vector. |
| Front carve, wrong extents | `darwin`/`userdata` overlap or wrong start | iOS root unreadable, Android may format it | `fastboot flash userdata root.img` (5 min), not a brick |
| Android's first boot | Android formats its `userdata` | if `darwin` was not split and verified first, the iOS root is gone | same as above |
| `misc` slot write from the menu | wrong suffix | boots the wrong slot | Power+VolDown → `fastboot set_active b` |
| Menu crash on `boot_b` | reset loop | retry counter, possible fallback to `a` | `boot_a` stock; fastboot; reflash `boot_b` from PC |
| Flash/chain a bad boot image | shim paints an error and resets | iOS does not start | Power+VolDown → `fastboot boot` from RAM |

Everything except the GPT edit keeps today's escape hatch intact: Power+VolDown
is handled in XBL/ABL *before* a boot image is read, `fastboot boot` runs from
RAM, and `boot_a` is never touched. The GPT is the one change that can also
remove recovery, so it must be done offline-validated and with raw dumps on the
PC **and** an OTG stick. Note also that splitboot's installer is not the thing
to run here: `split-carve` zeroes 64 MiB at the **start** of `userdata`, which
is exactly our HFS+ volume header.

## 5. The smallest experiment that proves the mechanism

Do these in order; stop at the first surprise. Phases 0 and 1 write nothing.

**Phase 0 — menu in the shim, RAM boot (~1 day, no writes).**
Build a variant of `shim-boot-alioth.img` that, before `loader_boot()`, paints
`iOS (default) / Android` for 5 s, moves the selection with Volume Up/Down and
confirms with Power (PM8150 GPIO; borrow the register sequence from the XNU
keys driver). "iOS" continues into the existing path and must reach
SpringBoard. "Android" only prints the 4 bytes it *would* write to `misc` and
resets. Boot it with `fastboot boot`; nothing is flashed.
*Proves:* keys and menu before any OS, and that the decision can be taken
without a PC. *Fails safely:* RAM-only.

**Phase 1 — offline front-carve on GPT dumps (~1 h, no writes).**
From OrangeFox, read LBA 0–5 and the last 33 sectors of `/dev/block/sda`
(read-only `dd`). Run the front-carve on the files and assert: both copies
parse, CRCs match, no entry overlaps, all other entries byte-identical,
`darwin` = 16 GiB at the old `userdata` start, new `userdata` start 1 MiB
aligned. Then optionally write the *identical* bytes back once from recovery to
prove the write path and ABL's tolerance, with the dump on OTG.
*Proves:* the GPT edit is representable and the tool is correct, without
changing content. *Abort if:* any other entry moves.

**Phase 2 — the destructive step, only if Android is wanted.**
Do the real carve, boot iOS with `ufsroot=darwin` and verify SpringBoard
**before** Android is ever allowed to boot. Then boot `boot_a` and let Android
set up fresh in the 87 GiB `userdata`.

## 6. Recommendation: DEFER

Reasons:

* Low priority by the project's own ordering; the iOS bring-up (GPU, USB,
  userland) is where the value is.
* It needs no bootloader work — but it does need the first GPT write on this
  phone, the one operation whose failure is not covered by Power+VolDown,
  `fastboot boot` or `boot_a`.
* The payoff is an Android we currently *deliberately* keep from booting,
  because it would reformat the partition holding iOS.
* The splitboot code is not reusable on Qualcomm; only the design is, and the
  alioth version (front carve + shim menu + `misc` slot switch) is written
  down here.

Revisit when "Android next to iOS" becomes a goal. Then run Phase 0 and Phase 1
first; both are free.

## 7. Sources

* <https://github.com/open-mapple/mapple_splitboot> — README; `installer/split.c`
  (`split-carve`, `split-chain`, `split-uninstall`); `tools/gpt-carve.py`;
  `tools/chainboot.py`; commits 2026-11-13/14 (the dual-boot verbs).
* <https://open-mapple.pages.dev/splitboot/> — user-facing install, menu,
  uninstall, "22 GiB", status.
* <https://open-mapple.pages.dev/docs/subsystems/splitboot/> — "no hardware of
  its own", `mp_menu_*`, status *"only the boot menu has run on a phone; the
  install steps are untested"*.
* `mapple_loader` `mtk/loader/{splitmenu.h,mtkroot.h,splitboot.h,fbdiag.c}` —
  menu logic, HFS+ root check, `KERNEL_PA 0x40080000`, core parking.
* Local: `docs/persistent-boot.md` (boot sizes, slot/retry, escape hatch),
  `NOTES.md` 2026-10-15/16 (GPT layout, `super` 8.5 GiB, userdata 0x2B8C00 +
  0x1AC4B MiB, the abandoned 64 GiB `iosroot` plan), `shim/build.sh`
  (`--base 0 --kernel_offset 0x8000`, ABL loads at 0x80080000).
