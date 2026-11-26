# Port notes: haptics (AW8697) + flashlight (PM8150L) on alioth

Branch: `hakios-small`, based on `hakios-battery` (patches 0001..0118 + 0500).
Status: **compile-only, opt-in, no hardware run yet.** The default boot is
unchanged: without `haptichakios=1` and `torchstep=1|2` neither driver maps
MMIO, touches a GPIO, writes a PMIC register, or starts a thread.

## 1. Inventory

Reference: `xiongnemo/hakios-alioth`.

| reference file | what it is | what we did |
| --- | --- | --- |
| `devices/redmi-k40/overlays/xnu/files/bsd/dev/hakios.haptic.c` | AW8697/AW86927 haptics, five diagnostic levels, waveform load, iOS actuator service | took the AW8697 identity and the safe register set; **did not** take the waveform/RAM/service path. Bus access is rebuilt on our GENI/QUP pattern. |
| `devices/redmi-k40/overlays/xnu/files/bsd/dev/hakios.torch.c` | PM8150L flash LED, SID 5 / 0xd300, channel 0 | ported the module sequence (configure, ITARGET, MODULE_EN, EN_LED_CTRL, dark) and the fault/alarm guards on our SPMI transport. |
| `devices/redmi-k40/FLASHLIGHT.md`, `boot.args` | alioth/UMI PM8150L facts, `torch=3`, `umi_haptic=5` | used for the register/current limits and the "channel 0 only" decision. |

Board values checked against alioth's own kernel DTS, not assumed from the
reference header:

* haptics: `&qupv3_se11_i2c` / `aw8697_haptic@5A` in
  `xiaomi-sm8250-common.dtsi`; QUPV3 wrapper 1 SE5 at **0xa84000**,
  SDA **gpio60**, SCL **gpio61** (`function = "qup11"`), reset **gpio130**,
  interrupt **gpio129**, address **0x5a**. Chip id register `0x00` = **0x97**.
* flashlight: `qcom,leds@d300` in `pm8150l.dtsi`, SPMI **SID 5**,
  peripheral **0xd300**, `qcom,ires-ua = <12500>`, stock max 1500 mA.
  Our port caps channel 0 at 500 mA and defaults to 125 mA.
* alioth TLMM south tile: `0x0f000000 + 0x00500000`, per-pin blocks 0x1000.
  GCC QUPV3 wrap1: vote 0x52008 bits 18/19/20/21/27, RCG 0x18600.

## 2. What patch `0501-hakios-haptic-torch.patch` changes

* **new** `bsd/dev/alioth_haptic.c` — AW8697 probe over GENI I2C.
  * GCC vote + RCG for wrap1 s5 (same sequence as `alioth_touch.c` for wrap0 s4).
  * GENI SE11 FIFO I2C at 400 kHz: `I2C_WRITE`/`I2C_READ` opcodes, repeated
    START for a register read, 5 ms command timeout, abort on error.
  * checks `SE_FW` protocol == 3 (I2C) first; if ABL did not load I2C firmware,
    it prints and touches nothing.
  * releases reset (low 5 ms, high, 8 ms), reads id `0x00` (expect 0x97),
    does **one** write: `SYSINTM (0x03) = 0xff`, read back; prints `GLBRD5`
    (0x46, state 0 = standby) and registers 0x00..0x07.
  * holds the chip back in reset on every exit. No waveform is ever started.
  * boot arg `haptichakios=1` (any non-zero); `haptichakiosdelay=N` seconds
    (default 5).
