#!/usr/bin/env bash
#
# Build xiongnemo/ios-gpu-check unchanged, with this tree's SDK and clang, into
# an unsigned IPA. Upstream's own build.sh does the same; this wrapper only
# supplies CC/SDK from our variables and pins the checkout.
#
#   GPU_CHECK_SRC=/path/to/ios-gpu-check ./build-gpu-check.sh
#   IOS_SDK=... CLANG=... GPU_CHECK_SRC=... ./build-gpu-check.sh
#
# GPU_CHECK_SRC defaults to /tmp/opencode/ios-gpu-check; clone it with
#   git clone https://github.com/xiongnemo/ios-gpu-check /tmp/opencode/ios-gpu-check
# Upstream is frozen at 7c73b33 (2026-11-22); its README says the GPU page moved
# to xiongnemo/ios-system-check.
#
# OUT defaults to <src>/build; the IPA is $OUT/GPUCheck.ipa.
set -euo pipefail
HERE=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
SRC=${GPU_CHECK_SRC:-/tmp/opencode/ios-gpu-check}

find_sdk() {
	if [ -n "${IOS_SDK:-}" ]; then printf '%s\n' "$IOS_SDK"; return; fi
	if command -v xcrun >/dev/null 2>&1; then xcrun --sdk iphoneos --show-sdk-path 2>/dev/null && return; fi
	return 1
}
find_clang() {
	if [ -n "${CLANG:-}" ]; then printf '%s\n' "$CLANG"; return; fi
	if command -v xcrun >/dev/null 2>&1; then xcrun --find clang; return; fi
	return 1
}

[ -f "$SRC/main.m" ] || {
	echo "build-gpu-check.sh: no main.m in $SRC (set GPU_CHECK_SRC)" >&2
	exit 2
}
SDK=$(find_sdk) || { echo "build-gpu-check.sh: no iPhoneOS SDK (set IOS_SDK)" >&2; exit 2; }
CLANG_BIN=$(find_clang) || { echo "build-gpu-check.sh: no clang (set CLANG)" >&2; exit 2; }

# LDID is optional: upstream signs with Entitlements.plist (which asks for
# nothing) when ldid is on PATH and leaves the linker's signature otherwise.
echo "source: $SRC"
echo "SDK:    $SDK"
echo "clang:  $CLANG_BIN"
(CC="$CLANG_BIN" SDK="$SDK" OUT="${OUT:-$SRC/build}" "$SRC/build.sh")
ls -l "${OUT:-$SRC/build}/GPUCheck.ipa"
