#!/bin/sh
# Read the phone's USB serial console (the hakios DWC3 gadget, 1209:316d
# "HakiOS K40") into a file, prefixed with a timestamp, until interrupted.
#
#   tools/sweet-usb-console.sh [outfile]
#
# The port is /dev/ttyACM0 and the kernel writes the same lines it puts on the
# screen. If the port is not readable:
#   sudo chmod a+rw /dev/ttyACM0
# (or add yourself to the owning group: `sudo usermod -aG uucp "$USER"`).
#
# Stop with Ctrl-C; the file keeps what was read so far.
set -u
port=${SWEET_USB_PORT:-/dev/ttyACM0}
out=${1:-/tmp/sweet-usb-console.log}

if [ ! -c "$port" ]; then
	echo "no $port: is the phone booted with usbhakios=1 usb=2?" >&2
	exit 1
fi
if [ ! -r "$port" ]; then
	echo "$port is not readable: sudo chmod a+rw $port" >&2
	exit 1
fi

echo "reading $port into $out (Ctrl-C to stop)" >&2
stty -F "$port" -crtscts -ixon -ixoff raw 2>/dev/null || true
# One reader only: `stdbuf` keeps the file current so another tool can tail it.
stdbuf -oL cat "$port" 2>/dev/null | while IFS= read -r line; do
	printf '%s %s\n' "$(date +%H:%M:%S)" "$line"
done | tee -a "$out"
