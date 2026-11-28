# Persistent boot: iOS on a normal power-on

Status: **researched and measured on the device; nothing was flashed while
writing this** (only read-only `getvar`/`oem device-info` queries were run).
The install, flash and undo steps are ready in `tools/`.

## Decision

Flash **one partition only: the active `boot` slot (`boot_b`)**.

* `boot_a` stays stock — a second escape hatch.
* `vbmeta` is **not required** on this device (bootloader unlocked, Android
  reports `verifiedbootstate=orange`, i.e. AVB is not enforcing). A `--vbmeta`
  switch exists only as a fallback if the first normal boot stops on an AVB
  screen.
* `dtbo`, `super`, `recovery`, `modem`, `persist`, `userdata` and the GPT are
  not touched. `dtbo` must stay stock: ABL applies the same overlays it already
  applies for `fastboot boot`.
* Add `root=/dev/ram0` to the boot **header** cmdline (the installer's
  `--dev-image-cmdline`). Qualcomm's boot code skips A/B retry-counter
  decrements for a "boot dev image" cmdline containing `root=`; the shim/XNU
  never read this string, so the change is inert to iOS. This is only strictly
  needed when `slot-successful:b` is not `yes`.
* Do **not** re-lock the bootloader afterwards. An unsigned `boot` plus a
  locked bootloader is a brick that needs EDL.

Why this is safe enough to try: `fastboot boot` and a normal power-on run the
*same* ABL image loader. The only differences are (a) where the image bytes
come from (USB buffer vs the `boot_b` partition) and (b) ABL runs its AVB check
on the normal path. The image has booted hundreds of times through (a), and (b)
is disabled in the orange/unlocked state. Everything the shim needs — device
tree, payload, kernel command line — is inside the image itself.

## What the device actually has (measured 2026-11-27, fastboot)

```
current-slot: b            slot-count: 2
unlocked: yes              secure: yes
partition-size:boot_a:   0xC000000   (192 MiB)
partition-size:boot_b:   0xC000000   (192 MiB)
partition-size:vbmeta_a: 0x20000     (128 KiB)
partition-size:vbmeta_b: 0x20000     (128 KiB)
partition-size:dtbo_a:   0x2000000   (32 MiB)
partition-size:dtbo_b:   0x2000000   (32 MiB)
slot-retry-count:a: 6      slot-retry-count:b: 6
   (slot-successful:a|b could not be read at that moment: the ABL had been
    wedged by `getvar all`; check it first with a fresh fastboot)
max-fetch-size: FAILED (remote: 'GetVar Variable Not found')  -> no fastboot fetch
is-userspace: no           product: aliothin      variant: SM8 UFS
oem device-info: Verity mode: true / Device unlocked: true /
                 Device critical unlocked: true / Charger screen enabled: false
off-mode-charge: 0         battery-soc-ok: yes    battery-voltage: 4393
```

`getvar verity` does **not** exist on this ABL (`GetVar Variable Not found`); use
`fastboot oem device-info`, which reports `Verity mode: true`.

**Do not run `fastboot getvar all` here.** It wedged this ABL (observed: it
stopped answering individual getvars until re-entering fastboot). The
installer uses only individual getvars.

| Fact | Value | Where it comes from |
| --- | --- | --- |
| Active slot | **b** | `getvar current-slot`; `phone/cmdline.txt`: `androidboot.slot_suffix=_b` |
| Slot count | 2 (A/B) | `getvar slot-count` |
| Stock `boot_b` | header **v3**, 192 MiB partition dump (`201326592` B), kernel `53493784` B, ramdisk `1516712` B, empty header cmdline (v3 keeps it in `vendor_boot`) | `phone/boot.img` |
| Our shim image | header **v2**, page 4096, `18083840` B, kernel (shim) `188416` B, ramdisk (payload) `17046832` B | `shim/out/shim-boot-alioth.img` |
| `vbmeta` dump | 128 KiB (`131072` B), `AVB0` magic | `phone/vbmeta.img` |
| `dtbo` dump | 32 MiB (`33554432` B) | `phone/dtbo.img` |
| Verified boot state | `orange` (unlocked) | `phone/cmdline.txt`: `androidboot.verifiedbootstate=orange` |
| SoC secure boot | `androidboot.secureboot=1` (PBL/XBL chain only; unrelated to OS AVB) | `phone/cmdline.txt` |
| Payload command line | 431 chars, `rd=ufsroot0 … sweettouch=1 sweetkeys=1 … adreno=22 …` baked into the payload | parsed out of the image |

