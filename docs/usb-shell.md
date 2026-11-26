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

### One owner, chosen before either program opens the port

The two jobs can be installed together, but they must never race for
`/dev/hakios-usb` (only one opener is allowed, and the loser would exit and
leave the port silent for the whole boot). Each program reads `usb=` from
`kern.bootargs` **before** opening anything:

| boot arg | owner of `/dev/hakios-usb` | the other job |
| --- | --- | --- |
| `usb=2` | `usbsh` (kernel log first, then shell) | `usbmux` prints `usb=2, not usb=3` and exits 0 without opening |
| `usb=3` | `usbmux` (iPhone/usbmux device side) | `usbsh` prints `usb=3, not usb=2` and exits 0 without opening |
| anything else | nobody | both exit 0 |

`usbsh` waits for the kernel's CDC-ACM bring-up: it retries `open()` once a
second while the answer is `ENXIO`/`EBUSY`/`ENOENT` and logs every 30 s. The
kernel prints these boot-log transitions, so a silent host link has a trace:

```
usb: owner thread started (level 2): /dev/hakios-usb is there
usb: THE CONTROLLER IS THE KERNEL'S: a serial port ...
usb: the CDC-ACM port is up: /dev/hakios-usb may be opened now ...
usb: a program (pid N) has the port (/dev/hakios-usb), level 2: ...
```

If the kernel cannot start the controller the thread says so; if another
program already holds the port, the open prints `another program already has
the port`. `usbsh` also prints `USBSH: ...` state lines to `/dev/console`
(and so to the persistent ring); its shell I/O stays on the USB port.

## 1. `usb=2`: the serial shell

The port carries the kernel log until the computer sends its first byte. After
that `usbsh` takes over:

```
--- usbsh: the log is paused; 'help' for commands, 'log' to resume it ---
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
* `log` gives the port back to the kernel log; the next typed byte returns to
  the shell.
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
tools/sweet-usbsh.sh                 # interactive
tools/sweet-usbsh.sh 'uname; ls /usr/local/bin'
tools/sweet-usbsh.sh -g /var/tmp/usbmux.log usbmux.log
tools/sweet-usbsh.sh -g /etc/hosts -
```

`tools/sweet-usbsh.sh` uses `stty raw`, sends a bare `\r` to take the port,
waits for the `ios:<cwd># ` prompt, and drops the echoed command + prompt from
one-shot output. Options: `-d DEV`, `-b BAUD`, `-t SEC`, `-l` (keep the
handshake log), `-g REMOTE [LOCAL]`.

Exact host-side sequence (the order matters; DTR/RTS are not required by this
gadget, but asserting them is harmless and matches a normal terminal):

```sh
# 1. boot: ... usbhakios=1 usb=2   and wait for this line in the boot log:
#    usb: the CDC-ACM port is up: /dev/hakios-usb may be opened now
# 2. host sees 1209:316d "HakiOS K40" -> /dev/ttyACM0
stty -F /dev/ttyACM0 115200 raw -echo -echoe -echok -crtscts clocal
# 3. open, raise DTR/RTS (optional), then send ONE bare CR (not CRLF) to
#    take the port; wait for:  --- usbsh: the log is paused ... ---  then  ios:/#
# 4. send the command and a CR:  uname -a\r   wait for the next ios:/# prompt
# 5. "log\r" gives the port back to the kernel log; the next byte returns
tools/sweet-usbsh.sh 'uname -a'          # does 2-4 and prints only the answer
```

Do not send `\r\n` for the takeover: the shell treats the CR as the line end
and the LF as an empty second line, which makes the prompt accounting off by
one (the old script comment in this file is why it sends a bare CR).

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
not own the port for this boot exits before opening it (see the ownership
table above), so installing both is safe and is what the image does.

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
