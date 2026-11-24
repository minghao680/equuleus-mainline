# Bluetooth handoff: the WCN3990 will not take its factory address on time

Scope: one feature, one problem. Everything here is about getting Bluetooth up on
the Xiaomi Mi 8 Pro (`equuleus`, SDM845) under mainline Linux, from a cold boot,
with no manual step. Display, Wi-Fi, audio and charging are out of scope except
where they share the combo chip or the boot ordering.

Status at the time of writing: **the controller works, but it does not come up by
itself reliably.** Configuring it by hand always works once the controller has
settled. Automating that has failed so far for a reason that is not yet
identified.

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

This is the crux, and it is not yet explained. Run by hand, the following works
every single time:

```
systemctl start bluetooth.service     # bluetoothd opens/powers the controller
sleep 6
systemctl stop  bluetooth.service
btmgmt -i hci0 public-addr a4:50:46:b3:ed:3c
  -> hci0 Set Public Address complete
btmgmt -i hci0 power on
  -> hci0 Set Powered complete   -> hciconfig shows UP RUNNING
```

The same steps issued from inside `bluetooth-addr.sh` do not, even with
`--no-block` and even while polling until `bluetooth.service` reports `active`.
The observable difference is `btmgmt info`:

* after a successful manual sequence: the management index exists;
* inside the unit: `Index list with 0 items`, and each `btmgmt public-addr` blocks
  until it is killed by `timeout`.

So the controller is only opened when `bluetoothd` runs **from a context that is
not this unit's**. Candidates the next agent should check: whether `systemctl`
issued from a service actually performs the start job (it may be queued behind the
unit itself, or rejected), whether `btmgmt` needs a session/seat that a service
lacks, or whether the start is happening but the daemon exits before opening the
device because of how it is signalled.

A direct experiment that settles it: add `logger`/`echo` lines around the
start/stop inside the unit and compare `systemctl status bluetooth` plus
`btmgmt info` at each step, from the unit and from an SSH shell on the same boot.

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