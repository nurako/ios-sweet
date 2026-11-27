#!/bin/sh
#
# check-patch-sources.sh: catch a patch that no longer matches the sources it is
# generated from. This is what went wrong with 0200 once: the sources changed but
# the generated patch still carried the old files, so CI built the old driver.
#
# For every patch given (default: 0200, 0300, 0400, 0500, 0501), find the files
# the patch CREATES, reconstruct each post-image from the patch's +lines, and
# compare it with the tree's copy of that file. Files with no separate source
# copy in this repo (config files, patch-only drivers) are listed as skipped.
#
# Usage: tools/check-patch-sources.sh [--quiet] [PATCH...]
# Exit 0 if every file with a source copy matches, 1 with the differing names.
set -eu

cd "$(dirname "$(readlink -f "$0")")/.."

quiet=0
if [ "${1:-}" = "--quiet" ]; then
	quiet=1
	shift
fi

if [ $# -eq 0 ]; then
	set -- xnu/patches/0200-hakios-gpu.patch \
	       xnu/patches/0300-hakios-usb.patch \
	       xnu/patches/0400-sweetbox.patch \
	       xnu/patches/0500-hakios-battery.patch \
	       xnu/patches/0501-hakios-haptic-torch.patch
fi

python3 - "$quiet" "$@" <<'PY'
import os
import re
import sys

ROOT = os.getcwd()
QUIET = sys.argv[1] == '1'

# Where the repository keeps the source of each file 0200 creates.  A file not
# here that is created only by a patch has no second copy to drift from.
SOURCES = {
    'bsd/dev/hakios.adreno.c': 'hakios-port/kernel/bsd/dev/hakios.adreno.c',
    'bsd/dev/hakios.board.c': 'hakios-port/kernel/bsd/dev/hakios.board.c',
    'bsd/dev/hakios_gpu_adapter.c': 'hakios-port/adapter/hakios_gpu_adapter.c',
    'bsd/sys/hakios.board.h': 'hakios-port/kernel/bsd/sys/hakios.board.h',
    'bsd/sys/hakios.input.h': 'hakios-port/kernel/bsd/sys/hakios.input.h',
    'iokit/Kernel/MiniDrivers.h': 'hakios-port/kernel/iokit/Kernel/MiniDrivers.h',
    'iokit/Kernel/MiniIOSurface.h': 'hakios-port/kernel/iokit/Kernel/MiniIOSurface.h',
    'iokit/Kernel/hakios.gpu.cpp': 'hakios-port/kernel/iokit/Kernel/hakios.gpu.cpp',
    'iokit/Kernel/hakios_miniosurface_stub.cpp': 'hakios-port/adapter/hakios_miniosurface_stub.cpp',
}

def created_files(patch):
    """path -> post-image bytes, for every file the patch creates."""
    text = open(patch, encoding='utf-8', errors='surrogateescape').read()
    out = {}
    for part in re.split(r'(?m)^(?=diff --git )', text):
        m = re.match(r'diff --git a/(\S+) b/(\S+)\n', part)
        if not m:
            continue
        path = m.group(2)
        if 'new file mode' not in part.split('\n')[1]:
            continue
        lines = []
        in_hunk = False
        for line in part.splitlines(keepends=True):
            if line.startswith('@@'):
                in_hunk = True
                continue
            if not in_hunk:
                continue
            if line.startswith('+'):
                lines.append(line[1:])
            elif line.startswith('\\'):
                continue
            elif line.startswith(' '):
                lines.append(line[1:])
        out[path] = ''.join(lines).encode('utf-8', 'surrogateescape')
    return out

bad = []
checked = 0
skipped = []
for patch in sys.argv[2:]:
    if not os.path.isfile(patch):
        print(f'check-patch-sources: no such patch: {patch}', file=sys.stderr)
        sys.exit(1)
    for path, wanted in created_files(patch).items():
        source = SOURCES.get(path)
        if source is None:
            skipped.append((patch, path))
            continue
        try:
            have = open(os.path.join(ROOT, source), 'rb').read()
        except OSError:
            bad.append((patch, path, source, 'source missing'))
            continue
        checked += 1
        if have != wanted:
            bad.append((patch, path, source, 'content differs'))

for patch, path, source, why in bad:
    print(f'{why}: {patch} says {path}, source {source}', file=sys.stderr)
if not QUIET:
    for patch, path in skipped:
        print(f'skipped (no source copy): {patch} {path}')
if bad:
    print(f'check-patch-sources: {len(bad)} file(s) differ, {checked} checked', file=sys.stderr)
    sys.exit(1)
print(f'check-patch-sources: {checked} file(s) match their sources, {len(skipped)} skipped')
PY
