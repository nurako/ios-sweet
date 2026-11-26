#!/usr/bin/env bash
#
# Build Mesa 25.0.7 for iOS 16.5 as the OpenGL ES library the hakios DRM
# transport talks through: softpipe + freedreno/MSM, OSMesa frontend, no EGL,
# no GBM, no Vulkan, no LLVM.  This is the reference's tools/mk-mesa.sh,
# reduced to what the OpenGL ES path needs (the AIR/Metal frontend is not
# built here; see PORT-NOTES.md).
#
# The result is one dylib:
#   out/libOSMesa.8.dylib   install name ${INSTALL_LIBDIR}/libOSMesa.8.dylib
# and two files used by the deferred EAGL build:
#   out/exported-gl.txt, out/gl.xml
#
# Requirements (macOS): Xcode command line tools, meson, ninja, bison, flex,
# python3 (a venv with Mako/pyyaml/packaging is made here), llvm-ar/llvm-strip.
#
# Usage:
#   IOS_SDK=~/theos/sdks/iPhoneOS16.5.sdk ./build-mesa.sh
#   CLANG=$(xcrun --find clang) IOS_SDK=$(xcrun --sdk iphoneos --show-sdk-path) ./build-mesa.sh
#   INSTALL_LIBDIR=/var/local/lib ./build-mesa.sh
#
# It cannot run on this Linux box: Mesa's cross build needs the iOS SDK.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
ROOT=$(pwd)

VERSION=25.0.7
SHA256=592272df3cf01e85e7db300c449df5061092574d099da275d19e97ef0510f8a6
BUILD=${BUILD:-$ROOT/build}
SRC=$BUILD/mesa-$VERSION
OUT=$ROOT/out
INSTALL_LIBDIR=${INSTALL_LIBDIR:-/var/local/lib}

find_sdk() {
	if [ -n "${IOS_SDK:-}" ]; then printf '%s\n' "$IOS_SDK"; return; fi
	if command -v xcrun >/dev/null 2>&1; then
		xcrun --sdk iphoneos --show-sdk-path 2>/dev/null && return
	fi
	return 1
}
find_clang() {
	if [ -n "${CLANG:-}" ]; then printf '%s\n' "$CLANG"; return; fi
	if command -v xcrun >/dev/null 2>&1; then xcrun --find clang; return; fi
	command -v clang
}
find_tool() {  # $1 name, $2 xcrun name
	if command -v "$1" >/dev/null 2>&1; then command -v "$1"; return; fi
	if command -v xcrun >/dev/null 2>&1; then xcrun --find "$2" 2>/dev/null && return; fi
	return 1
}

SDK=$(find_sdk) || {
	echo "build-mesa.sh: no iPhoneOS SDK. Set IOS_SDK to iPhoneOS16.5.sdk (Theos) or use Xcode." >&2
	exit 2
}
CC=$(find_clang)
AR=$(find_tool llvm-ar llvm-ar) || { echo "build-mesa.sh: llvm-ar not found" >&2; exit 2; }
RANLIB=$(find_tool llvm-ranlib llvm-ranlib) || { echo "build-mesa.sh: llvm-ranlib not found" >&2; exit 2; }
STRIP=$(find_tool llvm-strip llvm-strip) || { echo "build-mesa.sh: llvm-strip not found" >&2; exit 2; }
for t in meson ninja bison flex python3; do
	command -v "$t" >/dev/null 2>&1 || { echo "build-mesa.sh: $t is missing" >&2; exit 2; }
done

mkdir -p "$BUILD" "$OUT"

hash_ok() {
	if command -v shasum >/dev/null 2>&1; then
		echo "$SHA256  $1" | shasum -a 256 -c --quiet
	else
		echo "$SHA256  $1" | sha256sum -c --quiet
	fi
}

