#!/usr/bin/env bash
#
# CI entry point: Mesa/freedreno + the DRM client + gl_test in one step.
# Called by the userland workflow (see userland.yml.patch), on macOS only.
#
# Produces:
#   out/libOSMesa.8.dylib
#   out/gl_test
#   out/exported-gl.txt, out/gl.xml, out/built-from
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

if [ -z "${IOS_SDK:-}" ]; then
	echo "build-userland-gpu.sh: IOS_SDK is not set" >&2
	exit 2
fi
if [ -z "${CLANG:-}" ] && command -v xcrun >/dev/null 2>&1; then
	CLANG=$(xcrun --find clang)
fi

./build-mesa.sh
./build.sh