* **new** `bsd/dev/alioth_torch.c` — PM8150L flash module.
  * configure: `HDRM_AUTO (0x50)=0`, `ISC_DELAY (0x52)[1:0]=3`,
    `STROBE0 (0x49)[2]=0`, `SAFETY0 (0x40)=0x13`.
  * on: fault/PMIC-alarm check, `IRESOLUTION (0x47)[1:0]=0` (12.5 mA steps),
    `ITARGET0 (0x43)` from mA, `MODULE_EN (0x46)=0x80`,
    `EN_LED_CTRL (0x4c)[0]=1`.
  * off: `EN_LED_CTRL=0`, `MODULE_EN=0`, `ITARGET0=0`, `SAFETY0=0x13`,
    attempted even after a failed ON.
  * boot args: `torchstep=1` (one bounded ON/OFF), `torchstep=2` (exposes
    `/dev/hakios-torch`; a 32-bit write is mA, 0 = off), `torchma` (default
    125, clamp 25..500), `torchsecs` (default 2, 1..30), `torchmaxs` (default
    30, 1..30), `torchdelay` (default 5 s).
  * every write is read back; only the module's writable registers are
    allowed; type/subtype must be 0x18/0x04 before any write.
* `bsd/dev/sweet_spmi.c/.h` — read allowlist gains SID 5 / 0xd3 (flash) and
  SID 4 / 0x24 (PM8150L temperature alarm). New `sweet_spmi_write()`, one
  byte, **only** SID 5 / 0xd3, only through a channel owned by EE0, mapped
  once, retried twice on a dropped transfer, poisoned on timeout. Nothing
  else can be written.
* `bsd/conf/files` — adds the two new files (`standard`).
* `bsd/dev/sweet_ufs.c` — after `sweet_gpu_init()`, on `alioth_board()` only:
  calls `alioth_haptic_init()` / `alioth_torch_init()` when their boot arg is
  present. The default path is byte-for-byte unchanged.

Neither patch modifies `bsd/dev/sweet_gpu.c` (the name appears only as a
context line in `bsd/conf/files`).

## 3. Build verification

```
XNU_CC_CLANG=/usr/bin/clang python3 tools/xnu-cc.py /tmp/ci-small.log \
    /tmp/opencode/bt-small bsd/dev/alioth_haptic.c bsd/dev/alioth_torch.c \
    bsd/dev/sweet_spmi.c bsd/dev/sweet_ufs.c --per-file
0 of 4 files failed
```

Also compiled to objects and checked `llvm-nm -u`: the only names not in the
CI `config/allsymbols` are the other new object's symbols (resolved at link).
Log: `gh run view 45735232511 -R nurako/ios-sweet --log` (hakios-usb
buildtree; patches 0001..0118 plus the USB work). `git apply --check` of 0500
then 0501 passes forward on a clean tree at `a03dc7e` (blacktop + 0001..0118).

## 4. Boot cmdlines

Default (both drivers inert):

```
debug=0xc serial=3 cpus=8 keepsyms=1 rd=ufsroot0 unentitled_ios_sim_launch=1 \
ignition_level=1 wdt_test=no_user_checkin ufsrw=1 rootrw=1 \
launchd_unsecure_cache=1 wdt=-1 sweettouch=1 sweettouchdelay=0 sweetkeys=1 \
sweetusb=0
```

Haptics probe (safe, no motor movement):

```
... haptichakios=1 haptichakiosdelay=5
```

Torch one-shot (on for 2 s, then off):

```
... torchstep=1 torchma=125 torchsecs=2 torchdelay=5
```

Torch debug node (no light until userland writes mA):

```
... torchstep=2 torchmaxs=30
```

## 5. Expected proof lines (NOT yet observed on hardware)

Haptics:

```
HAKIOS HAPTIC: gpio60 SDA gpio61 SCL gpio130 reset gpio129 int, chip 0x5a on SE11 0xa84000
HAKIOS HAPTIC: SE11 fw=0x3103 proto=3 status=0x... tx=0x... rx=0x...
HAKIOS HAPTIC: i2c 400kHz m_clk=0x21 scl=0x702818 clk_sel=0x0
HAKIOS HAPTIC: reset gpio130 cfg=0x... io=0x... before
HAKIOS HAPTIC: reset gpio130 cfg=0x200 io=0x2 after (high=released)
HAKIOS HAPTIC: reg0 id=0x0097: AW8697 answers
HAKIOS HAPTIC: 0x03 <- 0xff, reads 0xff
HAKIOS HAPTIC: GLBRD5 0x??? state=0 (standby)
HAKIOS HAPTIC: AW8697 verified; no waveform was started
HAKIOS HAPTIC: chip held in reset (gpio130 low); done
```

