#!/bin/sh
# Get the phone into the bootloader's fastboot, from wherever it is.
#
# The A/B retry counters take a failed `boot_b` to recovery (OrangeFox), and
# from there the phone has adb; so a power-on plus this script is enough, with
# no button combination:
#
#   recovery (adb)  --adb reboot fastboot-->  fastbootd
#   fastbootd       --fastboot reboot bootloader-->  bootloader fastboot
#
# If the phone is already in fastboot this returns at once.
set -eu

wait_for() {   # wait_for <command> <seconds>
	want=$1
	limit=$2
	i=0
	while [ $i -lt "$limit" ]; do
		if eval "$want" >/dev/null 2>&1; then
			return 0
		fi
		sleep 1
		i=$((i + 1))
	done
	return 1
}

have_adb() { command -v adb >/dev/null 2>&1 && adb devices 2>/dev/null | awk 'NR>1 {print $2}' | grep -qxE 'device|recovery|sideload'; }
have_fb()  { command -v fastboot >/dev/null 2>&1 && fastboot devices 2>/dev/null | grep -qw fastboot; }
have_fbd() { command -v fastboot >/dev/null 2>&1 && fastboot devices 2>/dev/null | grep -qw fastbootd; }

say() { printf 'sweet-fastboot: %s\n' "$1"; }

if have_fb; then
	say "the phone is already in the bootloader's fastboot"
	exit 0
fi

# fastbootd is *not* enough: `fastboot boot` needs the bootloader.
if have_fbd; then
	say "in fastbootd; asking for the bootloader"
	fastboot reboot bootloader >/dev/null 2>&1 || true
	wait_for have_fb 30 && { say "in the bootloader's fastboot"; exit 0; }
	say "fastbootd did not reach the bootloader"
	exit 1
fi

if have_adb; then
	mode=$(adb shell getprop ro.bootmode 2>/dev/null | tr -d '\r' || true)
	say "adb is up (bootmode: ${mode:-unknown}); asking for fastboot"
	adb reboot fastboot >/dev/null 2>&1 || true
	if wait_for have_fbd 40; then
		say "fastbootd is up; asking for the bootloader"
		fastboot reboot bootloader >/dev/null 2>&1 || true
		wait_for have_fb 30 && { say "in the bootloader's fastboot"; exit 0; }
	fi
	# Some recoveries answer `reboot bootloader` directly.
	adb reboot bootloader >/dev/null 2>&1 || true
	wait_for have_fb 30 && { say "in the bootloader's fastboot"; exit 0; }
	say "adb is up but neither fastbootd nor the bootloader answered"
	exit 1
fi

say "no phone found (no fastboot, no fastbootd, no adb); power it on first"
exit 1
