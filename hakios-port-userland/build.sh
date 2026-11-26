#!/usr/bin/env bash
#
# Build the iOS userland half of the hakios Adreno stack:
#   out/gl_test   a triangle drawn through Mesa/freedreno, read back, and put
#                 on the panel with HakiosGPU's kHakiosShow (0x7f)
#
# build-mesa.sh must have produced out/libOSMesa.8.dylib first.
#
# Usage:
#   IOS_SDK=~/theos/sdks/iPhoneOS16.5.sdk ./build.sh
#   CLANG=$(xcrun --find clang) IOS_SDK=$(xcrun --sdk iphoneos --show-sdk-path) ./build.sh
#
# The EAGL/window-server library (libhakios.gl.dylib) is NOT built here: it
# needs userland/eagl.c, which this milestone deliberately defers.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
ROOT=$(pwd)

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

SDK=$(find_sdk) || {
	cat >&2 <<'EOF'
build.sh: no iPhoneOS SDK found.

This builds an iOS arm64 program against Mesa's iOS dylib; a Linux box has
neither the SDK headers nor the frameworks. Use macOS with Xcode, or Theos:

  IOS_SDK=~/theos/sdks/iPhoneOS16.5.sdk ./build.sh
EOF
	exit 2
}
CLANG_BIN=$(find_clang) || { echo "build.sh: no clang" >&2; exit 2; }
[ -f out/libOSMesa.8.dylib ] || {
	echo "build.sh: out/libOSMesa.8.dylib is missing; run ./build-mesa.sh first" >&2
	exit 2
}

MIN_IOS=${MIN_IOS:-16.0}
CFLAGS=(-arch arm64 -isysroot "$SDK" -miphoneos-version-min="$MIN_IOS" -O2 -Wall -Wextra)
mkdir -p out

echo "SDK:   $SDK"
echo "clang: $CLANG_BIN"
"$CLANG_BIN" "${CFLAGS[@]}" -framework CoreFoundation -framework IOKit \
	out/libOSMesa.8.dylib -o out/gl_test userland/gl_test.c

if command -v ldid >/dev/null 2>&1; then
	ldid -S out/gl_test
	echo "signed (ad-hoc, ldid)"
elif command -v codesign >/dev/null 2>&1; then
	codesign -s - out/gl_test
	echo "signed (ad-hoc, codesign)"
else
	echo "note: no ldid/codesign; the binary is unsigned (fine for miniamfi)" >&2
fi

ls -l out/gl_test out/libOSMesa.8.dylib
