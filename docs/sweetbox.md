# SWEETBOX: install files into the iOS root without reflashing `userdata`

Status: **implemented but not built or booted on the phone yet** (2026-11-26).
Everything is opt-in behind `sweetbox=1`; a boot without that argument is byte
for byte the old boot path.

## Why

Today a userland change means rebuilding the 16 GiB HFS image and flashing
`userdata` (~5 min, plus the ABL can wedge and need a manual fastboot). For the
Mesa/GL work we need to drop a binary or a launchd job, reboot, and read the
result out of the console ring.

Upstream `coreycusick/ios-guacamole` solves this with `SWEETBOX`: a raw
`logdump`/`rawdump` partition, kernel patches 0115/0116/0118/0119, a
`ROOT/<path>` install mode and a `sweet-autorun` helper. Their kernel reads a
partition by name and stamps it `SWEETDNE`. We do not have a spare LUN-0
partition and our UFS driver only talks to the one partition it mounted, so
this tree uses the **reserved tail of `userdata`** instead. `xiongnemo/hakios-alioth`
has `usbmux`/`usbsh`/`ipainstall`, which is a nicer long-term channel, but it
needs the USB gadget that is blocked here (apps-SMMU/DWC3), so it cannot be
the phase-1 mechanism.

## What is on the branch (`hakios-autorun`)

- `xnu/patches/0400-sweetbox.patch`:
  - `bsd/dev/sweet_box.c` (new): verifies and unpacks the mailbox.
  - `bsd/dev/sweet_ufs.c`: `sweet_ufs_box_read/write()` for the reserved
    1 MiB, bounded to that area; the console ring stays the last 1025 blocks.
  - `bsd/kern/bsd_init.c`: calls `sweet_box_init()` after the root mounts and
    **before launchd**.
  - `bsd/dev/mem.c`: `sweet-autorun` added to the default `sweetnull` list, so
    its stdout appears in the log.
  - `bsd/conf/files`: builds the new file.
- `tools/sweet-box.py`: pack / apply / pull / clear / status (recovery ADB).
- `tools/sweet-launchd-autorun.py`: add the `com.sweet.autorun` job to an
  existing launchd cache (one-time bootstrap).
- `userland/sweet-autorun.c` + `userland/build.sh`: the helper launchd runs.
- `docs/sweetbox.md` (this file).

## Layout and format

`userdata` is ~107 GiB; the iOS HFS image is 16 GiB at its start. The tail is
free and already used by the persistent log:

```
... HFS iOS root (16 GiB) ...   [ SWEETBOX mailbox 1 MiB ] [ log header 1 blk ] [ log ring 4 MiB ]
                                ^ end - (1025+256) blocks    ^ end - 1025 blocks   ^ end
```

Putting the mailbox *before* the log keeps patch 0047/0097/0108 unchanged: an
old `tools/sweet-log-pull.sh` still reads the last 1025 blocks correctly, and
the new tool reads 1281 blocks and takes the first 256.

Little endian, 4096-byte blocks, 256 blocks:

```
header 32 B:
  "SWEETBOX" | u32 version=1 | u32 nfiles | u32 payload_len |
  u32 payload_crc32 | u32 state | u32 header_crc32
entry:
  u16 namelen | name | u32 size | u32 crc32 | data
```

`header_crc32` covers the first 28 bytes; `payload_crc32` covers the payload
bytes. `state` is 0 pending (the only value the PC writes), 1 installed,
2 failed. The kernel checks the magic, header CRC, sizes and payload CRC
before opening any file. File entries carry their own CRC too; a bad file is
skipped and the box is marked failed.

Destinations:

- `ROOT/<path>` → `/<path>` on the root, **only** with `sweetboxroot=1`, and
  only under a small allowlist in `sweet_box.c`
  (`private/var/tmp/`, `private/var/mobile/`, `usr/libexec/sweet-autorun`,
  `usr/local/bin/`, `var/local/bin/`, `var/local/lib/`,
  `System/Library/LaunchDaemons/`, `System/Library/xpc/launchd.plist`).
  Parent directories must already exist (the kernel has no mkdir KPI).
- everything else → flat in `/private/var/tmp/` (`/` becomes `_`, a leading
  `.` becomes `_`). This is where `autorun.sh` and test binaries go.

After all entries: `/private/var/tmp/SWEETBOX.done` is written, then the
header state is stamped. `sweet-autorun` waits for a **non-empty** done file
(cleared at the start of every `sweetbox=1` boot — there is no RTC, so mtimes
cannot distinguish boots).

## Commands

### 0. One-time bootstrap (only once per root)

Build the helper on a Mac (needs Xcode):

```sh
userland/build.sh                    # -> userland/out/sweet-autorun
```

Make the launchd cache with the autorun job. `base.plist` is the phone's
current `/System/Library/xpc/launchd.plist` (from the local root image, or a
raw read in recovery). Keep the unmodified file as the rescue copy.

