# USB shell and file access (alioth, `hakios-usb` branch)

Two different USB personalities, chosen by the `usb=` boot argument. They
share the same kernel driver (`bsd/dev/hakios.usb.c`) and the same
`/dev/hakios-usb`, but only one can own the controller per boot.

| boot arg | the phone looks like | userland | what it is for |
| --- | --- | --- | --- |
| `usb=2` | CDC-ACM serial, `1209:316d` "HakiOS K40" | `usbsh` | a shell and read-only file access over `/dev/ttyACM0` |
| `usb=3` | iPhone, `05ac:12a8`, usbmux interface | `usbmux` + iOS `lockdownd` | host `usbmuxd`/`idevice*`/AFC (`ifuse`), pairing, file access |
| `usb=1` | nothing (read-only probe) | none | diagnostics |

Both need `usbhakios=1` (the master switch in `sweet_ufs.c`) and the shim's
SMR0 write (`shim/loader.c`: `SMR0 = 0x80000000`), which is what makes the
apps SMMU translate stream 0 for DWC3 DMA.

### The log is the invariant; the shell is the exception

The two jobs can be installed together, but they must never race for
`/dev/hakios-usb`. Each program reads `usb=` from `kern.bootargs` **before**
opening anything:

| boot arg | owner of `/dev/hakios-usb` | the other job |
| --- | --- | --- |
| `usb=2` | the kernel log; `usbsh` only after an explicit host request | `usbmux` prints `usb=2, not usb=3` and exits 0 without opening |
| `usb=3` | `usbmux` (iPhone/usbmux device side) | `usbsh` prints `usb=3, not usb=2` and exits 0 without opening |
| anything else | nobody | both exit 0 |

On `usb=2` the kernel log always flows whenever no program has attached.
`usbsh` does **not** open `/dev/hakios-usb` at boot; it blocks on
`/dev/hakios-usb-shell`. A shell is requested by this magic line (the bytes
`1d 1d 53 48 45 4c 4c 0a`; control characters that cannot occur in console
text):

```
\x1d\x1dSHELL\n
```

While in log mode the kernel watches for it. On a match it:

1. stops feeding the log (`usb: host asked for a shell`),
2. writes `--- usbsh: log paused; 'log' resumes it ---` to the port,
3. wakes `usbsh` through `/dev/hakios-usb-shell`.

`usbsh` then opens `/dev/hakios-usb` (`usb: shell took the port`) and prints
`ios:<cwd># `. Reading the port without a request is refused, so an accidental
open cannot silence the log. If no program attaches within 10 s the kernel
returns to log mode. The shell's `log` command, or 120 s with no shell input,
also returns to log mode (`usb: log mode again`). The kernel prints exactly
one transition line per change, and `usbsh` writes `USBSH: ...` state lines to
`/dev/console` (so the persistent ring):

```
usb: log mode
usb: host asked for a shell
usb: shell took the port
usb: log mode again
```

## 1. `usb=2`: the serial shell

The port carries the kernel log until the host sends the magic line. Then:

```
--- usbsh: log paused; 'log' resumes it ---
ios:/# ls /
```

* Input is line based (`\r` or `\n`), echoed, with backspace and Ctrl-C.
* Builtins: `ls`, `cat FILE` (1 MB cap), `b64 FILE`, `cd`, `pwd`, `getenv`,
  `sysctl`, `cs`, `fill FILE MB`, `udp`, `tcpsink`, `tcpsource`, `dmesg`,
  `uname`, `ps`, `kill`, `log`, `help`.
* Anything else is a program plus arguments; a name without `/` is looked up
  in `/redwood/bin /usr/bin /bin /usr/sbin /sbin /usr/libexec`. On our root
  that means it finds the stock iOS programs and whatever is in
  `/usr/local/bin`.
* `log` gives the port back to the kernel log. Send the magic line again to
  return to the shell; 120 s without shell input also returns to the log.
* `b64 FILE` prints:
  ```
  b64: BEGIN <size>
  <base64, 76 columns>
  b64: END
  ```
  `tools/sweet-usbsh.sh -g REMOTE [LOCAL]` parses exactly this and writes the
  bytes (or stdout with `-`).
* There is **no write/upload builtin**. Writes need a program run through the
  shell, or the `usb=3` AFC path below.

Host commands:

```sh
sudo usermod -aG dialout "$USER"     # once, if /dev/ttyACM0 is not accessible
tools/sweet-usbsh.sh                 # interactive (requests the shell, else shows the log)
tools/sweet-usbsh.sh 'uname; ls /usr/local/bin'
tools/sweet-usbsh.sh -g /var/tmp/usbmux.log usbmux.log
tools/sweet-usbsh.sh -g /etc/hosts -
```

`tools/sweet-usbsh.sh` sets the port raw, sends the magic line, and waits up
to `-a` seconds (default 3) for the banner. If the banner does not come it
prints the log stream for `-t` seconds and exits 1, so it is never silent.
Once acknowledged it sends the command, waits for the prompt, and drops the
echoed command + prompts from one-shot output. Options: `-d DEV`, `-b BAUD`,
`-t SEC`, `-a SEC`, `-l` (keep the log during the handshake),
`-g REMOTE [LOCAL]`.

Exact host-side sequence (DTR/RTS are not required by this gadget, but
asserting them is harmless and matches a normal terminal):

