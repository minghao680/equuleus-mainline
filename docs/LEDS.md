# White notification LED and rear torch

Both LEDs use the PMI8998, not the camera sensor or its power rails. No LED
trigger is selected at boot. This change adds no service or shortcut.

## White notification LED

`/sys/class/leds/white:status` is the white status LED on LPG channel 5
(`0xb500`). It supports normal brightness (`0` through `511`) and the PMIC's
hardware pattern generator. Run these commands as root to start a dim,
repeating hardware breathing pattern. The two pairs for each level tell the
LPG driver to hold that level and then step immediately to the next one.

```sh
led=/sys/class/leds/white:status
printf 'pattern\n' > "$led/trigger"
printf '%s\n' -1 > "$led/repeat"  # Use 1 for a single cycle.
pattern=
for level in 0 2 4 7 11 17 24 33 44 58 75 58 44 33 24 17 11 7 4 2 0; do
    pattern="${pattern}${pattern:+ }$level 60 $level 0"
done
printf '%s\n' "$pattern" > "$led/hw_pattern"
```

Stop the pattern and switch off the LED:

```sh
led=/sys/class/leds/white:status
printf 'none\n' > "$led/trigger"
printf '0\n' > "$led/brightness"
```

## Rear torch (experimental)

`/sys/class/leds/white:torch/brightness` is the Linux LED-class intensity
control, `0` (off) to `255`. The board describes only the first rear output
(vendor channel 0, `led-sources = <1>`). The driver limits its **requested**
current to 50 mA; current is quantized in 5 mA steps, not 255 distinct levels.
There is no high-current camera strobe or automatic torch trigger.

Do not rely on this output for illumination yet. In a short test, brightness
`51` set a nominal 10 mA target and enabled the channel. The PMIC briefly
reported `STATUS1=0x02`, and its independent torch clamp read `0x27` instead of
the expected `0x09`. The vendor driver treats nonzero `STATUS1` bits as
short/open LED-path faults; this result does not identify the component or
confirm a damaged LED. Turning off the torch cleared both the channel and
module enable. A later guarded check at brightness `255` set the nominal
50 mA target but immediately reproduced `STATUS1=0x02`, so the output was
switched off after about 0.1 s. The different target codes confirm that the
brightness control programs different levels, not that the actual current or
visible light changes. Do not work around the PMIC's protection or enable the
other flash outputs on the basis of these tests.

## Test scope

A temporary boot image reused the deployed kernel and initramfs; its only DTB
changes were these two LED nodes. Both devices registered with brightness `0`.
The notification LED's one-shot hardware test read back the intended 11-entry
rising lookup table, 60 ms step duration, ping-pong mode and output enable.
The repeating example above was also checked: the PMIC repeat bit was set,
and the output was still enabled beyond one cycle. After clearing the trigger,
the output and RGB sink enable bits both cleared.
This verifies PMIC programming and shutdown, not optical output. No boot or
userdata partition was written.
