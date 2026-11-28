#!/bin/sh
# Regenerate xnu/patches/0200-hakios-gpu.patch from the sources in this tree.
#
# The patch is applied by CI, the sources live under hakios-port/, and they drift
# apart every time one of them is edited by hand (this has silently shipped an
# old kernel twice).  This script rebuilds the patch from the sources against a
# pristine pre-0200 tree and proves the result:
#
#   1. a CI build tree (0119 applied, 0200..0501 reversed back out) is the
#      baseline; use --run <id> to fetch one, or --tree <dir> to reuse a copy,
#   2. the files 0200 creates are copied in from the sources,
#   3. `git diff` makes the new patch,
#   4. the blocks 0200 edits in place but does not create (bsd/conf/files,
#      bsd/dev/sweet_ufs.c, iokit/conf/files.arm64, osfmk/arm/caches.c,
#      osfmk/arm64/loose_ends.c) are carried over verbatim from the old patch,
#      duplicates included: the downstream patches depend on those exact hunks,
#   5. the result is applied to the baseline and every later patch is applied on
#      top of it, and the created files are compared to the sources byte for
#      byte.
#
# Usage:
#   tools/regen-0200.sh --tree /tmp/btB/xnu        # tree already reversed
#   tools/regen-0200.sh --run 46121023314          # download that run's tree
#
set -eu

REPO=$(cd "$(dirname "$0")/.." && pwd)
PATCH=xnu/patches/0200-hakios-gpu.patch
LATER='0300-hakios-usb 0400-sweetbox 0500-hakios-battery 0501-hakios-haptic-torch'
INPLACE='bsd/conf/files bsd/dev/sweet_ufs.c iokit/conf/files.arm64 osfmk/arm/caches.c osfmk/arm64/loose_ends.c'

tree=
run=
while [ $# -gt 0 ]; do
	case $1 in
	--tree) tree=$2; shift 2 ;;
	--run) run=$2; shift 2 ;;
	*) echo "usage: $0 (--tree DIR | --run ID)" >&2; exit 2 ;;
	esac
done

if [ -z "$tree" ]; then
	[ -n "$run" ] || { echo "need --tree or --run" >&2; exit 2; }
	tmp=$(mktemp -d)
	gh run download "$run" -R nurako/ios-sweet -n xnu-buildtree -D "$tmp" >/dev/null
	tar xzf "$tmp/buildtree.tgz" -C "$tmp"
	tree=$tmp/xnu
	# reverse the patches this tree carries, from the top down
	for p in 0501-hakios-haptic-torch 0500-hakios-battery 0400-sweetbox 0300-hakios-usb 0200-hakios-gpu; do
		f=$(mktemp)
		git -C "$REPO" show "HEAD~0:$PATCH" >/dev/null 2>&1 || true
		git -C "$REPO" show "HEAD:xnu/patches/$p.patch" >"$f"
		git -C "$tree" apply -R "$f" || { echo "cannot reverse $p in $tree" >&2; exit 1; }
	done
fi

[ -f "$tree/bsd/dev/sweet_ufs.c" ] || { echo "no sweet_ufs.c in $tree" >&2; exit 1; }
if [ -f "$tree/bsd/dev/hakios.adreno.c" ]; then
	echo "the tree still has 0200 applied; reverse it first" >&2
	exit 1
fi

# 1. the baseline as a commit, so git can diff against it
git -C "$tree" init -q .
git -C "$tree" add -A
git -C "$tree" -c user.email=a@b -c user.name=a commit -qm baseline

# 2. the files 0200 creates, from the sources
copy() { mkdir -p "$tree/$(dirname "$1")"; cp "$REPO/$2" "$tree/$1"; }
copy bsd/dev/hakios.adreno.c                hakios-port/kernel/bsd/dev/hakios.adreno.c
copy bsd/dev/hakios.board.c                 hakios-port/kernel/bsd/dev/hakios.board.c
copy bsd/dev/hakios_gpu_adapter.c           hakios-port/adapter/hakios_gpu_adapter.c
copy bsd/sys/hakios.board.h                 hakios-port/kernel/bsd/sys/hakios.board.h
copy bsd/sys/hakios.input.h                 hakios-port/kernel/bsd/sys/hakios.input.h
copy iokit/Kernel/MiniDrivers.h             hakios-port/kernel/iokit/Kernel/MiniDrivers.h
copy iokit/Kernel/MiniIOSurface.h           hakios-port/kernel/iokit/Kernel/MiniIOSurface.h
copy iokit/Kernel/hakios.gpu.cpp            hakios-port/kernel/iokit/Kernel/hakios.gpu.cpp
copy iokit/Kernel/hakios_miniosurface_stub.cpp hakios-port/adapter/hakios_miniosurface_stub.cpp

# 3+4. the new patch
git -C "$tree" add -A
git -C "$tree" diff --cached --binary >"$tmp.newfiles"
old=$(mktemp)
git -C "$REPO" show "HEAD:$PATCH" >"$old"
python3 - "$old" "$tmp.newfiles" "$REPO/$PATCH" "$INPLACE" <<'PY'
import sys
old, newf, out, inplace = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4].split()
old = open(old).read()
keep = []
for b in old.split('diff --git ')[1:]:
    p = b.split(' b/')[0]
    if p.startswith('a/'):
        p = p[2:]
    if p in inplace:
        keep.append('diff --git ' + b)
new = open(newf).read()
open(out, 'w').write(new + ''.join(keep))
print(f'kept {len(keep)} in-place block(s)', file=sys.stderr)
PY

# 5. prove it: applies to the baseline, the later patches apply on top, the
#    created files equal the sources
git -C "$tree" reset -q --hard HEAD
git -C "$tree" clean -qfd
git -C "$tree" apply "$REPO/$PATCH" || { echo "0200 does not apply to the baseline" >&2; exit 1; }
for p in $LATER; do
	f=$(mktemp)
	git -C "$REPO" show "HEAD:xnu/patches/$p.patch" >"$f"
	git -C "$tree" apply "$f" || { echo "$p does not apply after 0200" >&2; exit 1; }
done
fail=0
for pair in "bsd/dev/hakios.adreno.c hakios-port/kernel/bsd/dev/hakios.adreno.c" \
            "iokit/Kernel/hakios.gpu.cpp hakios-port/kernel/iokit/Kernel/hakios.gpu.cpp"; do
	set -- $pair
	cmp -s "$tree/$1" "$REPO/$2" || { echo "DIFF $1" >&2; fail=1; }
done
[ "$fail" = 0 ] || exit 1
echo "0200 regenerated: applies, later patches apply, created files match the sources"
