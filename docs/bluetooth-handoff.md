# Bluetooth handoff: the WCN3990 factory address (solved: btmgmt stdin/epoll)

Scope: one feature, one problem. Everything here is about getting Bluetooth up on
the Xiaomi Mi 8 Pro (`equuleus`, SDM845) under mainline Linux, from a cold boot,
with no manual step. Display, Wi-Fi, audio and charging are out of scope except
where they share the combo chip or the boot ordering.

Status: **resolved.** Bluetooth comes up by itself on a cold boot. The blocker was
not the controller at all: `btmgmt` puts stdin into an epoll set, `epoll` rejects
`/dev/null` with `EPERM`, and the unhandled failure made every unit-context attempt
hang silently. Feed the command a pipe and it completes in milliseconds. See
section 11 for the trace, the fix and three accepted cold boots.

> **Resolved - read section 11 first.** The multi-minute "hardware readiness" was
> an artefact of `btmgmt` blocking on a non-pollable stdin inside systemd units.
> The address is now written from `persist` at run time with one bounded
> `public-addr` call whose stdin is a pipe: three cold boots reached
> `UP RUNNING` with the factory address about 106 s after power-on. Section 10's
> source review is still worth reading: it is what ruled out the DT-free options
> and produced the readiness-signal advice that section 11 then corrected.

---

## 1. The stack, and why an address is needed at all

The Wi-Fi/Bluetooth combo is a Qualcomm **WCN3990** behind UART (BLSP6, `hci0`
over `hci_qca`). Bluetooth firmware (`qca/crbtfw21.tlv`, `qca/crnv21.bin`) is
downloaded by the host at boot and that part works:

```
Bluetooth: hci0: QCA Product ID   :0x0000000a
Bluetooth: hci0: QCA SOC Version  :0x40010214
Bluetooth: hci0: QCA Downloading qca/crbtfw21.tlv
Bluetooth: hci0: QCA Downloading qca/crnv21.bin
Bluetooth: hci0: QCA setup on UART is completed
```

The controller comes up as **`HCI_UNCONFIGURED`** because `hci_qca` marks its
address invalid. In that state every normal open is refused:

```
hciconfig hci0 up    -> Operation not supported (95)
bluetoothctl show    -> No default controller available
```

Only the **management interface** may configure it, which in practice means
`btmgmt`:

```
btmgmt -i hci0 public-addr a4:50:46:b3:ed:3c
  -> hci0 Set Public Address complete
btmgmt -i hci0 power on
  -> Set Powered for hci0 failed with status 0x11 (Invalid Index)   [first try]
```

The address comes from the read-only `persist` partition (`/dev/sda14`,
`wlan_bt/bt.mac`, six raw bytes). Reading it works:

```
$ od -An -tx1 /persist/wlan_bt/bt.mac
 a4 50 46 b3 ed 3c
```

Note the MAC differs from Wi-Fi's (`a4:50:46:f3:ed:3c`) by one nibble; both are
genuine factory values.

## 2. What actually works

Once the address is applied and the controller powered, everything downstream is
fine. Verified on hardware:

```
hci0:   Type: Primary  Bus: UART
        BD Address: A4:50:46:B3:ED:3C  ACL MTU: 1024:7  SCO MTU: 60:8
        UP RUNNING

btmgmt info:
  hci0 Primary controller
  addr A4:50:46:B3:ED:3C version 9 manufacturer 29
  current settings: powered br/edr

bluetoothctl show:
  Controller A4:50:46:B3:ED:3C (public)
  Manufacturer: 0x001d (29)  Version: 0x09 (9)  Name: equuleus

bluetoothctl --timeout 10 scan on
  -> 28 devices discovered, including LAPTOP-IGG23AJV
```

So the driver, the firmware path, the UART and BlueZ are all correct. **The only
open problem is timing the address write.**

## 3. The problem, stated precisely

`btmgmt public-addr` fails for a long and variable time after boot, and the
failure mode is not a clean error — `btmgmt` **blocks** and has to be killed by
`timeout`. Measured readiness on real boots (uptime at which the same command
first returned `complete`):

| Uptime | Result |
|---|---|
| 464 s | still failing |
| 586 s | success |
| 616 s | success |
| 803 s | success (manual, from an SSH shell) |
| 983 s | success (manual, first attempt after stopping the retrying unit) |

Anything below roughly 8 minutes has never succeeded on this device, and 900 s of
continuous retrying has never succeeded either — see the next section, which is
the important part.

## 4. The two effects that make this hard

