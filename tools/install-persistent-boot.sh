#!/usr/bin/env bash
# Make the phone boot iOS on a normal power-on.
#
# Writes exactly one partition: the active boot slot (expected boot_b). The
# other slot, dtbo, super, recovery, modem, persist, userdata and the GPT are
# never touched. See docs/persistent-boot.md.
#
#   tools/install-persistent-boot.sh --yes                 # boot_b only
#   tools/install-persistent-boot.sh --yes --vbmeta        # + disable AVB (fallback)
#   tools/install-persistent-boot.sh --yes --restore       # undo from phone/
#
# Safety rules implemented here:
#   * refuses to run without --yes (or --dry-run, which changes nothing);
#   * prints every command before running it;
#   * backs up boot_<slot> (and vbmeta_<slot> with --vbmeta) to phone/ with
#     SHA-256 before any write; `fastboot fetch` is used when the ABL supports
#     it, otherwise the existing stock dump (phone/boot.img) is used and its
#     provenance is recorded;
#   * checks the image is a bootable Android image whose ramdisk is a complete
#     SWEETXNU payload with the required baked command line, fits the
#     partition, and that the device is unlocked and on the expected slot.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PHONE_DIR=${PHONE_DIR:-$ROOT/../phone}
SLOT=""
YES=0
DRY=0
VB=0
REBOOT=0
STOCK_BOOT=""
DEVIMG=0

say()  { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
	cat <<'EOF'
usage: tools/install-persistent-boot.sh --yes [options]

  --yes                required; actually flash (without it nothing is written)
  --dry-run            print the commands, do not flash (no --yes needed)
  --vbmeta             also flash the active vbmeta slot with verification
                       disabled (fallback if a normal boot stops on AVB)
  --reboot             run `fastboot reboot` at the end (default: print it)
  --image PATH         boot image (default: shim/out/shim-boot-alioth.img)
  --slot a|b           override the slot reported by getvar (default: current)
  --stock-boot PATH    stock boot image to use if the phone cannot be fetched
                       (default: phone/boot_<slot>.img, then phone/boot.img)
  --dev-image-cmdline  add root=/dev/ram0 to the boot image header cmdline
                       (a copy is flashed). QCOM ABL then skips A/B retry
                       counter decrements for this "dev image". Needs this when
                       slot-successful:<slot> is not yes.
  --restore            hand over to tools/persistent-boot-restore.sh
  --phone-dir DIR      backup directory (default: ../phone next to the repo)
  -h, --help           this text

Nothing is ever written to boot_a unless it is the active slot, and the other
slot is always left untouched.
EOF
}

# ---- argument parsing (before anything touches the device) -----------------
while [ $# -gt 0 ]; do
	case "$1" in
		--yes|-y) YES=1 ;;
		--dry-run|-n) DRY=1 ;;
		--vbmeta) VB=1 ;;
		--reboot) REBOOT=1 ;;
		--restore) shift; exec "$ROOT/tools/persistent-boot-restore.sh" "$@" ;;
		--image) [ $# -ge 2 ] || die "--image needs a value"; IMAGE=$2; shift ;;
		--image=*) IMAGE=${1#*=} ;;
		--slot) [ $# -ge 2 ] || die "--slot needs a value"; SLOT=$2; shift ;;
		--slot=*) SLOT=${1#*=} ;;
		--stock-boot) [ $# -ge 2 ] || die "--stock-boot needs a value"; STOCK_BOOT=$2; shift ;;
		--stock-boot=*) STOCK_BOOT=${1#*=} ;;
		--dev-image-cmdline) DEVIMG=1 ;;
		--phone-dir) [ $# -ge 2 ] || die "--phone-dir needs a value"; PHONE_DIR=$2; shift ;;
		--phone-dir=*) PHONE_DIR=${1#*=} ;;
		-h|--help) usage; exit 0 ;;
		*) die "unknown argument: $1 (try --help)" ;;
	esac
	shift
done

if [ "$YES" != 1 ] && [ "$DRY" != 1 ]; then
	die "refusing to flash without --yes (use --dry-run to see the commands)"
fi