The 192 MiB `boot` size, 128 KiB `vbmeta` and 32 MiB `dtbo` from `getvar`
match the dumps in size exactly, so `phone/boot.img` is a complete partition
image and a valid restore. It was taken while slot b was active. Factory A/B
images are identical on both slots, so it is a valid restore for either slot
unless an OTA has since changed one of them; the script records the provenance
and checksum it actually used.

## Header v2 vs the stock v3 header

The stock boot partition is a v3 image; ours is v2. That is fine and is
actually **preferable**:

* `fastboot flash boot` writes bytes; the header is parsed by ABL at boot time,
  and the v2 image already boots on this exact bootloader via `fastboot boot`.
* v2 is self-contained: the embedded `live.dtb` and the 431-char payload
  command line travel with the image. A v3 boot image has no cmdline and no
  base DTB (they live in `vendor_boot`), so rebuilding as v3 would add a
  dependency we do not need.
* ABL selects its loader path from the boot header version. A v2 image takes
  the legacy path (base DTB and cmdline from `boot`, no `vendor_boot`
  concatenation); that is the same path that has been booting with
  `fastboot boot`. Expect `linux,initrd-start` to point at our payload exactly
  as it does today.

The shim only consumes (a) the DTB in `x0` and (b) `/chosen/linux,initrd-start`
→ `/chosen/linux,initrd-end`, then reads `SWEETXNU` at that address. All three
are produced by ABL from the image, not by the host, so a normal boot has the
same inputs as `fastboot boot`.

## AVB, measured against this device

Reading the recorded cmdline and `oem device-info`:

```
androidboot.verifiedbootstate=orange
androidboot.secureboot=1
Verity mode: true
Device unlocked: true
Device critical unlocked: true
```

* `secureboot=1` is the Qualcomm PBL→XBL→ABL chain. It is still intact; we are
  not touching the bootloader.
* `verifiedbootstate=orange` is Android Verified Boot's *unlocked* state, and
  `Device unlocked`/`critical unlocked` are both `true`. ABL may display the
  "device cannot be checked" warning but it does not refuse the image. This is
  why every Xiaomi user can flash a patched `boot` after
  `fastboot flashing unlock` without touching `vbmeta`.
* `Verity mode: true` is the *dm-verity* mode for the Android system
  partitions, not a promise to verify `boot` against `vbmeta` while unlocked.
  It is the normal value on an unlocked Xiaomi.
* The stock `vbmeta` contains the hash of the stock `boot_b`. Ours does not
  match it. In the orange state that mismatch is reported, not enforced.

So the minimal set is **`boot_b` and nothing else**. If the first normal boot
instead stops on an AVB error screen or returns to fastboot, re-run the
installer with `--vbmeta`, which writes the stock vbmeta for the active slot
with both verification flags cleared:

```
fastboot --disable-verity --disable-verification flash vbmeta_b phone/vbmeta_b.img
```

Caveat: that vbmeta image's signature no longer matches its contents. It is
only acceptable because the bootloader is unlocked. Never lock the bootloader
after it.

## Exact command sequence

Facts first (all read-only):