If `SE11 is not an I2C engine` appears, ABL left the serial engine in another
protocol; nothing was touched and the boot continues.

Flashlight:

```
HAKIOS TORCH: module before: type=0x0018 subtype=0x0004 rev=0x00 rt=0x... ... alarm=0x08/0x00 stage=0x0
HAKIOS TORCH: one-shot ON at 125 mA for 2 s
HAKIOS TORCH: 50 ms after ON: type=0x0018 ... rt=0x0090 ... en=0x0080 ch=0x0001 itarget=9 ...
HAKIOS TORCH: off after 2 s; NN writes, all read back
HAKIOS TORCH: after OFF: ... en=0x0000 ch=0x0000 itarget=0 ...
```

`rt=0x0090` is the reference's "ramped up" state; `stage=0x0` is the PMIC
thermal alarm's "all is well". A fault line ends with `OFF: fault ...` and the
module is darkened.

## 6. Missing / next

1. **No iOS service.** Haptics has no `/dev/hakios-haptic` actuator bridge and
   no waveform/RAM loading; the flashlight has no FigFlashlight/mediaserverd
   glue. Both are kernel-side probes only. The debug node exists for
   `torchstep=2`, but nothing in our current userland writes it.
2. **Haptic playback** needs `aw8697_haptic.bin` from the phone's
   `/vendor/firmware`, the RAM load sequence and the two host waveforms
   (Android's effect 1 / loop 11). Deliberately absent until the probe line is
   confirmed; a wrong RAM write can drive the actuator hard.
3. **Haptic IRQ** (gpio129) is not wired; the probe polls. Not needed for the
   verification line.
4. **Battery-temperature torch guard** is not available: the reference stops
   at 45 C from the battery manager. We guard with the flash module's own
   faults (open/short/OT/VPH) and the PM8150L temperature alarm (SID 4). The
   fixed 25 C gauge cannot provide a real pack temperature.
5. **GENI I2C is new here.** Only `alioth_touch.c`'s SPI use of the same
   engine is proven. If SE11 is not in I2C mode, or the clock/RCG differs,
   the probe fails at the proto check or times out; it never retries forever.
6. **Hardware run** — none. Watch for: the haptic id, the `0x03` round trip,
   `GLBRD5=0`, the torch `rt=0x0090`, and that `stage` stays 0.

## 7. Risks and safe defaults

* **Leaving the torch on.** `torchstep=1` is bounded by `torchsecs` (max 30)
  and always calls `dark()`; `torchstep=2` cuts at `torchmaxs` and stays dark
  until a 0 write and a new ask. Every error path attempts all OFF writes.
  Default (no `torchstep`) never lights it.
* **A haptic that buzzes forever.** No waveform command is ever sent: the only
  write is `SYSINTM=0xff`, and the chip is put back into reset at the end.
  Both the default and the probe leave the actuator unpowered.
* **A wrong PMIC write.** `sweet_spmi_write()` accepts only SID 5 / 0xd300,
  one byte, through an EE0-owned channel; the torch file additionally
  allowlists registers and reads every write back. Any surprise stops all
  further writes for the boot.
* **A hanging bus.** GENI transfers have bounded polls (5 ms command timeout,
  abort + FIFO drain on error); SPMI writes have a 1 s loop and poison the
  lane on timeout. Both run on their own kernel thread after a delay, so a
  failure cannot stall `sweet_ufs_init`.
* **Keep both opt-in.** The default boot must stay the reference: no
  `haptichakios`, no `torchstep`.
