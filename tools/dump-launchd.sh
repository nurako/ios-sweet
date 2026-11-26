#!/bin/sh
# Print the shape of the iOS root's launchd job list (read-only).
# The job list on this root is /System/Library/xpc/launchd.plist, not the
# LaunchDaemons directory: jobs must be added there as inline definitions.
#
#   sudo tools/dump-launchd.sh
set -e

here=$(cd "$(dirname "$0")" && pwd)
root=$here/..
[ -f "$root/ios-root/ios16-root-alioth.img" ] || root=$here/../..
img=${IMG:-$root/ios-root/ios16-root-alioth.img}
mnt=${MNT:-/tmp/iosro}

[ -f "$img" ] || { echo "no image at $img" >&2; exit 1; }
mkdir -p "$mnt"
mountpoint -q "$mnt" && umount "$mnt" || true
mount -o loop,ro "$img" "$mnt"

python3 - "$mnt/System/Library/xpc/launchd.plist" <<'PY'
import plistlib, sys, pprint
path = sys.argv[1]
d = plistlib.load(open(path, 'rb'))
print("top keys:", list(d)[:10])
for key, val in d.items():
    if isinstance(val, dict) and val:
        print(f"\n{key}: {len(val)} entries")
        keys = list(val)[:2]
        print("first keys:", keys)
        for k in keys:
            print(f"\n--- {k}")
            pprint.pprint(val[k], width=130, sort_dicts=False)
        break
PY

umount "$mnt"