```sh
fastboot devices
fastboot getvar current-slot
fastboot getvar slot-count
fastboot getvar unlocked
fastboot getvar secure
fastboot getvar verity        # unsupported on this ABL (see below)
fastboot getvar partition-size:boot_a
fastboot getvar partition-size:boot_b
fastboot getvar partition-size:vbmeta_a
fastboot getvar partition-size:vbmeta_b
fastboot getvar partition-size:dtbo_a
fastboot getvar partition-size:dtbo_b
fastboot getvar slot-successful:a
fastboot getvar slot-successful:b
fastboot getvar slot-retry-count:a
fastboot getvar slot-retry-count:b
fastboot oem device-info
```

Measured on this phone (2026-11-27): `current-slot: b`, `slot-count: 2`,
`unlocked: yes`, `secure: yes` (SoC), `partition-size:boot_*: 0xC000000`
(192 MiB — exactly the 201326592-byte dump), `vbmeta_*: 0x20000` (128 KiB),
`dtbo_*: 0x2000000` (32 MiB), `slot-retry-count:*: 6`. If any of these differ,
stop and re-read this document before flashing; the script refuses on obvious
mismatches. `getvar verity` is unsupported; use `fastboot oem device-info`.
Do not use `getvar all` (it wedges this ABL).

Back up (checksummed). `fastboot fetch` is *not supported* by this ABL
(`max-fetch-size` is unsupported), so the backup is the existing dump; the
script copies it to the slot-specific name, verifies the `ANDROID!` magic and
writes a `.sha256` plus a manifest:

```sh
sha256sum phone/boot.img phone/vbmeta.img
```

Then the only write. Add `root=/dev/ram0` to the image's **boot header** command
line first if it is not already there (Qualcomm's boot code treats a cmdline
containing `root=` as a "boot dev image" and skips retry-counter decrements;
unverified on this ABL, harmless either way. The shim/XNU never read this
header string). Rebuilt images get it from
`shim/build.sh`; for the existing image the installer makes a byte-identical
copy that differs only in the 512-byte v2 header cmdline field:

```sh
# what tools/install-persistent-boot.sh --dev-image-cmdline prepares:
#   header cmdline: "console=null root=/dev/ram0"
fastboot flash boot_b phone/persistent-boot-b.img
fastboot set_active b
fastboot reboot
```

Without the patch it is the same command with `shim/out/shim-boot-alioth.img`.
`fastboot set_active b` writes only `misc`; it does not write `boot_a`.

The one-shot wrapper does all of the above with checks, a preflight of the
baked payload command line and a printed undo:

```sh
tools/install-persistent-boot.sh --yes
# recommended when slot-successful:b is not "yes":
tools/install-persistent-boot.sh --yes --dev-image-cmdline
# optional AVB fallback:
tools/install-persistent-boot.sh --yes --vbmeta
```

## Escape hatch and bootloop recovery

The bootloader is never modified, so fastboot is always reachable:

1. Hold **Power ~10 s** to force the phone off.
2. Hold **Power + Volume-Down** until the fastboot screen appears. This happens
   in XBL/ABL, before any boot image is read, so a broken `boot_b` cannot
   prevent it. Unplug USB first on alioth if it enters charger mode instead.
3. From fastboot, any of:
   * `fastboot flash boot_b phone/boot_b.img` — permanent undo (also
     `tools/persistent-boot-restore.sh --yes`).
   * `fastboot boot phone/boot_b.img` — boot stock once, no write.
   * `fastboot boot recovery/recovery.img` — OrangeFox, with `adb` if present,
     to pull logs or fix `userdata`.
   * `fastboot --set-active=a` — last resort only (see the warning below).

No PC-side ROM, no MiFlash, no EDL is needed to undo a bad `boot_b`.

**Warning about slot A / Android:** `boot_a` is stock Android and `userdata`
now contains the iOS HFS+ root. If Android is allowed to boot, it cannot mount
its data and may reformat `userdata`, destroying the iOS root. Use `boot_a` only
to reach fastboot/adb, and prefer `fastboot boot recovery` or restoring
`boot_b`. A normal recovery is `fastboot flash boot_b phone/boot_b.img`, not
"let Android boot".

## Multi-slot safety and retry counters

