#!/usr/bin/env python3
"""SWEETBOX: install files into the running iOS root without reflashing.

The kernel patch 0400 reserves 1 MiB in `userdata` immediately before the
persistent console-log ring (last 1025 blocks). This tool packs files into
that area and writes it through recovery ADB, the same raw path
`tools/sweet-log-pull.sh` uses. The mailbox is applied on the NEXT boot, by
`bsd_init` after the root mounts and before launchd; see docs/sweetbox.md.

  # pack (DST=SRC pairs; DST starting with ROOT/ installs on the root)
  tools/sweet-box.py pack box.bin hello=/build/hello \\
      ROOT/System/Library/LaunchDaemons/com.example.plist=job.plist \\
      autorun.sh=autorun.sh

  # phone in OrangeFox recovery with ADB, apply it
  tools/sweet-box.py apply box.bin
  tools/sweet-box.py status
  tools/sweet-box.py clear

Format (little endian, 4096-byte blocks, 256 blocks = 1 MiB):
  header 32 B: "SWEETBOX" | u32 version=1 | u32 nfiles |
               u32 payload_len | u32 payload_crc32 | u32 state |
               u32 header_crc32 (over the first 28 bytes)
  entry:       u16 namelen | name | u32 size | u32 crc32 | data
state 0 = pending (the only state this tool writes), 1 = installed,
2 = failed. A payload is never trusted: the kernel checks two CRCs before
it opens any file.
"""
import os
import struct
import subprocess
import sys
import zlib

MAGIC = b'SWEETBOX'
VERSION = 1
BLOCK = 4096
BOX_BLOCKS = 256                 # 1 MiB, must match sweet_ufs.c
LOG_BLOCKS = 1025                # 1 header + 4 MiB ring, unchanged since 0047
BOX_BYTES = BOX_BLOCKS * BLOCK
HEADER = struct.Struct('<8sIIIIII')
MAX_FILES = 64
MAX_NAME = 255
STATE_PENDING, STATE_DONE, STATE_FAILED = 0, 1, 2
STATE_NAMES = {STATE_PENDING: 'pending (applies on next boot)',
               STATE_DONE: 'installed', STATE_FAILED: 'failed'}


def header_crc(fields):
    return zlib.crc32(HEADER.pack(*fields)[:-4]) & 0xffffffff


def pack_header(nfiles, payload_len, payload_crc, state=STATE_PENDING):
    fields = (MAGIC, VERSION, nfiles, payload_len, payload_crc, state, 0)
    fields = fields[:-1] + (header_crc(fields),)
    return HEADER.pack(*fields)


def parse_header(data):
    if len(data) < HEADER.size:
        raise SystemExit('short mailbox read')
    fields = HEADER.unpack_from(data, 0)
    if fields[0] != MAGIC:
        return None
    magic, version, nfiles, plen, pcrc, state, hcrc = fields
    if version != VERSION or hcrc != header_crc(fields):
        raise SystemExit(f'bad header (version {version}, crc {hcrc:#x})')
    if nfiles > MAX_FILES or plen > BOX_BYTES - HEADER.size:
        raise SystemExit(f'bad sizes (files {nfiles}, payload {plen})')
    return {'nfiles': nfiles, 'payload_len': plen, 'payload_crc': pcrc,
            'state': state}


def iter_entries(payload, nfiles):
    cur = 0
    for _ in range(nfiles):
        if cur + 2 > len(payload):
            raise SystemExit('truncated entry')
        namelen, = struct.unpack_from('<H', payload, cur)
        cur += 2
        if not namelen or namelen > MAX_NAME or cur + namelen + 8 > len(payload):
            raise SystemExit('bad entry')
        name = payload[cur:cur + namelen].decode('utf-8', 'replace')
        cur += namelen
        size, crc = struct.unpack_from('<II', payload, cur)
        cur += 8
        if cur + size > len(payload):
            raise SystemExit(f'{name}: overruns payload')
        yield name, size, crc, payload[cur:cur + size]
        cur += size


