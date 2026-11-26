#!/usr/bin/env python3
"""Add (or remove) the SWEETBOX autorun job in an iOS launchd cache.

  tools/sweet-launchd-autorun.py IN.plist OUT.plist [--remove]

IN is the phone's /System/Library/xpc/launchd.plist (pull it from the root
image, or from the phone in recovery with a raw read). OUT is what the first
SWEETBOX box installs as ROOT/System/Library/xpc/launchd.plist. iOS launchd
takes its system jobs from this cache; the job key below adds a RunAtLoad
job that runs /usr/libexec/sweet-autorun, whose stdout the kernel copies
into the log as |sweet-autorun|.

Keep one unmodified copy of the cache as the rescue box: if a later edit
breaks launchd, put the original back through the mailbox on the next boot
(root installs run in bsd_init before launchd reads the cache).
"""
import os
import plistlib
import sys

JOB_KEY = '/System/Library/LaunchDaemons/com.sweet.autorun.plist'
JOB = {
    'Label': 'com.sweet.autorun',
    'ProgramArguments': ['/usr/libexec/sweet-autorun'],
    'RunAtLoad': True,
    'POSIXSpawnType': 'Interactive',
}


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    remove = '--remove' in sys.argv
    if len(args) != 2:
        sys.exit(__doc__)
    src, dst = args
    with open(src, 'rb') as f:
        data = plistlib.load(f)
    jobs = data.setdefault('LaunchDaemons', {})
    if remove:
        if jobs.pop(JOB_KEY, None) is None:
            print(f'{JOB_KEY}: not present')
        else:
            print(f'{JOB_KEY}: removed')
    else:
        jobs[JOB_KEY] = dict(JOB)
        print(f'{JOB_KEY}: added ({JOB["ProgramArguments"][0]})')
    st = os.stat(src)
    with open(dst, 'wb') as f:
        plistlib.dump(data, f, fmt=plistlib.FMT_BINARY)
    try:
        os.chown(dst, st.st_uid, st.st_gid)
    except PermissionError:
        pass
    os.chmod(dst, st.st_mode & 0o7777)
    print(f'=> {dst} ({os.path.getsize(dst)} bytes)')


if __name__ == '__main__':
    main()