**(a) `bluetoothd` must not hold the controller.** With `bluetooth.service`
active, every attempt blocks. Stopping it makes the *next* call succeed at once:

```
$ systemctl stop bluetooth
$ btmgmt -i hci0 public-addr a4:50:46:b3:ed:3c
hci0 Set Public Address complete, options:
```

**(b) Retrying in a loop prevents the controller from ever becoming ready.** This
is the surprising one, and it is why several "obvious" fixes did not work:

| Implementation | Result |
|---|---|
| Poll every 3 s, up to 900 s (with a `power on` poke each round) | **failed for 844 s**, still failing when the window closed |
| Poll every 25 s, stopping `bluetoothd` before each attempt, up to 900 s | **failed for 922 s** |
| Poll every 30 s, 15 min, then `Restart=on-failure` + 60 s | failed for 1000 s, timed out, restarted, failed again |
| **One attempt after a quiet pause** | **succeeded immediately, repeatedly** |

The pattern is consistent: a loop of `btmgmt` calls keeps the device busy, and
the first call after the looping process is gone returns `complete` on the first
try. The kernel side is consistent with this too — `dmesg` shows the QCA setup
being (re)started late in boot:

```
[  413.724617] Bluetooth: hci0: setting up wcn399x
```

## 5. Hypotheses already tested and rejected

* **"It is a timing race on the persist partition."** Real, but a different bug:
  `wifi-mac.service` was skipped once by `ConditionPathExists=/dev/disk/by-partlabel/persist`
  because udev had not created the symlink yet. Fixed by
  `systemd/persist-part.sh`, which waits and falls back to `lsblk`. The Bluetooth
  helper uses the same resolver, and reading the address works every time.
* **"The address itself is wrong."** No: the same six bytes work by hand, and
  `hciconfig` confirms `A4:50:46:B3:ED:3C`.
* **"It is the UART pinmux."** That was a real earlier bug (needed
  `pinctrl-0 = <&qup_uart6_4pin>` for RTS/CTS), but it is fixed: firmware now
  downloads and version info is read correctly.
* **"It is the missing address sysfs attribute."** `sysfs` has **no**
  `address` file for `hci0` in this kernel (`/sys/class/bluetooth/hci0/` contains
  only `device power reset rfkill0 subsystem`). That only broke the idempotency
  check; `hciconfig` parsing replaces it.
* **"BlueZ is too old / needs a newer btmgmt."** `bluetoothd 5.82`, `btmgmt` from
  the same package, and the management interface reports version 1.23. Not
  obviously the constraint.
* **"`reboot bootloader` from Linux."** Unrelated to Bluetooth, but do not rely on
  it: it reboots into Linux even with the IMEM restart-reason driver loaded.

## 6. What is in the tree now

* `systemd/bluetooth-addr.sh` — resolves `persist`, reads the address, checks
  the current address (via `hciconfig`, since sysfs lacks it), stops
  `bluetoothd` if it holds the controller, makes **exactly one** bounded
  `btmgmt public-addr` attempt, and starts `bluetooth.service` on success.
* `systemd/bluetooth-addr.service` — `Type=oneshot`, **one attempt per
  invocation**, `TimeoutStartSec=120`. Nothing is ordered before the boot, so a
  slow controller can never delay it.
* `systemd/bluetooth-addr.timer` — `OnBootSec=10min`, `OnUnitActiveSec=10min`.
  This is the mechanism that gives the controller quiet time between attempts.

Latest observed behaviour of that design:

```
up=600s   timer tick -> [bt] controller not ready, will retry on the next timer tick
up=840s   (manual check from an SSH shell, for measurement) -> hci0 Set Public Address complete
up=1285s  timer tick -> finished, hci0 BD Address A4:50:46:B3:ED:3C, UP RUNNING, bt active
```

So the schedule does converge, but the ticks themselves almost never land the
address — they mostly log "controller not ready". Two clean boots with ticks every
three minutes were still unconfigured at 637 s and 780 s respectively.

### The remaining difference between a manual run and the unit

**This is now measured, and it is the unit context itself.** The same script, run
in the same second on the same boot, behaves differently depending only on how it
is launched:

| Launch context | `btmgmt -i hci0 public-addr` | Result |
|---|---|---|
| `systemd-run --unit=... --wait` | blocked, killed at the 20 s timeout | `hci0` stays `DOWN RAW` |
| plain process in the serial shell | returned `complete` in ~2 s | `hci0 UP RUNNING` |

