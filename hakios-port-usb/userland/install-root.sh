#!/usr/bin/env bash
#
# Install the built usbmux/usbsh and their launchd jobs into an iOS root image
# or a mounted root volume.
#
#   ./install-root.sh /path/to/mounted/root
#   BINDIR=/redwood/bin JOBDIR=/redwood/LaunchDaemons ./install-root.sh /path
#
# Our root is the stock iPhone X 16.7.16 HFS+ volume from tools/mkiosroot.sh,
# with none of the reference's /redwood ramdisk: the default install is
# /usr/local/bin and /System/Library/LaunchDaemons, both writable on our unsealed root.
# The reference plists name /redwood/bin, so the path is rewritten on install.
#
# Run build.sh first; this copies out/usbsh and out/usbmux.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

ROOT=${1:-}
BINDIR=${BINDIR:-/usr/local/bin}
JOBDIR=${JOBDIR:-/System/Library/LaunchDaemons}

if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then
	echo "usage: $0 /path/to/mounted/ios/root   (BINDIR=... JOBDIR=... override)" >&2
	exit 2
fi
for f in out/usbsh out/usbmux; do
	[ -x "$f" ] || { echo "$0: $f is missing; run ./build.sh first" >&2; exit 2; }
done

install -d "$ROOT$BINDIR" "$ROOT$JOBDIR"
install -m 0755 out/usbsh out/usbmux "$ROOT$BINDIR/"

for job in com.hakios.usbmux.plist com.hakios.usbsh.plist; do
	# The plist's ProgramArguments is /redwood/bin/<name>; follow BINDIR.
	sed "s#/redwood/bin/#$BINDIR/#g" "$job" > "$ROOT$JOBDIR/$job"
	chmod 0644 "$ROOT$JOBDIR/$job"
done
# launchd refuses group-writable jobs; install -m and chmod above see to it.

echo "installed:"
echo "  $ROOT$BINDIR/usbmux   (usb=3; needs lockdownd running)"
echo "  $ROOT$BINDIR/usbsh    (usb=2; the CDC-ACM shell)"
echo "  $ROOT$JOBDIR/com.hakios.usbmux.plist"
echo "  $ROOT$JOBDIR/com.hakios.usbsh.plist"
echo
echo "If the root is a file image, copy it back to userdata with the usual"
echo "tools (or mount it on the phone); then boot with usb=2 (shell) or usb=3 (mux)."
