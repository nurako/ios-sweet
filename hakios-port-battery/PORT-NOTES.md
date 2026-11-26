# Port notes: battery reporting (alioth, PM8150B fg-gen4)

Branch: `hakios-battery` (based on main + patches 0001..0118).
Status: **phase 1, compile-only**. The default boot still publishes the static
100% / 4200 mV fallback. Real gauge reads are opt-in with `batteryhakios=1`.

## 1. Inventory

Our tree already has patch `0062-sweet-touch-power-battery.patch`, which adds:

* `bsd/dev/sweet_spmi.c` / `.h` — read-only SPMI observer transport
  (PMIC arbiter 0x0c440000 + observer 0x0e600000, channel lookup by
  `(slave << 8) | peripheral`, 512 channels, per-channel poison on timeout).
* `iokit/Kernel/arm/SweetBattery.cpp` — an `IOPMPowerSource` (what powerd
  reads), default static 100% / 4200 mV, and a `sweetbattery=1` path for
  sweet's PM6150 QG at SPMI SID 0 (voltage-derived SOC).

On alioth the PM6150 layout does not exist. The battery PMIC is **PM8150B on
SPMI SID 2** (same as the working `Gsjsjzhznsz/ios-raphael` port):

| value | peripheral / register | conversion |
| --- | --- | --- |
| monotonic SOC | `fg-batt-soc@0x4000 +0x09` (shadow `+0x0A`) | 255→100, 0→0, else `round((raw-1)*98/253)+1` |
| battery present | `fg-batt-info@0x4100 +0x07` | bits 0..2 clear = present |
| voltage | `fg-batt-info +0xA0` (shadow `+0xA6`) | `uV = raw*122070/1000` |
| current | `fg-batt-info +0xA2` (shadow `+0xA8`) | `uA = sign16(raw)*488281/1000`, discharge positive |
| charger state | SMB5 `0x1006` (+ error `0x1007`) | 1..4 charging, 5 terminated/full |
| external power | SMB5 `0x1310` bit 4 | USBIN_PLUGIN |
| temperature | PM8150B RRADC (not ported) | fixed 25.0 C, flagged estimated |

The reference (`xiongnemo/hakios-alioth`) does not read fg-gen4 directly: its
Android/UEFI loader firmware owns the charger and its DSP battery manager
supplies SOC/voltage/current/temperature/cycles to `HakiosBattery`
(`IOPMPowerSource`). We have no loader/DSP battery service yet, so phase 1
reads the same fg-gen4 registers directly, exactly like ios-raphael's
verified `0096-raphael-battery-fggen4.patch`.

## 2. What patch `0500-hakios-battery.patch` changes

* `bsd/dev/sweet_spmi.c`: `sweet_spmi_read()` now permits SID 0 battery blocks
  (unchanged PM6150 set) **and** SID 2 blocks `0x10-0x13`, `0x40`, `0x41`
  only. No writes, no interrupts, no other PMIC peripheral reachable.
* `iokit/Kernel/arm/SweetBattery.cpp`:
  * new boot arg `batteryhakios=1` selects the PM8150B fg-gen4 path;
    `sweetbattery=1` keeps the old PM6150 path; neither = static fallback.
  * shadow-copy reads of SOC/VBATT/IBATT reject torn samples (no HOLD write).
  * battery capacity for alioth is 4520 mAh (sweet stays 5020).
  * a one-shot probe line prints every raw register, the shadow copies and the
    derived percent / mV / mA / temperature.
  * a change in percent now logs a line even when the mode is unchanged.
* Does not touch `bsd/dev/sweet_gpu.c`.

## 3. Build verification

```
XNU_CC_CLANG=/usr/bin/clang python3 tools/xnu-cc.py /tmp/ci-bat.log \
    <buildtree> bsd/dev/sweet_spmi.c iokit/Kernel/arm/SweetBattery.cpp
0 of 2 files failed
```

`git apply --check` and forward application were verified against the
CI buildtree of `nurako/ios-sweet` run 45735232511 (patches 0001..0118),
and the applied files compare byte-identical to the compiled sources.

## 4. Boot cmdline

```
debug=0xc serial=3 cpus=8 keepsyms=1 rd=ufsroot0 unentitled_ios_sim_launch=1 \
ignition_level=1 wdt_test=no_user_checkin ufsrw=1 rootrw=1 \
launchd_unsecure_cache=1 wdt=-1 sweettouch=1 sweettouchdelay=0 sweetkeys=1 \
sweetusb=0 batteryhakios=1
```

## 5. Expected proof lines (NOT yet observed on hardware)

```
SWEET BATTERY: SPMI arb=... APIDs=... observer reads only
SWEET BATTERY: alioth probe type=0/0xd sys=0/0x0 msoc=0/0x..,0x..(NN%) \
    v=0/0x....,0x....(3xxxmV) i=0/0x..(..mA) usb=0/0x.. chg=0/0x.. c2=0/0x.. \
    temp=25.0C(est, not measured)
SWEET BATTERY: PM8150B fg-gen4 / hardware SOC, NN% 3xxxmV ...mA temp=25.0C(est) external=0 charging=0
```

If the probe fails, the boot keeps `SWEET BATTERY: static fallback, 100%
4200mV`; nothing else in the boot depends on the gauge.

## 6. Missing / next

1. **Temperature** — the pack's thermistor is on PM8150B's RRADC
   (`qcom,pm8150b-adc` bat_therm). Reading it needs ADC channel selection and
   a conversion write, i.e. a read-write driver. Until then 25.0 C is
   published and explicitly marked `SweetBatteryTemperatureEstimated`.
2. **Cycle count** — the reference gets it from the DSP battery manager; the
   gauge-only path leaves it 0.
3. **Charge limits / JEITA** — SMB5 is autonomous; we only observe it. Every
   write path (input current limit, JEITA, charge enable) is deliberately
   absent.
4. **Full-charge / calibrated capacity** — no learned `full_uah`, so
   capacity is nominal 4520 mAh.
5. **Device verification** — none yet. Confirm SOC moves, voltage is
   3.5–4.4 V, current sign flips on charge, and `charging=1` appears only
   with a charger attached.

## 7. Risks

* **Reading while the charger runs.** The SPMI arbiter is shared with the
  bootloader's charger firmware and the buttons driver. Reads are serialized
  by `sweet_spmi`'s lock, the observer block is read-only, and a timed-out
  channel is poisoned instead of retried forever. A dropped transfer is
  retried once per datum via the shadow loop, then that poll falls back.
* **Torn samples.** Mitigated by the gauge's own shadow copies; a persistent
  mismatch means the read path is tearing and should be reported, not trusted.
* **Raphael-proven, alioth-untested.** Register offsets and conversions come
  from the vendor PM8150B tree and the working raphael port, but alioth's
  battery profile/SOC algorithm may differ; verify the boot probe line first.
* **Keep the static fallback the default** until the probe line and a real
  SOC/voltage/current run are observed on the phone. `batteryhakios=1` is
  opt-in precisely so a bad gauge read cannot affect a normal boot.