```
=== A) unit context (systemd-run --unit) ===
13:36:26 target=a4:50:46:b3:ed:3c
13:36:35 public-addr (no prior inspection):
13:36:57 power on:
13:37:10 state:  DOWN RAW
=== C) plain shell in this session ===
13:37:10 target=a4:50:46:b3:ed:3c
13:37:19 public-addr (no prior inspection):
13:37:21 power on:
13:37:24 state:  UP RUNNING
```

The earlier timing and ordering observations are real but secondary. The address
call only completes from a process that is **not inside a systemd unit**; inside
one, `btmgmt` blocks on the management socket until `timeout` kills it. That is
why every timer tick logs "controller not ready" however late it fires, and why a
loop of ticks never converges: the process context, not the clock, decides.

First experiment for the next agent — the whole problem reduces to this:

```
systemd-run --unit=probe --wait /run/bt-clean.sh   # blocks
/run/bt-clean.sh                                    # succeeds, same minute
```

Then bisect unit properties until a unit behaves like the shell:

```
systemd-run --scope --wait /run/bt-clean.sh        # stays in the caller's session
systemd-run --unit=probe --wait --property=Type=simple \
    --property=Delegate=yes --property=PrivateDevices=no /run/bt-clean.sh
```

If `--scope` succeeds, the difference is cgroup/session placement, and the fix is
either to run the retry outside a unit or to stop doing this in userspace.

The robust way out, given this result, is **kernel-side configuration**: let
`hci_qca` take the address at probe time from a device-tree property or from the
`persist` partition, so no userspace process ever has to issue the management
command. That is the direction I would pursue next.

## 7. What the next agent should try

Highest value first:

1. **Confirm or refute that the timer tick eventually lands.** Reboot and sample
   `hciconfig hci0` every 30 s for 25 minutes. If a tick between 900 s and 1500 s
   succeeds, the design is correct and only the schedule needs tuning (for
   example `OnBootSec=12min` plus `OnUnitActiveSec=3min` until `UP RUNNING`).
2. **Find what makes the controller ready.** The interesting question is not "how
   long" but "what changes at minute ~10". Candidates: the `hci_qca` setup retry
   (`Retry BT power ON`), a regulator that comes up late (`vddch0`, `vddio`), the
   BT-enable GPIO, or the WCN3990's own boot timing. `dmesg | grep -i qca` around
   the transition, and `regmap`/regulator state, would settle it.
3. **Test whether a single mgmt call is enough to unblock the rest.** If one
   `btmgmt info` (or a `power off`) early in boot is what later allows
   `public-addr`, an explicit handshake at ~30 s followed by one attempt at ~10
   min may be far more reliable than either alone.
4. **Consider configuring the address in the kernel instead.** If `hci_qca` could
   take the address from a device-tree property or from `persist` at probe time,
   userspace timing disappears entirely. This is the most robust direction, but
   it needs a driver change plus a DT binding.
5. **Check whether `bluetoothd` can be told to wait** rather than racing it: an
   ordering that keeps `bluetooth.service` from starting until the address is
   applied *without* the timer, e.g. a `ExecStartPre` wait loop inside
   `bluetooth.service` itself, which is allowed to block that unit only.

## 8. How to reproduce and inspect quickly

```bash
# state
hciconfig hci0
btmgmt info
systemctl status bluetooth-addr --no-pager
systemctl list-timers bluetooth-addr.timer --no-pager
journalctl -u bluetooth-addr --no-pager | tail

# try by hand (stop the daemon first, it holds the controller)
systemctl stop bluetooth
ADDR=$(od -An -tx1 /persist/wlan_bt/bt.mac | tr -s ' \n' ' ' | sed 's/^ //;s/ $//;s/ /:/g')
timeout 8 btmgmt -i hci0 public-addr "$ADDR"
timeout 8 btmgmt -i hci0 power on
hciconfig hci0
systemctl start bluetooth
bluetoothctl show
```

Practical traps when debugging this device:

* `btmgmt` can block forever on an unconfigured controller — always wrap it in
  `timeout`, or the unit hangs in `activating`.
* There is no `address` file under `/sys/class/bluetooth/hci0/`.
* `systemctl reboot` over SSH sometimes does nothing on this build; reboot from
  the USB serial console (`/dev/ttyGS0`, 115200 8N1) instead.
* `adb` is not available; the console is a CDC-ACM gadget created by the
  initramfs, and Wi-Fi SSH needs a saved NetworkManager profile (a freshly
  flashed image has none).
