#!/usr/bin/env bash
#
# Talk to usbsh on the phone over the usb=2 CDC-ACM serial port.
#
# The kernel's USB serial port carries the kernel log until the computer types
# something; then usbsh (hakios-port-usb/userland/src/usbsh.c, launchd job
# com.hakios.usbsh) takes the input, prints a banner and an "ios:<cwd># " prompt,
# echoes each line, and runs it: builtins (ls, cat, b64, cd, pwd, dmesg, ...) or
# a program with arguments. "log" gives the port back to the kernel log.
#
# Usage:
#   tools/sweet-usbsh.sh                     interactive shell
#   tools/sweet-usbsh.sh 'ls /'              one command, its output
#   tools/sweet-usbsh.sh -g /etc/hosts hosts download a file (usbsh "b64")
#   tools/sweet-usbsh.sh -g /var/tmp/usbmux.log -
#                                            ... to stdout
#
# Options:
#   -d DEV    serial device (default: $SWEET_USB_PORT, else the first /dev/ttyACM*)
#   -b BAUD   baud (default 115200; a CDC-ACM gadget ignores it)
#   -t SEC    seconds to wait for each prompt (default 10; b64 transfers use 60)
#   -l        keep the kernel log printed during the handshake
#   -g REMOTE [LOCAL]
#             download REMOTE with usbsh's "b64"; LOCAL "-" or omitted = stdout
#
# There is no upload command in usbsh: file access is read-only (cat/b64); a
# write would need a new builtin in usbsh.c. See docs/usb-shell.md.
#
# The byte-level protocol needs exact reads (newlines, binary-ish b64), so the
# I/O is done by the embedded Python below; this file stays the user interface.
set -u
exec python3 - "$@" <<'PY'
import base64, glob, os, re, select, sys, termios, time

def usage(code=2):
    print(__doc__ or "usage: sweet-usbsh.sh [-d DEV] [-b BAUD] [-t SEC] [-l] [-g REMOTE [LOCAL]] [COMMAND...]",
          file=sys.stderr)
    raise SystemExit(code)

port = os.environ.get("SWEET_USB_PORT", "")
baud = int(os.environ.get("SWEET_USB_BAUD", "115200"))
timeout = 10.0
keep_log = False
get = False
args = sys.argv[1:]
i = 0
while i < len(args):
    a = args[i]
    if a in ("-h", "--help"):
        usage(0)
    elif a == "-d":
        i += 1; port = args[i]
    elif a == "-b":
        i += 1; baud = int(args[i])
    elif a == "-t":
        i += 1; timeout = float(args[i])
    elif a == "-l":
        keep_log = True
    elif a == "-g":
        get = True
        i += 1
        if i >= len(args): usage()
        remote = args[i]
    else:
        break
    i += 1
rest = args[i:]

if get:
    local = rest[0] if rest else "-"
else:
    local = None

if not port:
    ports = sorted(glob.glob("/dev/ttyACM*"))
    if not ports:
        print("sweet-usbsh: no serial port (set SWEET_USB_PORT or -d DEV)", file=sys.stderr)
        print("  the phone must be booted with usb=2 and usbhakios=1", file=sys.stderr)
        raise SystemExit(2)
    port = ports[0]

try:
    fd = os.open(port, os.O_RDWR | os.O_NOCTTY)
except OSError as e:
    print(f"sweet-usbsh: cannot open {port}: {e.strerror} (permissions? dialout group?)", file=sys.stderr)
    raise SystemExit(2)