# ---- image selection --------------------------------------------------------
if [ -z "${IMAGE:-}" ]; then
	IMAGE=$ROOT/shim/out/shim-boot-alioth.img
	if [ ! -f "$IMAGE" ] && [ -f "$ROOT/../ios-sweet/shim/out/shim-boot-alioth.img" ]; then
		IMAGE=$ROOT/../ios-sweet/shim/out/shim-boot-alioth.img
	fi
fi
[ -f "$IMAGE" ] || die "no boot image at $IMAGE (build it, or pass --image PATH)"
IMAGE=$(cd "$(dirname "$IMAGE")" && pwd)/$(basename "$IMAGE")

# ---- fastboot helpers -------------------------------------------------------
FB=(fastboot)

have_device() {
	timeout -k 3 10 "${FB[@]}" devices 2>/dev/null | awk 'NF && $2 ~ /fastboot/ { found=1 } END { exit !found }'
}

fbvar() {
	# `fastboot getvar` writes to stderr; some builds prefix "(bootloader) ".
	# The timeout matters: a wedged Xiaomi ABL otherwise blocks forever.
	timeout -k 5 15 "${FB[@]}" getvar "$1" 2>&1 |
		sed -n -e 's/^(bootloader) //' -e "s/^$1: //p" | head -n1
}

run() {
	printf '+'
	printf ' %q' "$@"
	printf '\n'
	[ "$DRY" = 1 ] || "$@"
}

# ---- preflight: is this really a self-sufficient persistent image? ----------
say "== image: $IMAGE"
python3 - "$IMAGE" <<'PY'
import os, struct, sys

path = sys.argv[1]
d = open(path, 'rb').read()
size = len(d)
fail = lambda m: (print('error: ' + m, file=sys.stderr), sys.exit(1))

if d[:8] != b'ANDROID!':
    fail('not an Android boot image (magic is %r)' % d[:8])

