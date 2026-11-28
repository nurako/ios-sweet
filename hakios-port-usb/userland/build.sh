#!/usr/bin/env bash
#
# Build the two userland programs of the xiongnemo/hakios-alioth USB stack:
#
#   usbsh   the shell on the usb=2 CDC-ACM serial port (/dev/hakios-usb)
#   usbmux  the phone's side of Apple's usbmux on the usb=3 iPhone port
#
# They are ordinary dynamically linked iOS 16 arm64 programs. Two private
# interfaces are used and must be in the SDK/link line:
#   * usbmux calls MGCopyAnswer() from /usr/lib/libMobileGestalt.dylib
#     (-lMobileGestalt; a Theos SDK carries its stub, a stock Xcode SDK may not)
#   * usbsh calls proc_kmsgbuf() from libSystem (no header in the SDK)
#
# Usage:
#   ./build.sh                 # build into out/
#   IOS_SDK=/path ./build.sh   # explicit iPhoneOS SDK
#   CLANG=/path/clang ./build.sh
#
# It does NOT run on a plain Linux box without an iPhoneOS SDK: see
# hakios-port-usb/PORT-NOTES.md, "Userland build".
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

find_sdk() {
	if [ -n "${IOS_SDK:-}" ]; then
		printf '%s\n' "$IOS_SDK"
		return
	fi
	if command -v xcrun >/dev/null 2>&1; then
		xcrun --sdk iphoneos --show-sdk-path 2>/dev/null && return
	fi
	local d
	for d in "${THEOS:-$HOME/theos}"/sdks/iPhoneOS*.sdk; do
		[ -d "$d" ] && { printf '%s\n' "$d"; return; }
	done
	return 1
}

find_clang() {
	if [ -n "${CLANG:-}" ]; then
		printf '%s\n' "$CLANG"
		return
	fi
	if command -v xcrun >/dev/null 2>&1 && xcrun --find clang >/dev/null 2>&1; then
		xcrun --find clang
		return
	fi
	command -v clang
}

if ! SDK=$(find_sdk); then
	cat >&2 <<'EOF'
build.sh: no iPhoneOS SDK found.

These are iOS userland programs, not kernel code: they need the iOS SDK
headers and libraries. A stock Linux box has neither.

Options:
  * macOS with Xcode:            IOS_SDK=$(xcrun --sdk iphoneos --show-sdk-path) ./build.sh
  * Linux/macOS with Theos:      IOS_SDK=~/theos/sdks/iPhoneOS16.5.sdk ./build.sh
    (the Theos SDK is the one the reference uses; it has libMobileGestalt.tbd)
  * set IOS_SDK=/path/to/iPhoneOSXX.Y.sdk explicitly.

See hakios-port-usb/PORT-NOTES.md, section "Userland build", for the exact
recipe, signing and install path into our iOS root.
EOF
	exit 2
fi

CLANG_BIN=$(find_clang) || { echo "build.sh: no clang" >&2; exit 2; }

MIN_IOS="${MIN_IOS:-16.0}"
CFLAGS=(-arch arm64 -isysroot "$SDK" -miphoneos-version-min="$MIN_IOS" -O2 -Wall -Wextra)
mkdir -p out

echo "SDK:   $SDK"
echo "clang: $CLANG_BIN"

# usbsh: libSystem only (proc_kmsgbuf is declared by hand in the source).
"$CLANG_BIN" "${CFLAGS[@]}" -o out/usbsh src/usbsh.c

# usbmux: CoreFoundation (MGCopyAnswer answer is a CFString) and MobileGestalt.
if ! "$CLANG_BIN" "${CFLAGS[@]}" -framework CoreFoundation -lMobileGestalt \
	-o out/usbmux src/usbmux.c; then
	cat >&2 <<'EOF'
build.sh: usbmux link failed. If the error is "-lMobileGestalt not found",
this SDK has no stub for the private library. Use the Theos iPhoneOS16.5 SDK,
or add a two-symbol libMobileGestalt.tbd:

  --- libMobileGestalt.tbd ---
  --- !tapi-tbd
  tbd-version: 4
  targets: [ arm64-ios ]
  install-name: '/usr/lib/libMobileGestalt.dylib'
  exports:
    - targets: [ arm64-ios ]
      symbols: [ _MGCopyAnswer ]
  ...
EOF
	exit 1
fi

if command -v ldid >/dev/null 2>&1; then
	# Our kernel's miniamfi does not check signatures, but an ad-hoc signature
	# keeps iOS's own checks (and codesign -d) happy.
	ldid -S out/usbsh out/usbmux
	echo "signed (ad-hoc, ldid)"
elif command -v codesign >/dev/null 2>&1; then
	codesign -s - out/usbsh out/usbmux
	echo "signed (ad-hoc, codesign)"
else
	echo "note: no ldid/codesign; the binaries are unsigned (fine for miniamfi)" >&2
fi

ls -l out/usbsh out/usbmux