PATCHES=$(cat "$ROOT"/mesa/patches/*.patch | (command -v shasum >/dev/null 2>&1 && shasum -a 256 || sha256sum) | cut -d' ' -f1)
if [ ! -d "$SRC" ] || [ "$(cat "$SRC/.hakios-patches" 2>/dev/null || true)" != "$PATCHES" ]; then
	[ -f "$BUILD/mesa-$VERSION.tar.xz" ] || \
		curl -sL --fail -o "$BUILD/mesa-$VERSION.tar.xz" "https://archive.mesa3d.org/mesa-$VERSION.tar.xz"
	hash_ok "$BUILD/mesa-$VERSION.tar.xz"
	rm -rf "$SRC" "$BUILD"/build-*
	tar xJf "$BUILD/mesa-$VERSION.tar.xz" -C "$BUILD"
	for p in "$ROOT"/mesa/patches/*.patch; do
		echo "build-mesa.sh: $(basename "$p")"
		patch -s --no-backup-if-mismatch -d "$SRC" -p1 < "$p"
	done
	echo "$PATCHES" > "$SRC/.hakios-patches"
fi
# The stand-in for libdrm: always the current copy, never patched into Mesa.
rm -rf "$SRC/src/hakios-drm"
cp -r "$ROOT/hakios-drm" "$SRC/src/hakios-drm"

if [ ! -x "$BUILD/venv/bin/python3" ]; then
	python3 -m venv "$BUILD/venv"
	"$BUILD/venv/bin/pip" -q install mako pyyaml packaging
fi
export PATH=$BUILD/venv/bin:$PATH

cat > "$BUILD/cross.ini" <<INI
[binaries]
c = ['$CC', '-arch', 'arm64', '-isysroot', '$SDK']
cpp = ['$CC++', '-arch', 'arm64', '-isysroot', '$SDK', '-fuse-cxa-atexit']
objc = ['$CC', '-arch', 'arm64', '-isysroot', '$SDK']
ar = '$AR'
ranlib = '$RANLIB'
strip = '$STRIP'
pkg-config = 'false'

[host_machine]
system = 'darwin'
subsystem = 'ios'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'

[properties]
needs_exe_wrapper = true
INI

DRIVERS=${DRIVERS:-softpipe,freedreno}
BDIR=$BUILD/build-${DRIVERS//,/-}
if [ ! -f "$BDIR/build.ninja" ]; then
	meson setup "$BDIR" "$SRC" --cross-file "$BUILD/cross.ini" --wrap-mode=nofallback \
		--prefix=/usr/local --libdir=lib --buildtype=release -Db_ndebug=true \
		-Dplatforms= -Dgallium-drivers="$DRIVERS" -Dfreedreno-kmds=msm -Dvulkan-drivers= \
		-Dglx=disabled -Degl=disabled -Dgbm=disabled -Dosmesa=true -Dllvm=disabled \
		-Dshared-glapi=enabled -Dgles1=enabled -Dgles2=enabled -Dopengl=true \
		-Dzstd=disabled -Dxmlconfig=disabled -Dexpat=disabled -Dshader-cache=enabled \
		-Dvalgrind=disabled -Dlibunwind=disabled -Dglvnd=disabled -Dvideo-codecs= \
		-Dtools= -Dgallium-vdpau=disabled -Dgallium-va=disabled -Dgallium-xa=disabled \
		-Dlmsensors=disabled -Dbuild-tests=false 2>&1 | tee "$BUILD/meson-setup.log"
fi
ninja -C "$BDIR" 2>&1 | tee "$BUILD/ninja.log"

LIB=$BDIR/src/gallium/targets/osmesa/libOSMesa.8.dylib
"$STRIP" -x -o "$OUT/libOSMesa.8.dylib" "$LIB"
install_name_tool -id "$INSTALL_LIBDIR/libOSMesa.8.dylib" "$OUT/libOSMesa.8.dylib"
nm -gU "$OUT/libOSMesa.8.dylib" | awk '{print $NF}' | grep '^_gl' | sed 's/^_//' | sort -u \
	> "$OUT/exported-gl.txt"
cp "$SRC/src/mapi/glapi/registry/gl.xml" "$OUT/gl.xml"
cat "$ROOT"/mesa/patches/*.patch "$ROOT"/hakios-drm/* | \
	(command -v shasum >/dev/null 2>&1 && shasum -a 256 || sha256sum) > "$OUT/built-from"

echo "build-mesa.sh: Mesa $VERSION ($DRIVERS): $OUT/libOSMesa.8.dylib, $(stat -f%z "$OUT/libOSMesa.8.dylib" 2>/dev/null || stat -c%s "$OUT/libOSMesa.8.dylib") bytes, $(wc -l < "$OUT/exported-gl.txt") gl* functions"
echo "build-mesa.sh: install name $INSTALL_LIBDIR/libOSMesa.8.dylib"