hv = struct.unpack_from('<I', d, 40)[0]
if hv == 2:
    page = struct.unpack_from('<I', d, 36)[0]
    ks   = struct.unpack_from('<I', d, 8)[0]
    rs   = struct.unpack_from('<I', d, 16)[0]
    if page not in (2048, 4096, 8192, 16384):
        fail('bad v2 page size %d' % page)
    rd_off = page * (1 + (ks + page - 1) // page)
    hdr_cmd = d[64:64+512].split(b'\0')[0].decode('ascii', 'replace')
elif hv == 3:
    fail('header v3 has no base DTB/cmdline; this plan needs the self-contained '
         'v2 image that already boots via fastboot boot')
else:
    fail('unsupported boot header version %d' % hv)

if rd_off + 0x48 + 608 > size:
    fail('ramdisk/payload offset %d is outside the %d-byte image' % (rd_off, size))
if d[rd_off:rd_off+8] != b'SWEETXNU':
    fail('ramdisk is not a SWEETXNU payload (found %r): a normal boot would stop '
         'in the UFS probe screen' % d[rd_off:rd_off+8])
cl = d[rd_off+0x48:rd_off+0x48+608].split(b'\0')[0].decode('ascii', 'replace')
toks = cl.split()
need = ['rd=ufsroot0', 'sweettouch=1', 'sweetkeys=1',
        'batteryhakios=1', 'usbhakios=1']
missing = [t for t in need if t not in toks]
if not any(t.startswith('cpus=') for t in toks):
    missing.append('cpus=')
if missing:
    fail('payload cmdline is missing %s' % ', '.join(missing))
print('   header v%d, page %d, image %d B, shim %d B, payload %d B'
      % (hv, page, size, ks, rs))
print('   baked cmdline (%d chars): %s' % (len(cl), cl))
PY

IMG_SIZE=$(stat -c %s "$IMAGE")

# ---- device / slot / partition size ----------------------------------------
FB_TIMEOUT=15
if [ "$DRY" = 1 ] && ! have_device; then
	warn 'no fastboot device in dry-run; assuming slot b and skipping size checks'
	SLOT=${SLOT:-b}
	PSIZE=0
else
	have_device || die 'no device in fastboot (unlock the screen and run: fastboot devices)'
	[ -n "$SLOT" ] || SLOT=$(fbvar current-slot)
	if [ -z "$SLOT" ] && [ "$DRY" = 1 ]; then
		warn 'could not read current-slot (ABL wedged?); assuming b in dry-run'
		SLOT=b
	fi
	[ "$SLOT" = a ] || [ "$SLOT" = b ] || die "getvar current-slot returned '$SLOT'"
	UNLOCKED=$(fbvar unlocked)
	SECURE=$(fbvar secure)
	VERITY=$(fbvar verity)
	SLOTCOUNT=$(fbvar slot-count)
	say "== device: slot=$SLOT (slot-count=${SLOTCOUNT:-?}) unlocked=${UNLOCKED:-?} " \
	    "secure=${SECURE:-?} verity=${VERITY:-unsupported}"
	if [ "$UNLOCKED" = yes ]; then
		:
	elif [ -z "$UNLOCKED" ] && [ "$DRY" = 1 ]; then
		warn 'could not read unlocked (ABL wedged?); continuing dry-run'
	else
		die "bootloader is not unlocked (unlocked='${UNLOCKED:-nothing}'); " \
		    "an unsigned boot image will not load"
	fi
	PSIZE_HEX=$(fbvar "partition-size:boot_$SLOT")
	if [ -n "$PSIZE_HEX" ]; then
		PSIZE=$((PSIZE_HEX))
		say "== boot_$SLOT partition: $PSIZE B ($((PSIZE / 1048576)) MiB)"
		[ "$IMG_SIZE" -le "$PSIZE" ] ||
			die "image ($IMG_SIZE B) does not fit boot_$SLOT ($PSIZE B)"
		if [ "$IMG_SIZE" -gt $((PSIZE / 2)) ]; then
			warn "image uses more than half of boot_$SLOT"
		fi
	elif [ "$DRY" = 1 ]; then
		warn 'could not read partition-size (ABL wedged?); skipping dry-run size check'
	else
		die "getvar partition-size:boot_$SLOT returned nothing"
	fi
	# read-only A/B bookkeeping: this decides whether ABL decrements retries
	RETRY=$(fbvar "slot-retry-count:$SLOT" || true)
	SUCCESS=$(fbvar "slot-successful:$SLOT" || true)
	say "== slot-$SLOT: successful=${SUCCESS:-unknown} retry-count=${RETRY:-unknown}"
	if [ "$SUCCESS" = yes ]; then
		say "   (marked successful: ABL will not decrement the A/B retry counter)"
	elif [ "$DEVIMG" = 1 ]; then
		say "   (--dev-image-cmdline: adding root= so ABL treats this as a dev image)"
	elif [ "$DRY" = 1 ]; then
		warn "slot-$SLOT is not known successful here; a real run will require " \
		    "--dev-image-cmdline"
	else
		warn "slot-$SLOT is not known to be marked successful (getvar said" \
		    "'${SUCCESS:-nothing}'). Qualcomm ABL decrements the retry counter on" \
		    "each normal boot in that state; after ${RETRY:-6} boots it can fall" \
		    "back to the other slot (Android, which may reformat userdata)."
		warn "re-run with --dev-image-cmdline (recommended) to suppress the" \
		    "decrement, or check again after a fresh fastboot."
		die "refusing without --dev-image-cmdline (or a slot known successful=yes)"
	fi
fi

BOOT_PART=boot_$SLOT
VBMETA_PART=vbmeta_$SLOT
mkdir -p "$PHONE_DIR"
say "== backups in: $PHONE_DIR"

# ---- backup boot_<slot> ----------------------------------------------------
# `fastboot fetch` needs max-fetch-size; this ABL does not advertise it. Prefer
# a real fetch when available, otherwise reuse the stock dump already on disk.
fetch_supported() {
	local m
	m=$(fbvar max-fetch-size || true)
	case "$m" in ""|unknown|"not supported"|n/a) return 1 ;; esac
	return 0
}

BOOT_BAK=$PHONE_DIR/$BOOT_PART.img
BOOT_SRC=""
if fetch_supported; then
	say "== backup: fastboot fetch $BOOT_PART -> $BOOT_BAK"
	run "${FB[@]}" fetch "$BOOT_PART" "$BOOT_BAK"
	BOOT_SRC="fastboot fetch $BOOT_PART"