```sh
tools/sweet-launchd-autorun.py base.plist launchd.plist
printf '/private/var/tmp/hello\n' >/tmp/autorun.sh
tools/sweet-box.py pack /tmp/box.bin \
    ROOT/System/Library/xpc/launchd.plist=launchd.plist \
    ROOT/usr/libexec/sweet-autorun=userland/out/sweet-autorun \
    hello=/path/to/arm64/hello \
    autorun.sh=/tmp/autorun.sh
```

The job dictionary is stored inside the cache under the key
`/System/Library/LaunchDaemons/com.sweet.autorun.plist`; no separate file at
that path is needed (this is how `ios-guacamole` does it too).

### 1. Apply a box (phone in OrangeFox recovery, `adb` available)

```sh
tools/sweet-box.py apply /tmp/box.bin
tools/sweet-box.py status          # optional: header, files, CRCs
```

`apply` finds `userdata`, computes `skip = size/4096 - (1025+256)`, writes
exactly 256 blocks with `dd conv=notrunc,fsync`, and reads them back. It never
touches the HFS area.

### 2. Boot with the channel on

Add to the kernel cmdline (see `README.md` for the full line):

```
sweetbox=1
# first time only, to install the launchd cache + helper:
sweetbox=1 sweetboxroot=1
```

Expected console lines:

```
SWEET BOX: enabled; emptied /private/var/tmp/SWEETBOX.done (0)
SWEET BOX: 3 file(s), ... payload bytes, root install on
SWEET BOX: installed /System/Library/xpc/launchd.plist (...)
SWEET BOX: extracted /private/var/tmp/hello (...)
SWEET BOX: done, ...
SWEET BOX: stamped state 1: 0
```

Then launchd starts `com.sweet.autorun`; `sweet-autorun` sees the done file,
runs `autorun.sh`, and its output appears in the persistent log as
`|sweet-autorun| SWEET RUN: ...`.

### 3. Later boxes (no `sweetboxroot`)

```sh
printf '/private/var/tmp/hello\n' >/tmp/autorun.sh
tools/sweet-box.py pack /tmp/box.bin hello=/build/hello autorun.sh=/tmp/autorun.sh
tools/sweet-box.py apply /tmp/box.bin
# reboot with sweetbox=1
```

### Reading the result

```sh
tools/sweet-log-pull.sh /tmp/boot.txt          # same recovery session
grep 'SWEET BOX\|SWEET RUN' /tmp/boot.txt
```

or boot with `sweetlogdump=... sweetloggrep=SWEET` as documented in
`README.md`.

## Recovery when a payload is bad

- **CRC / magic bad:** the kernel prints `SWEET BOX: payload CRC mismatch` or
  `no SWEETBOX magic` and does **not** open any file. It also does not stamp
  the mailbox, so `tools/sweet-box.py status` still shows it; fix and re-pack,
  or `tools/sweet-box.py clear`.
- **A file fails to install:** state becomes 2 and the log says which file.
  Re-pack with a corrected file (the PC tool always writes state 0) and apply.
- **Bad `launchd.plist` / launchd does not start:** the kernel still installs
  `ROOT/` entries at `bsd_init`, before launchd reads the cache. Boot recovery,
  put the saved unmodified `launchd.plist` in a box as
  `ROOT/System/Library/xpc/launchd.plist`, apply, boot with
  `sweetbox=1 sweetboxroot=1`. That is the rescue path; keep the original
  `base.plist` outside the phone.
- **Mailbox cleared:** `tools/sweet-box.py clear` zeros only the first
  mailbox block; the next boot prints `no SWEETBOX magic` and continues.
- **Worst case:** the mailbox is outside the HFS image. Deleting/ignoring it
  is enough; no reflash is required. If the root itself was damaged by an
  allowed `ROOT/` write, the same mailbox can restore the file, and the full
  image reflash path in `README.md` remains the last resort.

## Risks and honest trade-offs

- **No live channel.** Phase 1 applies on the next boot because the PC must be
  in recovery to write raw blocks. This is one reboot per iteration, not the
  ~5-minute flash + ABL risk. A live USB/usbmux channel needs the gadget that
  is currently blocked (see `ROADMAP.md`, USB).
- **A bad root install can stop the UI.** The allowlist and the
  before-launchd rescue path reduce this; it is still a root write. Do not add
  `/sbin/launchd` or arbitrary `/System` paths to the allowlist casually.
- **Mailbox size** is 1 MiB (up to 64 files). Enough for a dylib or a few
  binaries; not for an app bundle. Raise `SWEET_BOX_BLOCKS` in both
  `sweet_ufs.c` and `tools/sweet-box.py` if needed (keep 4096-byte blocks).
- **Log interaction:** the mailbox is before the log header, so the log never
  overwrites a pending box and an old log puller still works. A future change
  to the log layout must keep the mailbox offset in sync with the tool.
- **No signature check on the box.** The kernel checks integrity (CRC), not
  authenticity. The phone is already an unlocked bring-up target; do not use
  this on a device with data you care about.
- **Kernel/userland compile status:** all touched kernel files compile with
  `tools/xnu-cc.py` against the 45735232511 build tree. The userland helper
  needs a Mac build and has not run on the phone. The first on-device run
  must confirm the launchd job and the `SWEET RUN:` relay.
