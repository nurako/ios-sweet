#!/bin/sh
# Read the phone's USB serial console (the hakios DWC3 gadget, 1209:316d
# "HakiOS K40") into a file, prefixed with a timestamp, until interrupted.
#
#   tools/sweet-usb-console.sh [outfile]
#
# The port is /dev/ttyACM0 and the kernel writes the same lines it puts on the
# screen. It survives the port going away and coming back (fastboot, a reboot,
# a re-enumeration), which is what makes it usable across a whole boot cycle.
#
# If the port is not readable:
#   sudo chmod a+rw /dev/ttyACM0
# (or add yourself to the owning group: `sudo usermod -aG uucp "$USER"`).
#
# Stop with Ctrl-C; the file keeps what was read so far.
set -u
port=${SWEET_USB_PORT:-/dev/ttyACM0}
out=${1:-/tmp/sweet-usb-console.log}

echo "waiting for $port, appending to $out (Ctrl-C to stop)" >&2
while :; do
	if [ -c "$port" ] && [ -r "$port" ]; then
		stty -F "$port" -crtscts -ixon -ixoff raw 2>/dev/null || true
		stdbuf -oL cat "$port" 2>/dev/null | while IFS= read -r line; do
			printf '%s %s\n' "$(date +%H:%M:%S)" "$line"
		done | tee -a "$out"
	fi
	sleep 1
done