else
	for cand in "$PHONE_DIR/$BOOT_PART.img" "$STOCK_BOOT" "$PHONE_DIR/boot.img"; do
		[ -n "$cand" ] && [ -f "$cand" ] && { BOOT_SRC=$cand; break; }
	done
	[ -n "$BOOT_SRC" ] || die "cannot read $BOOT_PART back and no stock dump found " \
	    "(looked for $PHONE_DIR/$BOOT_PART.img, --stock-boot, $PHONE_DIR/boot.img)"
	say "== backup: $BOOT_SRC -> $BOOT_BAK (no fastboot fetch on this ABL)"
	if [ "$BOOT_SRC" != "$BOOT_BAK" ]; then
		if [ "$DRY" = 1 ]; then
			run cp -f --reflink=auto "$BOOT_SRC" "$BOOT_BAK"
		else
			cp -f --reflink=auto "$BOOT_SRC" "$BOOT_BAK"
		fi
	fi
	if [ "$DRY" = 1 ] && [ ! -f "$BOOT_BAK" ]; then
		warn "dry-run: $BOOT_BAK does not exist yet; not checksumming"
	elif [ "$DRY" = 0 ]; then
		[ "$(head -c 8 "$BOOT_BAK")" = "ANDROID!" ] ||
			die "$BOOT_BAK is not an Android boot image; refusing to use it as a backup"
		( cd "$PHONE_DIR" && sha256sum "$BOOT_PART.img" > "$BOOT_PART.img.sha256" )
	fi
fi

# ---- optional vbmeta backup ------------------------------------------------
VBMETA_BAK=$PHONE_DIR/$VBMETA_PART.img
VBMETA_SRC=""
if [ "$VB" = 1 ]; then
	if fetch_supported; then
		say "== backup: fastboot fetch $VBMETA_PART -> $VBMETA_BAK"
		run "${FB[@]}" fetch "$VBMETA_PART" "$VBMETA_BAK"
		VBMETA_SRC="fastboot fetch $VBMETA_PART"
	else
		for cand in "$PHONE_DIR/$VBMETA_PART.img" "$PHONE_DIR/vbmeta.img"; do
			[ -f "$cand" ] && { VBMETA_SRC=$cand; break; }
		done
		[ -n "$VBMETA_SRC" ] || die "no vbmeta dump found (looked for " \
		    "$PHONE_DIR/$VBMETA_PART.img, $PHONE_DIR/vbmeta.img)"
		say "== backup: $VBMETA_SRC -> $VBMETA_BAK"
		if [ "$VBMETA_SRC" != "$VBMETA_BAK" ]; then
			if [ "$DRY" = 1 ]; then
				run cp -f --reflink=auto "$VBMETA_SRC" "$VBMETA_BAK"
			else
				cp -f --reflink=auto "$VBMETA_SRC" "$VBMETA_BAK"
			fi
		fi
		if [ "$DRY" = 1 ] && [ ! -f "$VBMETA_BAK" ]; then
			warn "dry-run: $VBMETA_BAK does not exist yet; not checksumming"
		elif [ "$DRY" = 0 ]; then
			[ "$(head -c 4 "$VBMETA_BAK")" = "AVB0" ] ||
				die "$VBMETA_BAK is not an AVB0 image"
			( cd "$PHONE_DIR" && sha256sum "$VBMETA_PART.img" > "$VBMETA_PART.img.sha256" )
		fi
	fi
fi

# ---- optional dev-image header cmdline -------------------------------------
# QCOM ABL skips A/B retry-counter decrements when the boot cmdline contains
# "root=" (its "boot dev image" test). The shim never reads the boot header
# cmdline (XNU gets the payload's own cmdline), so this only affects ABL's
# bookkeeping. It is a byte-identical copy of the image except for the 512-byte
# header cmdline field, which is required because we cannot rebuild the image
# without its kernel/ADT inputs.
IMAGE_FLASH=$IMAGE
if [ "$DEVIMG" = 1 ]; then
	IMAGE_FLASH=$PHONE_DIR/persistent-boot-$SLOT.img
	say "== dev-image: $IMAGE -> $IMAGE_FLASH (header cmdline += root=/dev/ram0)"
	python3 - "$IMAGE" "$IMAGE_FLASH" <<'PY'
