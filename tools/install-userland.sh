#!/bin/sh
# Install the built iOS userland (Mesa, gl_test, usbmux, usbsh) into the iOS
# root image, then rebuild the sparse userdata image. Run as root:
#
#   sudo tools/install-userland.sh <artifact-dir>
#
# <artifact-dir> is what the `userland` GitHub workflow uploads (libOSMesa.8.dylib,
# gl_test, usbmux, usbsh). The image path and the sparse output can be overridden:
#
#   IMG=ios-root/ios16-root-alioth.img SIMG=ios-root/ios16-root-alioth.simg \
#       sudo tools/install-userland.sh /tmp/artifacts
#
# Nothing is flashed here: the sparse image is left for `fastboot flash userdata`.
set -eu

art=${1:?usage: sudo tools/install-userland.sh <artifact-dir>}
repo=$(cd "$(dirname "$0")/.." && pwd)
img=${IMG:-$repo/ios-root/ios16-root-alioth.img}
simg=${SIMG:-$repo/ios-root/ios16-root-alioth.simg}
mnt=${MNT:-$repo/ios-root/mnt}

[ "$(id -u)" = 0 ] || { echo "run me with sudo" >&2; exit 1; }
[ -f "$img" ] || { echo "no image at $img" >&2; exit 1; }
[ -d "$art" ] || { echo "no artifact dir at $art" >&2; exit 1; }

echo "== fsck before"
fsck.hfsplus -f "$img" || true

echo "== mount $img at $mnt"
mkdir -p "$mnt"
mount -o loop,rw "$img" "$mnt"

echo "== install files"
mkdir -p "$mnt/usr/local/lib" "$mnt/usr/local/bin"
for f in libOSMesa.8.dylib; do
	[ -f "$art/$f" ] && cp -f "$art/$f" "$mnt/usr/local/lib/$f" && echo "  /usr/local/lib/$f"
done
for f in gl_test usbmux usbsh; do
	[ -f "$art/$f" ] && cp -f "$art/$f" "$mnt/usr/local/bin/$f" && chmod 755 "$mnt/usr/local/bin/$f" && echo "  /usr/local/bin/$f"
done

echo "== flush and unmount"
sync
umount "$mnt"

echo "== fsck after"
fsck.hfsplus -f "$img" || true

echo "== sparse image -> $simg"
rm -f "$simg"
img2simg "$img" "$simg"
ls -lh "$simg"
echo
echo "next: fastboot flash userdata $simg   (destructive to Android data)"