* Only `boot_b` is written; `boot_a` is never touched by these scripts.
* ABL chooses the slot from `misc` (`slot_suffix`). The A/B retry bookkeeping
  lives in the `misc` bootloader message (`slot_metadata`: bootable /
  successful / tries-remaining). Xiaomi/Qualcomm ABL decrements
  `tries_remaining` on a normal boot **only when the slot is bootable, not
  marked successful, and the counter is above zero**; a slot marked
  `successful` is left unchanged (observed on Xiaomi ABL devices). It also
  skips the decrement for fastboot/fastbootd/charger/recovery boots, and
  Qualcomm's published UEFI code skips it for a "boot dev image" whose command
  line contains `root=` (that last quirk is not verified on this ABL; the
  change is inert either way).
* Consequence for us: Android last booted from slot b and called
  `markBootSuccessful`, so b should still be `successful=yes` in `misc` —
  `fastboot flash` does not clear that flag, and our kernel never writes
  `misc`. Under that condition ABL never decrements and will keep booting b
  forever. `slot-retry-count:b` is 6 today, consistent with a successful slot.
* Verify before the first normal boot:
  `fastboot getvar slot-successful:b` → expect `yes`.
  * `yes`: nothing more to do; retries are not decremented.
  * `no`: ABL will decrement on every normal boot; after 6 boots it can mark b
    unbootable and fall back to `boot_a` (Android, which may reformat
    `userdata`). Then either (a) run the installer with
    `--dev-image-cmdline`, which changes the boot **header** command line (not
    the payload's, which is what XNU sees) to contain `root=/dev/ram0`; Qualcomm's
    boot code treats that as a dev image and skips the decrement (unverified
    on this ABL, harmless either way), or (b) re-run
    `fastboot set_active b` every few boots (it resets the counter to 6), or
    (c) implement the permanent fix: have the shim/kernel write
    `successful=1` for the slot into `misc` on boot.
  * empty/unsupported: treat as `no`.
* `fastboot set_active b` writes only the `misc` slot suffix and, per the
  AOSP contract, also clears the unbootable flag and resets the retry count for
  b. It does not write `boot_a`.
* `fastboot boot` ignores the slot entirely (it boots the buffer you send), so
  the existing bring-up workflow keeps working after the flash.
* If the phone ever comes up on slot a, immediately `fastboot set_active b`
  and **do not let Android boot** with the iOS image in `userdata`.

## Kernel command line: there is no host on a normal boot

The shim builds XNU's `boot_args` from the **payload header's** 608-byte
cmdline (`tools/mkpayload.py --cmdline`), not from ABL's cmdline and not from
the boot image header. On a normal boot nobody can add arguments, so the image
must be self-sufficient. The current `shim-boot-alioth.img` is:

```
debug=0xc serial=3 cpus=8 keepsyms=1 -noprogress rd=ufsroot0
unentitled_ios_sim_launch=1 ignition_level=1 wdt_test=no_user_checkin
ufsrw=1 rootrw=1 launchd_unsecure_cache=1 wdt=-1
sweettouch=1 sweettouchdelay=0 sweetkeys=1
sweetusb=0 usbhakios=1 usb=2 usbreplay=1
sweetgpu=0 board_pil_gpu=0x8681a000 board_pil_gpu_size=0x2000
adreno=22 adreno_keep=1 adreno_pause=0 adreno_watch=30 adreno_loud=1 gpu_irq=1
sweetbox=1 batteryhakios=1
```

What must be present, by subsystem:

| Purpose | Arguments |
| --- | --- |
| Boot at all | `rd=ufsroot0` (UFS root probe), `cpus=8`, `serial=3`, `debug=0xc`, `keepsyms=1`, `-noprogress` |
| iOS userland policy | `unentitled_ios_sim_launch=1`, `ignition_level=1`, `launchd_unsecure_cache=1`, `wdt=-1`, `wdt_test=no_user_checkin` |
| Writable iOS root | `ufsrw=1 rootrw=1` |
| Touch | `sweettouch=1 sweettouchdelay=0` |
| Keys | `sweetkeys=1` |
| Battery | `batteryhakios=1` |
| USB console | `usbhakios=1 usb=2 usbreplay=1` (`sweetusb` is the old path, off) |
| GPU (Adreno 650) | `adreno=22 adreno_keep=1 adreno_pause=0 adreno_watch=30 adreno_loud=1 gpu_irq=1 board_pil_gpu=… board_pil_gpu_size=…` |
| Mailbox | `sweetbox=1` |

`tools/install-persistent-boot.sh` extracts the payload, checks the magic, page
size, header version, payload presence and the required tokens (`rd=ufsroot0`,
`cpus=`, `sweettouch=1`, `sweetkeys=1`, `batteryhakios=1`, `usbhakios=1`) and
refuses to flash an incomplete image. If the image is rebuilt, rebuild it with
the full integrated cmdline from `NOTES.md`; the boot header's own
`console=null` is irrelevant.

## Charging and off-mode

This device reports `off-mode-charge: 0` and `charger-screen-enabled: 0`
(`oem device-info`: `Charger screen enabled: false`). In plain words: it will
**not** sit in a charger UI. With a cable inserted on a powered-off phone,
expect it to try to boot the active slot (our shim) rather than show a battery
icon. Off-mode charging itself is a separate XBL/ABL/PMIC path that runs before
a boot image is read, so flashing `boot_b` cannot break it.

* Flat battery: plug in; the PMIC charges first. Because the charger screen is
  disabled, the phone may power on by itself once it has enough charge. If it
  boots iOS, there is no real charger driver (the battery service is a
  fuel-gauge/static fallback), so it can drain and shut down. That is not a
  brick: the charger path and the bootloader are independent of `boot_b`.
* To avoid surprise boots while charging, charge with the phone off and do not
  rely on a charger screen appearing; unplug and use Power+Volume-Down if you
  need fastboot.
* A dead battery is not a fastboot-blocker: the bootloader runs on a mostly
  empty battery and fastboot works once the PMIC allows the device on.

## Risks, in plain words

1. **Untested normal-boot path for a v2 image.** `fastboot boot` and a normal
   boot use the same loader, but this exact write has not been tried. Failure
   is visible, not silent: the shim paints "`LOADER no SWEETXNU payload`" or
   "`LOADER no initrd in /chosen`" on the panel, then resets. Undo with
   fastboot.
2. **AVB may still warn or stop.** Evidence says it will not (orange state). If
   it does, `--vbmeta` is the fix; if that fails, restore.
3. **Android could reformat `userdata`.** Never let slot A/Android boot with
   the iOS image in `userdata`.
4. **An OTA or `fastboot set_active a` can change the active slot.** After any
   such change, re-check `getvar current-slot` before powering on.
5. **A/B retry could eventually flip the slot.** Qualcomm ABL decrements a
   slot's retry counter on normal boots only while the slot is not marked
   successful. Slot b was marked successful by Android and flashing does not
   clear that, so this should not happen. Check `slot-successful:b` first; if
   `no`, use `--dev-image-cmdline` or `set_active b` every few boots (see the
   multi-slot section). Falling back to slot A means Android, which may
   reformat `userdata`.
6. **A failed shim resets the phone** (PSCI reset, as it does today). ABL then
   boots the active slot again; that is where the retry counter matters.
7. **Signing/locking.** Never re-lock with this image in `boot_b`.

## First-boot observation (what to look for)

After `fastboot reboot`, with the phone unplugged and no key held:

* The "unlocked bootloader" warning appears, then the shim's red screen:
  `SHIM sweet milestone 4: xnu loader`, `INITRD lo=… hi=…`,
  `LOADER <reason>` (empty reason = the payload was found and copied),
  `BOOTARG pa=…`, then XNU output.
* If instead the UFS probe screen ("`UFS probe done, reset in ~3 min`")
  appears, the payload was not at `initrd-start`: the loader chose a different
  ramdisk layout. Undo with fastboot and report the screen.