import struct, sys
src, dst = sys.argv[1], sys.argv[2]
d = bytearray(open(src, 'rb').read())
if d[:8] != b'ANDROID!' or struct.unpack_from('<I', d, 40)[0] != 2:
    sys.exit('error: dev-image patch only supports the v2 shim image')
cmd = bytes(d[64:64+512]).split(b'\0')[0]
if b'root=' not in cmd.split():
    new = (cmd + b' root=/dev/ram0')[:511]
    d[64:576] = new.ljust(512, b'\0')
    print('   header cmdline: %s' % new.decode('ascii', 'replace'))
else:
    print('   header cmdline already contains root=')
open(dst, 'wb').write(d)
PY
	[ "$(stat -c %s "$IMAGE_FLASH")" = "$IMG_SIZE" ] ||
		die "dev-image copy changed size"
	if [ "$DRY" = 0 ]; then
		[ "$(head -c 8 "$IMAGE_FLASH")" = "ANDROID!" ] ||
			die "dev-image copy is not an Android image"
	fi
elif [ "$DRY" = 0 ] && [ "$(dd if="$IMAGE" bs=1 skip=64 count=512 2>/dev/null | tr -d '\0' | grep -c 'root=' || true)" = 0 ]; then
	warn "boot header cmdline has no root=; ABL may decrement the A/B retry counter"
fi

# ---- write the manifest ----------------------------------------------------
if [ "$DRY" = 0 ]; then
	{
		echo "# persistent-boot manifest"
		echo "date=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
		echo "slot=$SLOT"
		echo "boot_part=$BOOT_PART"
		echo "boot_image=$IMAGE"
		echo "boot_image_sha256=$(sha256sum "$IMAGE" | cut -d' ' -f1)"
		echo "flashed_image=$IMAGE_FLASH"
		echo "flashed_image_sha256=$(sha256sum "$IMAGE_FLASH" | cut -d' ' -f1)"
		echo "dev_image_cmdline=$DEVIMG"
		echo "boot_backup=$BOOT_BAK"
		echo "boot_backup_source=$BOOT_SRC"
		[ "$VB" = 1 ] && echo "vbmeta_backup=$VBMETA_BAK"
		[ "$VB" = 1 ] && echo "vbmeta_backup_source=$VBMETA_SRC"
		echo "note=the other boot slot was not written; see docs/persistent-boot.md"
	} > "$PHONE_DIR/persistent-boot.manifest"
	say "== manifest: $PHONE_DIR/persistent-boot.manifest"
fi

# ---- flash ----------------------------------------------------------------
if [ "$SLOT" = a ]; then
	warn "the ACTIVE slot is a; boot_b will be left untouched"
fi
say "== writing $BOOT_PART only"
run "${FB[@]}" flash "$BOOT_PART" "$IMAGE_FLASH"

if [ "$VB" = 1 ]; then
	say "== disabling AVB on $VBMETA_PART (fallback path only)"
	run "${FB[@]}" --disable-verity --disable-verification flash "$VBMETA_PART" "$VBMETA_BAK"
fi

say "== pinning the active slot"
run "${FB[@]}" set_active "$SLOT"

if [ "$REBOOT" = 1 ]; then
	run "${FB[@]}" reboot
else
	OTHER=boot_a
	[ "$SLOT" = a ] && OTHER=boot_b
	EXTRA=""
	[ "$VB" = 1 ] && EXTRA=", $VBMETA_PART"
	cat <<EOF

done (writes: $BOOT_PART$EXTRA; $OTHER untouched).

next:
  unplug USB, then press Power once and let it start normally.
  Watch for "SHIM sweet milestone 4" then "LOADER" with an empty reason.
  If it shows "LOADER no SWEETXNU payload" or the UFS probe screen, it did not
  boot the payload: force off (Power ~10 s), Power+Volume-Down for fastboot,
  then:
      tools/persistent-boot-restore.sh --yes
  (or: fastboot flash $BOOT_PART $BOOT_BAK)

to undo later:
  tools/persistent-boot-restore.sh --yes$([ "$VB" = 1 ] && echo " --vbmeta")
EOF
fi