# Raw, no echo, 8N1. A CDC-ACM gadget ignores the line rate; keep it anyway.
try:
    attrs = termios.tcgetattr(fd)
    attrs[0] = 0                                      # iflag
    attrs[1] = 0                                      # oflag
    attrs[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
    attrs[3] = 0                                      # lflag: no echo/canonical
    attrs[6][termios.VMIN] = 0
    attrs[6][termios.VTIME] = 0
    speeds = {9600: termios.B9600, 115200: termios.B115200, 921600: termios.B921600}
    if baud in speeds:
        attrs[4] = attrs[5] = speeds[baud]
    termios.tcsetattr(fd, termios.TCSANOW, attrs)
except termios.error as e:
    print(f"sweet-usbsh: cannot configure {port}: {e}", file=sys.stderr)
    raise SystemExit(2)

PROMPT = re.compile(rb"ios:[^#\r\n]*# ")

def read_until(want, seconds):
    """Read until WANT usbsh prompts are in the buffer; return bytes or None."""
    buf = bytearray()
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        r, _, _ = select.select([fd], [], [], 0.2)
        if not r:
            continue
        try:
            chunk = os.read(fd, 65536)
        except OSError as e:
            if e.errno == 5:      # EIO: the gadget went away
                break
            raise
        if not chunk:
            continue
        buf += chunk
        if len(PROMPT.findall(buf)) >= want:
            return bytes(buf)
    return None

def read_until_marker(marker, seconds):
    """Read until MARKER is in the buffer; return bytes or None."""
    buf = bytearray()
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        r, _, _ = select.select([fd], [], [], 0.2)
        if not r:
            continue
        try:
            chunk = os.read(fd, 65536)
        except OSError as e:
            if e.errno == 5:
                break
            raise
        if not chunk:
            continue
        buf += chunk
        if marker in buf:
            return bytes(buf)
    return None

def show(data):
    sys.stdout.buffer.write(data.replace(b"\r\n", b"\n").replace(b"\r", b"\n"))
    sys.stdout.buffer.flush()

def bail(msg, data=None):
    if data:
        sys.stdout.buffer.write(data.replace(b"\r", b"\n"))
        sys.stdout.buffer.flush()
    print(f"sweet-usbsh: {msg}", file=sys.stderr)
    raise SystemExit(1)

# One write for the non-interactive cases: a bare CR takes the port (usbsh
# prints its banner and a first prompt), then the command and its CR. Waiting
# for the second prompt is what makes this race-free.
def takeover(cmd):
    os.write(fd, b"\r" + cmd.encode() + b"\r")

if get:
    takeover("b64 " + remote)
    data = read_until_marker(b"b64: END", 60)
    if data is None:
        bail(f"no answer to b64 {remote}")
    if b"b64: BEGIN " not in data:
        bail("b64 failed", data)
    m = re.search(rb"^b64: BEGIN \d+\r?\n(.*?)^b64: END", data, re.M | re.S)
    if not m:
        bail("b64 output is truncated", data)
    try:
        blob = base64.b64decode(m.group(1))
    except Exception as e:
        bail(f"cannot decode b64: {e}", data)
    if local == "-":
        sys.stdout.buffer.write(blob)
        sys.stdout.buffer.flush()
    else:
        with open(local, "wb") as f:
            f.write(blob)
        print(f"sweet-usbsh: wrote {local}", file=sys.stderr)
    raise SystemExit(0)

if rest:
    takeover(" ".join(rest))
    data = read_until(2, timeout)
    if data is None:
        bail("no prompt after the command", data)
    text = data.replace(b"\r\n", b"\n").replace(b"\r", b"\n")
    lines = text.decode(errors="replace").split("\n")
    out = [l for l in lines
           if l and not l.startswith("--- usbsh: the log is paused")
           and not re.match(r"^ios:.*# ", l)]
    if out:
        print("\n".join(out))
    raise SystemExit(0)

# Interactive: handshake, then one line per prompt.
os.write(fd, b"\r")
data = read_until(1, timeout)
if data is None:
    bail("no usbsh prompt (is usb=2 set and usbsh installed/running?)")
if keep_log:
    show(data)
else:
    show(b"".join(l + b"\n" for l in data.split(b"\n")
                  if l.startswith(b"--- usbsh: the log is paused")))
try:
    while True:
        line = sys.stdin.readline()
        if line == "":
            break
        line = line.rstrip("\n")
        if line in ("exit", "quit"):
            break
        os.write(fd, line.encode() + b"\r")
        data = read_until(1, timeout)
        if data is None:
            bail("no prompt; the link may have gone")
        show(data)
except KeyboardInterrupt:
    pass
finally:
    os.close(fd)
PY