* Entering fastboot still requires Volume Down + Power.
* Charging works from a PC USB-A port; a C-to-C PD wall charger delivers nothing
  because this kernel has no Type-C/PD negotiation (`/sys/class/typec` absent).

## 9. Relevant files

| Path | Role |
|---|---|
| `systemd/bluetooth-addr.sh` | address resolution, one bounded attempt, starts bluetoothd |
| `systemd/bluetooth-addr.service` | one attempt per invocation |
| `systemd/bluetooth-addr.timer` | repeats the attempt every 10 min |
| `systemd/persist-part.sh` | udev-independent `persist` lookup (shared with Wi-Fi MAC) |
| `docs/bluetooth-complete.md` | earlier write-up: UART pinmux root cause and the manual procedure |
| `docs/bluetooth-baud-analysis.md`, `docs/bluetooth-clock-not-effective.md` | two rejected theories kept for the record |

---

## 10. Source review (2026-11-24): use the existing DT address path

Reviewer: another agent, reviewing the kernel tree and the installed units only.
No device-side change was made.

### 10.1 The "wait 8-10 minutes for the WCN3990" model is not supported

The relevant kernel sequence is deterministic:

* `hci_register_dev()` sets `HCI_SETUP` and queues `hdev->power_on` itself
  (`net/bluetooth/hci_core.c:2585`, `:2641`, `:2672`). bluetoothd is not needed
  to trigger the first setup.
* The serdev setup callback reaches `hu->proto->setup`, hence `qca_setup()`
  (`drivers/bluetooth/hci_serdev.c:178`, `:213-214`).
* Therefore a late `setting up wcn399x` / `QCA setup on UART` message records an
  HCI open/reopen. It does **not** establish an eight-minute controller settling
  delay. Userspace service starts/stops and retries are sufficient to explain
  those late messages.

Also, plain `btmgmt info` reads the normal index list. An unconfigured controller
is not diagnosed by `Index list with 0 items`; inspect `btmgmt unconf-index` (or
`btmgmt ext-index`) before concluding that setup has not completed.

### 10.2 `local-bd-address` is already implemented end to end

Section 7 item 4's claim that this needs "a driver change plus a DT binding" is
incorrect for this tree:

1. QCA marks the controller for a firmware-node supplied address in
   `qca_check_bdaddr()` (`drivers/bluetooth/btqca.c:700`, quirk set at `:725`).
2. Bluetooth core reads `local-bd-address` in
   `hci_dev_get_bd_addr_from_property()` (`net/bluetooth/hci_sync.c:3603`,
   property read at `:3609`).
3. During setup it invokes the QCA `set_bdaddr` callback; success clears the
   invalid-address condition (`hci_sync.c:5053-5055`). QCA's write callback is
   `qca_set_bdaddr()` (`drivers/bluetooth/btqca.c:1021`).
4. The standard binding already exists
   (`Documentation/devicetree/bindings/net/bluetooth/bluetooth-controller.yaml:18`).

For the address documented above, the minimal DTS addition inside the existing
`bluetooth { ... }` node is:

```dts
	/* A4:50:46:B3:ED:3C, stored least-significant byte first. */
	local-bd-address = [3c ed b3 46 50 a4];
```

The byte order is specified by the binding at lines 23-25. Do **not** add
`qcom,local-bd-address-broken`: that requests another byte swap and would reverse
the address again.

This is the preferred experiment for this single-device image: one DTS property,
no timer, no nested `systemctl`, and no userspace power/address loop. Keep the
per-device value in a generated/local include if the public DTS must remain
generic; do not commit every device's factory address into a shared board DTS.

Expected result on a cold boot: QCA firmware setup completes, the kernel writes
the address during setup, and hci0 becomes a normal configured controller without
`bluetooth-addr.timer` ever running.

### 10.3 The current userspace automation is not a clean baseline

* The repository `bluetooth-addr.service` has only `After=local-fs.target`; it
  lacks `Before=bluetooth.service`, while `build-rootfs.sh` enables both units.
* The repository script then starts, stops and restarts `bluetooth.service` from
  inside its own oneshot. That makes daemon lifecycle and HCI open/close part of
  every measurement, so "retrying prevents readiness" is not an isolated hardware
  observation.
* The installed rootfs is not running the same design: its unit still has
  `Before=bluetooth.service`, `RemainAfterExit=yes`, `TimeoutStartSec=40`, and a
  `persist` condition, and its script is the older 2.9 kB version. The repository
  script is 5.2 kB. Device observations must name the exact unit/script version.

Do not tune the 2/3/10-minute timers until this is made reproducible.

