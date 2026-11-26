#!/bin/sh
# Build the SWEETBOX autorun helper for the iOS 16 root (arm64, A11: no
# arm64e), ad-hoc signed. The kernel's SWEET AMFI stand-in (0035/0036) marks
# signed binaries on the root volume as platform binaries, so no other
# signature is needed.
#
#   userland/build.sh          -> userland/out/sweet-autorun
#
# Needs macOS with Xcode (xcrun iphoneos SDK + codesign).
set -eu
cd "$(dirname "$0")"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
CC="xcrun --sdk iphoneos clang -arch arm64 -mios-version-min=16.0 -isysroot $SDK -O2 -Wall -Wextra"
mkdir -p out
$CC -o out/sweet-autorun sweet-autorun.c
codesign -f -s - out/sweet-autorun
echo "out/sweet-autorun"