def cmd_pack(args):
    if len(args) < 2:
        raise SystemExit('usage: pack OUT DST=SRC [DST=SRC ...]')
    out = args[0]
    pairs = []
    for item in args[1:]:
        if '=' not in item:
            raise SystemExit(f'expected DST=SRC, got {item!r}')
        dst, src = item.split('=', 1)
        pairs.append((dst, src))
    if len(pairs) > MAX_FILES:
        raise SystemExit(f'too many files ({len(pairs)} > {MAX_FILES})')
    payload = bytearray()
    for dst, src in pairs:
        name = dst.encode('utf-8')
        if not name or len(name) > MAX_NAME or b'\0' in name:
            raise SystemExit(f'bad destination name {dst!r}')
        with open(src, 'rb') as f:
            data = f.read()
        payload += struct.pack('<H', len(name)) + name
        payload += struct.pack('<II', len(data), zlib.crc32(data) & 0xffffffff)
        payload += data
        print(f'  + {dst}  ({len(data)} bytes)')
    if len(payload) > BOX_BYTES - HEADER.size:
        raise SystemExit(f'payload {len(payload)} B > {BOX_BYTES - HEADER.size} B mailbox')
    blob = pack_header(len(pairs), len(payload),
                       zlib.crc32(payload) & 0xffffffff) + bytes(payload)
    blob += b'\0' * (BOX_BYTES - len(blob))
    with open(out, 'wb') as f:
        f.write(blob)
    roots = sum(1 for d, _ in pairs if d.startswith('ROOT/'))
    print(f'=> {out}: {len(blob)} bytes, {len(pairs)} files ({roots} root), '
          f'state 0 (applies on the next boot)')


def adb_prefix(args):
    serial = None
    rest = list(args)
    if rest[:1] == ['-s']:
        if len(rest) < 2:
            raise SystemExit('-s needs a serial')
        serial, rest = rest[1], rest[2:]
    return (['adb', '-s', serial] if serial else ['adb']), rest


def adb_shell(adb, cmd):
    return subprocess.run(adb + ['shell', cmd], check=True,
                          capture_output=True, text=True).stdout.strip().replace('\r', '')


def device_area(adb):
    dev = adb_shell(adb, 'for d in /dev/block/by-name/userdata '
                         '/dev/block/bootdevice/by-name/userdata; '
                         'do [ -e $d ] && readlink -f $d && break; done')
    if not dev:
        raise SystemExit('userdata block device not found (phone in recovery with adb?)')
    size = int(adb_shell(adb, f'blockdev --getsize64 {dev}'))
    skip = size // BLOCK - (LOG_BLOCKS + BOX_BLOCKS)
    if skip <= 0:
        raise SystemExit(f'{dev} is too small ({size} bytes)')
    return dev, size, skip


def cmd_apply(args):
    adb, rest = adb_prefix(args)
    if len(rest) != 1:
        raise SystemExit('usage: apply [-s SERIAL] BOX.bin')
    box = rest[0]
    data = open(box, 'rb').read()
    if len(data) != BOX_BYTES:
        raise SystemExit(f'{box} is {len(data)} bytes, expected {BOX_BYTES}')
    h = parse_header(data)
    if h is None:
        raise SystemExit(f'{box} has no SWEETBOX header')
    if zlib.crc32(data[HEADER.size:HEADER.size + h['payload_len']]) & 0xffffffff != h['payload_crc']:
        raise SystemExit(f'{box}: payload CRC mismatch (do not write it)')
    if h['state'] != STATE_PENDING:
        raise SystemExit(f'{box}: state is {h["state"]}, repack it')
    dev, size, skip = device_area(adb)
    print(f'{dev}: {size} bytes; mailbox blocks {skip}..{skip + BOX_BLOCKS - 1} '
          f'({BOX_BYTES} bytes, just before the log ring)')
    print('writing only that area (never the HFS image); applying on next boot')
    adb_push = adb + ['push', box, '/tmp/sweetbox.bin']
    subprocess.run(adb_push, check=True)
    adb_shell(adb, f'dd if=/tmp/sweetbox.bin of={dev} bs={BLOCK} seek={skip} '
                   f'count={BOX_BLOCKS} conv=notrunc,fsync')
    adb_shell(adb, 'sync')
    got = subprocess.run(adb + ['exec-out', f'dd if={dev} bs={BLOCK} '
                               f'skip={skip} count={BOX_BLOCKS} 2>/dev/null'],
                         check=True, capture_output=True).stdout
    if got[:len(data)] != data:
        raise SystemExit('read-back differs from the packed box (write failed?)')
    print(f'OK: {len(data)} bytes written and read back; {h["nfiles"]} files '
          f'will be applied on the next boot with sweetbox=1')