```sh
# 1. boot: ... usbhakios=1 usb=2   the port is already streaming the kernel log
# 2. host sees 1209:316d "HakiOS K40" -> /dev/ttyACM0
stty -F /dev/ttyACM0 115200 raw -echo -echoe -echok -crtscts clocal
# 3. request a shell: send the 8 magic bytes (printf's \035 is 0x1d)
printf '\035\035SHELL\n' > /dev/ttyACM0
#    wait for: --- usbsh: log paused; 'log' resumes it ---  then  ios:/#
# 4. send the command and CR:  uname -a\r   wait for the next ios:/# prompt
# 5. "log\r" returns the port to the log; send the magic again for a shell
tools/sweet-usbsh.sh 'uname -a'          # does 2-4 and prints only the answer
```

### `gl_test` markers

The gl_test launchd job runs only when `/var/tmp/run-gl-test` exists. It now
prints `GLTEST: start` before the 5 s delay and `GLTEST: exit N` after the
client returns, so a screen photo or a `sweetlogdump` shows whether the client
started at all. A panic after the start line and before the exit line is the
client itself.

## 2. `usb=3`: the iPhone mux

`usbmux` (userland, `/usr/local/bin/usbmux`) opens `/dev/hakios-usb`, asks the
kernel for the device's UDID (`ioctl HAKIOS_USB_IPHONE`), which is what starts
the iPhone-shaped device side. It then speaks the device end of Apple's usbmux
to the host's `usbmuxd`:

* packets: 8-byte header (`protocol`, `length`, both big-endian) for protocol
  0/version 1, then 16-byte headers (magic `0xfeedface`, `tx_seq`, `rx_seq`)
  after the version-2 setup packet; one packet = one USB transfer;
* protocol 0 = version negotiation, 2 = setup, 6 = TCP;
* TCP payload is a `struct tcphdr` + data. SYN opens a connection to
  `127.0.0.1:<port>` on the phone, SYN|ACK or RST answers, ACK carries data and
  windows, RST closes. The important port is **62078 = lockdownd**; the other
  services are the ports lockdownd starts after pairing.
* The kernel reports the mux process's TCP connections as pid 0
  (`tcp_usrreq.c` hunk), which is how lockdownd recognises an Apple in-kernel
  `AppleUSBDeviceMux` and allows pairing. `hakios.usbmux.cpp` publishes that
  IOService so lockdownd also gets the "host connected" notification
  (`0xe3ff8201`).

Host commands (Linux; after `usbmux` is installed and running on the phone):

```sh
sudo usbmuxd -f -v &                # or the distro service
idevice_id -l                       # the phone's UDID
ideviceinfo                         # queries lockdownd on 62078
# accept "Trust This Computer?" on the phone, then:
ifuse /mnt/ios                      # AFC file access (read/write)
fusermount -u /mnt/ios
```

On macOS the same role is played by the Apple Mobile Device service and
`idevice*`/`ifuse` from libimobiledevice. If `idevice_id -l` stays empty,
check the kernel log (`usb=3` lines: `the USB mux is process N`,
`AppleUSBDeviceMux ... published`) and that host `usbmuxd` is running.

## 3. Building and installing the userland

These are normal iOS arm64 programs, not kernel code. They need the iPhoneOS
SDK; this Linux tree has none, and `hakios-port-usb/userland/build.sh` says so
and stops. Use one of:

* **Theos SDK (recommended, works on Linux/macOS):** `iPhoneOS16.5.sdk`
  (has `libMobileGestalt.tbd`), cctools/`ld64`, `ldid`.
* **macOS + Xcode:** `IOS_SDK=$(xcrun --sdk iphoneos --show-sdk-path)`; if
  `-lMobileGestalt` is missing, use the Theos SDK or add a `libMobileGestalt.tbd`
  exporting `_MGCopyAnswer` (the failure message in `build.sh` prints it).

```sh
cd hakios-port-usb/userland
IOS_SDK=~/theos/sdks/iPhoneOS16.5.sdk ./build.sh
./install-root.sh /path/to/mounted/ios/root
```

`install-root.sh` defaults to `/usr/local/bin` and `/System/Library/LaunchDaemons`
(our root has no `/redwood` ramdisk); it rewrites the reference plists'
`/redwood/bin` paths. Both jobs can be installed together: the job that does
not own the port for this boot exits before opening it, and on `usb=2` even
`usbsh` waits for the host's magic line (see the ownership table above).

Entitlements: none are required by the sources and miniamfi here does not
enforce them. If a stricter AMFI path is ever used, `usbmux`'s
`MGCopyAnswer(UniqueDeviceID)` may need
`com.apple.private.MobileGestalt.AllowedProtectedKeys = [UniqueDeviceID]`, and
`usbsh cs` needs `com.apple.private.cs.debugger` to inspect other processes.

## 4. Boot cmdlines

```
# shell + files (usb=2)
debug=0xc serial=3 cpus=8 keepsyms=1 -noprogress rd=ufsroot0 \
unentitled_ios_sim_launch=1 ignition_level=1 wdt_test=no_user_checkin \
ufsrw=1 rootrw=1 launchd_unsecure_cache=1 wdt=-1 \
sweettouch=1 sweettouchdelay=0 sweetkeys=1 sweetusb=0 usbhakios=1 usb=2

# iPhone mux (usb=3)
... same ... usbhakios=1 usb=3
```

Read a session back without a photo:

```
sweetlogdump=262144 sweetloggrep=usb: sweetlogdumpwait=120 ufslogsecs=1
```
