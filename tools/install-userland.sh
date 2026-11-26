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
# the image lives in ios-root/ of the workspace, which is either the repo root
# or the directory above it (this repo is ios-sweet/ inside the workspace)
root=$repo
[ -f "$root/ios-root/ios16-root-alioth.img" ] || root=$(cd "$repo/.." && pwd)
img=${IMG:-$root/ios-root/ios16-root-alioth.img}
simg=${SIMG:-$root/ios-root/ios16-root-alioth.simg}
mnt=${MNT:-$root/ios-root/mnt}

[ "$(id -u)" = 0 ] || { echo "run me with sudo" >&2; exit 1; }
[ -f "$img" ] || { echo "no image at $img" >&2; exit 1; }
[ -d "$art" ] || { echo "no artifact dir at $art" >&2; exit 1; }

echo "== fsck before"
fsck.hfsplus -f "$img" || true

echo "== mount $img at $mnt"
mkdir -p "$mnt"
# The iOS boots leave the HFS+ journal dirty, and Linux mounts such a volume
# read-only unless forced (`force` skips the journal; fsck above and below
# check the metadata itself).
if ! mount -o loop,rw,force "$img" "$mnt" 2>/dev/null; then
	mount -o loop,rw "$img" "$mnt"
fi
if ! touch "$mnt/.sweet-write-test" 2>/dev/null; then
	echo "still read-only: try 'sudo umount $mnt' and re-run" >&2
	umount "$mnt" 2>/dev/null
	exit 1
fi
rm -f "$mnt/.sweet-write-test"

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
