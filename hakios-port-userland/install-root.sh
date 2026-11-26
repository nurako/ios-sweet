#!/usr/bin/env bash
#
# Install the Mesa/freedreno userland into an iOS root image or a mounted root:
#   LIBDIR/libOSMesa.8.dylib
#   BINDIR/gl_test
#   JOBDIR/com.hakios.gltest.plist  (only with JOBS=1)
#
# Our root has no /redwood (unlike the reference), so the defaults are paths
# the SWEETBOX allowlist already accepts:
#   /var/local/lib            the library
#   /usr/local/bin            the test program
#   /System/Library/LaunchDaemons
#
# The dylib's install name is baked in at build time.  If you built with a
# different INSTALL_LIBDIR, build again or this script refuses (dyld would not
# find the library otherwise).
#
# Usage:
#   ./install-root.sh /path/to/mounted/root
#   LIBDIR=/usr/local/lib BINDIR=/usr/local/bin JOBS=1 ./install-root.sh /path
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

ROOT=${1:-}
LIBDIR=${LIBDIR:-/var/local/lib}
BINDIR=${BINDIR:-/usr/local/bin}
JOBDIR=${JOBDIR:-/System/Library/LaunchDaemons}
JOBS=${JOBS:-0}

if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then
	echo "usage: $0 /path/to/mounted/ios/root   (LIBDIR=... BINDIR=... JOBS=1)" >&2
	exit 2
fi
for f in out/gl_test out/libOSMesa.8.dylib; do
	[ -f "$f" ] || { echo "$0: $f is missing; run ./build.sh first" >&2; exit 2; }
done

# Check that dyld will look where we put it.  otool exists on macOS; the
# check is advisory on Linux.
if command -v otool >/dev/null 2>&1; then
	name=$(otool -D out/libOSMesa.8.dylib | sed -n '2p')
	if [ "$name" != "$LIBDIR/libOSMesa.8.dylib" ]; then
		echo "$0: library install name is $name but LIBDIR is $LIBDIR" >&2
		echo "    rebuild with INSTALL_LIBDIR=$LIBDIR ./build-mesa.sh, or set LIBDIR=$(dirname "$name")" >&2
		exit 2
	fi
fi

install -d "$ROOT$LIBDIR" "$ROOT$BINDIR"
install -m 0755 out/libOSMesa.8.dylib "$ROOT$LIBDIR/"
install -m 0755 out/gl_test "$ROOT$BINDIR/"

if [ "$JOBS" = 1 ]; then
	install -d "$ROOT$JOBDIR"
	sed "s#/usr/local/bin/#$BINDIR/#g" userland/com.hakios.gltest.plist > "$ROOT$JOBDIR/com.hakios.gltest.plist"
	chmod 0644 "$ROOT$JOBDIR/com.hakios.gltest.plist"
fi

echo "installed:"
echo "  $ROOT$LIBDIR/libOSMesa.8.dylib"
echo "  $ROOT$BINDIR/gl_test"
if [ "$JOBS" = 1 ]; then
	echo "  $ROOT$JOBDIR/com.hakios.gltest.plist"
fi
