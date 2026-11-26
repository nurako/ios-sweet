#!/usr/bin/env python3
"""Add our jobs to the iOS root's launchd job list.

On this root launchd does not scan System/Library/LaunchDaemons for new files:
the authoritative list is /System/Library/xpc/launchd.plist, a dictionary
keyed by plist path with the job definition inline. So a job must be both a
file (for tidiness) and an entry in that list.

    python3 tools/add-launchd-jobs.py <mounted-root>

Idempotent: re-running replaces the two entries.
"""
import os
import plistlib
import sys

JOBS = {
    '/System/Library/LaunchDaemons/com.hakios.usbmux.plist': {
        'Label': 'com.hakios.usbmux',
        'ProgramArguments': ['/usr/local/bin/usbmux'],
        'RunAtLoad': True,
        'KeepAlive': {'SuccessfulExit': False},
        'StandardOutPath': '/dev/console',
        'StandardErrorPath': '/dev/console',
    },
    '/System/Library/LaunchDaemons/com.hakios.gltest.plist': {
        'Label': 'com.hakios.gltest',
        'ProgramArguments': ['/usr/local/bin/gl_test'],
        'EnvironmentVariables': {'DYLD_LIBRARY_PATH': '/usr/local/lib'},
        'RunAtLoad': True,
        'StandardOutPath': '/dev/console',
        'StandardErrorPath': '/dev/console',
    },
}


def main():
    if len(sys.argv) != 2:
        sys.exit('usage: add-launchd-jobs.py <mounted-root>')
    path = os.path.join(sys.argv[1], 'System/Library/xpc/launchd.plist')
    if not os.path.exists(path):
        sys.exit(f'no {path}')
    with open(path, 'rb') as f:
        data = plistlib.load(f)
    jobs = data.setdefault('LaunchDaemons', {})
    for key, job in JOBS.items():
        jobs[key] = job
        print(f'  job {key} ({job["Label"]})')
    with open(path, 'wb') as f:
        plistlib.dump(data, f, fmt=plistlib.FMT_BINARY, sort_keys=False)
    print(f'  launchd.plist now lists {len(jobs)} daemons')


if __name__ == '__main__':
    main()
