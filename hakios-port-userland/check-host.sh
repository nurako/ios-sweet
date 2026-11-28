#!/usr/bin/env bash
#
# The checks that can be run on a Linux host without the iOS SDK:
#   * C syntax of the DRM client and the OSMesa adapter via check-shims/
#   * gl_test syntax (format warnings for uint64_t are expected on Linux)
#   * shell/Python syntax, and the CI patch against the real userland.yml
#
# It does NOT build Mesa, link, sign or run anything for iOS.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

CC=${CC:-clang}
command -v "$CC" >/dev/null 2>&1 || { echo "check-host.sh: $CC not found" >&2; exit 2; }

"$CC" -fsyntax-only -Wall -Wextra -I check-shims -include check-shims/compat.h \
	-I hakios-drm hakios-drm/hakios.drm.c
echo 'check-host.sh: hakios.drm.c syntax OK'

"$CC" -fsyntax-only -Wall -Wextra -I check-shims userland/gl_test.c
echo 'check-host.sh: gl_test.c syntax OK (uint64_t format warnings are Linux-only)'

"$CC" -fsyntax-only -Wall -Wextra -I check-shims userland/gl_osmesa.c
echo 'check-host.sh: gl_osmesa.c syntax OK'

for s in *.sh; do bash -n "$s"; done
echo 'check-host.sh: shell syntax OK'

python3 -m py_compile userland/mkeagl.py
rm -rf userland/__pycache__
echo 'check-host.sh: mkeagl.py OK'

if [ -f ../../ios-sweet-main/.github/workflows/userland.yml ]; then
	tmp=$(mktemp -d)
	mkdir -p "$tmp/.github/workflows"
	cp ../../ios-sweet-main/.github/workflows/userland.yml "$tmp/.github/workflows/"
	git -C "$tmp" init -q
	git -C "$tmp" add .
	git -C "$tmp" -c user.email=check@example -c user.name=check commit -qm base
	git -C "$tmp" apply --check "$(pwd)/userland.yml.patch"
	rm -rf "$tmp"
	echo 'check-host.sh: userland.yml.patch applies'
else
	echo 'check-host.sh: ios-sweet-main/workflows/userland.yml not present; patch not checked'
fi