def cmd_pull(args):
    adb, rest = adb_prefix(args)
    if len(rest) != 1:
        raise SystemExit('usage: pull [-s SERIAL] OUT.bin')
    dev, _, skip = device_area(adb)
    data = subprocess.run(adb + ['exec-out', f'dd if={dev} bs={BLOCK} '
                                f'skip={skip} count={BOX_BLOCKS} 2>/dev/null'],
                          check=True, capture_output=True).stdout
    with open(rest[0], 'wb') as f:
        f.write(data)
    print(f'{dev}: read mailbox blocks {skip}..{skip + BOX_BLOCKS - 1} -> {rest[0]}')


def cmd_clear(args):
    adb, rest = adb_prefix(args)
    if rest:
        raise SystemExit('usage: clear [-s SERIAL]')
    dev, _, skip = device_area(adb)
    adb_shell(adb, f'dd if=/dev/zero of={dev} bs={BLOCK} seek={skip} count=1 '
                   f'conv=notrunc,fsync')
    adb_shell(adb, 'sync')
    print(f'cleared the mailbox header block {skip} on {dev}; next boot ignores it')


def cmd_status(args):
    adb, rest = adb_prefix(args)
    if rest:
        raise SystemExit('usage: status [-s SERIAL]')
    dev, _, skip = device_area(adb)
    data = subprocess.run(adb + ['exec-out', f'dd if={dev} bs={BLOCK} '
                                f'skip={skip} count={BOX_BLOCKS} 2>/dev/null'],
                          check=True, capture_output=True).stdout
    h = parse_header(data)
    if h is None:
        print(f'{dev}: no SWEETBOX mailbox (blocks {skip}..{skip + BOX_BLOCKS - 1})')
        return
    crc = zlib.crc32(data[HEADER.size:HEADER.size + h['payload_len']]) & 0xffffffff
    print(f'{dev}: mailbox blocks {skip}..{skip + BOX_BLOCKS - 1}')
    print(f'  state: {STATE_NAMES.get(h["state"], h["state"])}')
    print(f'  files: {h["nfiles"]}, payload {h["payload_len"]} bytes, '
          f'CRC {"OK" if crc == h["payload_crc"] else "BAD"}')
    try:
        for name, size, fcrc, body in iter_entries(
                data[HEADER.size:HEADER.size + h['payload_len']], h['nfiles']):
            print(f'  {"ROOT " if name.startswith("ROOT/") else "     "}'
                  f'{name}  ({size} B, {"ok" if zlib.crc32(body) & 0xffffffff == fcrc else "BAD"})')
    except SystemExit as e:
        print(f'  entries unreadable: {e}')


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return
    sub, args = sys.argv[1], sys.argv[2:]
    commands = {'pack': cmd_pack, 'apply': cmd_apply, 'pull': cmd_pull,
                'clear': cmd_clear, 'status': cmd_status}
    if sub not in commands:
        raise SystemExit(f'unknown subcommand {sub!r}; see --help')
    commands[sub](args)


if __name__ == '__main__':
    main()
