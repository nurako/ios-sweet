#!/usr/bin/env bash
#
# Build gpucheck-cli: the off-screen tests of xiongnemo/ios-gpu-check as a
# command-line program against this tree's libOSMesa (no UIKit, no EAGL).
#
# Needs build-mesa.sh's output first, as build.sh does:
#   IOS_SDK=~/theos/sdks/iPhoneOS16.5.sdk ./build.sh
#   ../build-gpucheck-cli.sh
#
# Usage:
#   IOS_SDK=... CLANG=... hakios-port-userland/tools/gpu-check/build-gpucheck-cli.sh
#   OUT=DIR (default hakios-port-userland/out)
set -euo pipefail
HERE=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)                 # hakios-port-userland
OUT=${OUT:-$ROOT/out}

find_sdk() {
	if [ -n "${IOS_SDK:-}" ]; then printf '%s\n' "$IOS_SDK"; return; fi
	if command -v xcrun >/dev/null 2>&1; then xcrun --sdk iphoneos --show-sdk-path 2>/dev/null && return; fi
	return 1
}
find_clang() {
	if [ -n "${CLANG:-}" ]; then printf '%s\n' "$CLANG"; return; fi
	if command -v xcrun >/dev/null 2>&1; then xcrun --find clang; return; fi
	command -v clang
}

SDK=$(find_sdk) || { echo "build-gpucheck-cli.sh: no iPhoneOS SDK (set IOS_SDK)" >&2; exit 2; }
CLANG_BIN=$(find_clang) || { echo "build-gpucheck-cli.sh: no clang" >&2; exit 2; }
[ -f "$OUT/libOSMesa.8.dylib" ] || {
	echo "build-gpucheck-cli.sh: $OUT/libOSMesa.8.dylib is missing; run build-mesa.sh first" >&2
	exit 2
}

MIN_IOS=${MIN_IOS:-16.0}
mkdir -p "$OUT"
echo "SDK:   $SDK"
echo "clang: $CLANG_BIN"
"$CLANG_BIN" -arch arm64 -isysroot "$SDK" -miphoneos-version-min="$MIN_IOS" -O2 -Wall -Wextra \
	-o "$OUT/gpucheck-cli" "$HERE/gpucheck-cli.c" "$OUT/libOSMesa.8.dylib"

if command -v ldid >/dev/null 2>&1; then
	ldid -S "$OUT/gpucheck-cli"
	echo "signed (ad-hoc, ldid)"
elif command -v codesign >/dev/null 2>&1; then
	codesign -s - "$OUT/gpucheck-cli"
	echo "signed (ad-hoc, codesign)"
else
	echo "note: no ldid/codesign; the binary is unsigned (fine for miniamfi)" >&2
fi
ls -l "$OUT/gpucheck-cli"
