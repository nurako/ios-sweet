#!/usr/bin/env bash
# Undo tools/install-persistent-boot.sh: put the stock boot image back.
#
#   tools/persistent-boot-restore.sh --yes                 # boot_<slot>
#   tools/persistent-boot-restore.sh --yes --vbmeta        # also stock vbmeta
#   tools/persistent-boot-restore.sh --yes --slot b
#
# Defaults to the slot in phone/persistent-boot.manifest, else getvar
# current-slot. Verifies the SHA-256 written at install time before flashing.
# Never touches the other slot, dtbo, super, recovery, modem, persist, userdata
# or the GPT. Refuses to run without --yes and prints every command first.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PHONE_DIR=${PHONE_DIR:-$ROOT/../phone}
SLOT=""
YES=0
DRY=0
VB=0
REBOOT=0

say()  { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
	cat <<'EOF'
usage: tools/persistent-boot-restore.sh --yes [options]

  --yes              required; actually flash
  --dry-run          print commands, touch nothing (no --yes needed)
  --vbmeta           restore the stock vbmeta for the slot too
  --reboot           run `fastboot reboot` at the end (default: print it)
  --slot a|b         slot to restore (default: manifest, then current-slot)
  --phone-dir DIR    backup directory (default: ../phone next to the repo)
  -h, --help         this text
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--yes|-y) YES=1 ;;
		--dry-run|-n) DRY=1 ;;
		--vbmeta) VB=1 ;;
		--reboot) REBOOT=1 ;;
		--slot) [ $# -ge 2 ] || die "--slot needs a value"; SLOT=$2; shift ;;
		--slot=*) SLOT=${1#*=} ;;
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

FB=(fastboot)

have_device() {
	timeout -k 3 10 "${FB[@]}" devices 2>/dev/null | awk 'NF && $2 ~ /fastboot/ { found=1 } END { exit !found }'
}

fbvar() {
	timeout -k 5 15 "${FB[@]}" getvar "$1" 2>&1 |
		sed -n -e 's/^(bootloader) //' -e "s/^$1: //p" | head -n1
}

run() {
	printf '+'
	printf ' %q' "$@"
	printf '\n'
	[ "$DRY" = 1 ] || "$@"
}

[ -d "$PHONE_DIR" ] || die "no backup directory at $PHONE_DIR"

if [ -z "$SLOT" ] && [ -f "$PHONE_DIR/persistent-boot.manifest" ]; then
	SLOT=$(sed -n 's/^slot=//p' "$PHONE_DIR/persistent-boot.manifest" | head -n1)
fi
if [ -z "$SLOT" ]; then
	if [ "$DRY" = 1 ] && ! have_device; then
		warn 'no device in dry-run and no manifest; assuming slot b'
		SLOT=b
	else
		have_device || die 'no device in fastboot and no slot in the manifest'
		SLOT=$(fbvar current-slot)
	fi
fi
[ "$SLOT" = a ] || [ "$SLOT" = b ] || die "unknown slot '$SLOT'"

BOOT_PART=boot_$SLOT
BOOT_BAK=$PHONE_DIR/$BOOT_PART.img
[ -f "$BOOT_BAK" ] || die "no backup at $BOOT_BAK"

# Verify the backup the installer checksummed.
if [ -f "$BOOT_BAK.sha256" ]; then
	say "== verifying $BOOT_BAK.sha256"
	( cd "$PHONE_DIR" && sha256sum -c "$BOOT_PART.img.sha256" )
else
	warn "no $BOOT_BAK.sha256; only checking the header"
	[ "$(head -c 8 "$BOOT_BAK")" = "ANDROID!" ] || die "$BOOT_BAK is not an Android boot image"
fi

say "== restore: writing $BOOT_PART only"
run "${FB[@]}" flash "$BOOT_PART" "$BOOT_BAK"

if [ "$VB" = 1 ]; then
	VBMETA_PART=vbmeta_$SLOT
	VBMETA_BAK=$PHONE_DIR/$VBMETA_PART.img
	[ -f "$VBMETA_BAK" ] || VBMETA_BAK=$PHONE_DIR/vbmeta.img
	[ -f "$VBMETA_BAK" ] || die "no vbmeta backup in $PHONE_DIR"
	if [ -f "$VBMETA_BAK.sha256" ]; then
		say "== verifying $VBMETA_BAK.sha256"
		( cd "$PHONE_DIR" && sha256sum -c "$(basename "$VBMETA_BAK").sha256" )
	else
		[ "$(head -c 4 "$VBMETA_BAK")" = "AVB0" ] || die "$VBMETA_BAK is not an AVB0 image"
	fi
	say "== restoring stock vbmeta (plain flash, no --disable-* flags)"
	run "${FB[@]}" flash "$VBMETA_PART" "$VBMETA_BAK"
fi

if [ "$REBOOT" = 1 ]; then
	run "${FB[@]}" reboot
else
	cat <<EOF

done. $BOOT_PART is the stock image again; the other slot was not touched.
Unplug USB, then press Power for a normal boot.
If the phone is in a bootloop, hold Power ~10 s, then Power+Volume-Down for
fastboot and re-run this script.
EOF
fi