### 10.4 If a generic userspace solution is required instead

Use a single owner and a real readiness signal:

1. Remove the timer and every `systemctl start/stop bluetooth.service` from the
   address helper. Let `bluetooth.service` alone pull in the helper with
   `Wants=bluetooth-addr.service` and `After=bluetooth-addr.service`.
2. Wait with a bounded, read-only poll of `btmgmt unconf-index` or
   `btmgmt ext-index`; sysfs `hci0` appearing is earlier than completed QCA setup.
3. Issue exactly one bounded `btmgmt public-addr`. Do not precede it with
   `power off` and do not loop `power on`: after a successful public-address
   change the kernel already queues `hdev->power_on` (`net/bluetooth/mgmt.c:8123`,
   `:8167`).
4. Return nonzero on a real failure so systemd reports it instead of silently
   declaring a skipped/failed configuration successful.

### 10.5 Minimal decision test

On the next cold boot, capture only:

```sh
btmgmt unconf-index
btmgmt ext-index
systemd-analyze critical-chain bluetooth.service bluetooth-addr.service
journalctl -b -u bluetooth.service -u bluetooth-addr.service --no-pager
dmesg | grep -iE 'Bluetooth: hci0|qca'
```

Then try the DTS property above as the single changed variable. Acceptance is
three cold boots with the factory address, `UP RUNNING`, and a successful scan,
with both `bluetooth-addr.service` and `bluetooth-addr.timer` disabled. If that
passes, delete the timer-based machinery rather than preserving it as a fallback.

---

## 11. Resolved: the unit hangs on stdin, not on the controller

The blocker was not hardware readiness, not ordering, and not the management
interface. It was **`btmgmt` putting stdin into its epoll set**.

`strace` on the same command, same second, same boot, shows the only difference:

```
UNIT  (stdin is /dev/null):
  bind(4, {AF_BLUETOOTH, hci_dev=htobs(65535), HCI_CHANNEL_CONTROL}, 6) = 0
  epoll_ctl(3, EPOLL_CTL_ADD, 0, ...) = -1 EPERM

SHELL (stdin is the serial tty):
  bind(4, {AF_BLUETOOTH, hci_dev=htobs(65535), HCI_CHANNEL_CONTROL}, 6) = 0
  epoll_ctl(3, EPOLL_CTL_ADD, 0, ...) = 0
```

`epoll` refuses regular files and `/dev/null` (EPERM). `btmgmt` does not handle
that failure, so its main loop waits forever and the process is eventually killed
by `timeout` with **no output at all** — which is exactly the "controller is not
ready" symptom. From a serial console stdin is a tty, so the call completes in
milliseconds.

This also explains the earlier confusions: every "it works after a few minutes"
observation was a run whose stdin happened to be pollable, and the loops that
"never converged" were runs whose stdin was `/dev/null`. Nothing about the
WCN3990 needed eight minutes.

Making stdin a pipe fixes it inside a unit:

```sh
{ sleep 30; } | timeout 20 btmgmt -i hci0 public-addr "$addr"
```

`/dev/zero` was tested as well and still fails; a pipe is required.

### Final design

* `systemd/bluetooth-addr.sh` reads the address from the read-only `persist`
  partition at run time — no per-device value in any image — waits for `hci0`,
  then makes **one** bounded `public-addr` call with stdin fed from a pipe. No
  `power off`, no `power on` loop, no nested `systemctl`, no timer.
* `systemd/bluetooth-addr.service` is a plain oneshot ordered `Before=bluetooth.service`.
* `systemd/bluetooth.service.d-10-equuleus.conf` makes `bluetooth.service` pull the
  helper in with `Wants=` plus `After=`, which is the single-owner arrangement
  suggested in section 10.4.
* `systemd/bluetooth-addr.timer` is **deleted**.

### Acceptance: three cold boots, timer absent

```
boot 1  up=106s  addr=A4:50:46:B3:ED:3C  state=UP RUNNING  acc=success  scan=33
boot 2  up=106s  addr=A4:50:46:B3:ED:3C  state=UP RUNNING  acc=success  scan=45
boot 3  up=106s  addr=A4:50:46:B3:ED:3C  state=UP RUNNING  acc=success  scan=58
```

`systemd-analyze critical-chain` shows the whole cost is 30 s:

```
bluetooth.service +87ms
└─bluetooth-addr.service @17.692s +30.062s
```

So Bluetooth is configured 106 s after power-on with no manual step, and the
`local-bd-address` device-tree route is **not** needed for this device.
