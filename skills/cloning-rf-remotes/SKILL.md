---
name: cloning-rf-remotes
description: Use when reverse-engineering a 433/315 MHz OOK remote (ceiling fan, outlet/light switch, garage, doorbell) to replay it from software — capturing with an RTL-SDR + rtl_433, decoding the pulse train, and driving a generic transmitter (ESP8266/ESP32 + TX module). Covers the capture-coordination race, the replay-before-you-trust verification, and the interference-vs-range failure split.
---

# Cloning RF Remotes

Capture a cheap OOK remote with an RTL-SDR, decode its pulse train, and replay
it from a microcontroller — so any RF-controlled device becomes network-addressable.

**The physics is the easy part; the models already know it.** What actually
sinks these projects is three operational traps: coordinating button presses
without racing the capture, proving your replay is byte-correct *before* you
trust a silent device, and telling "my signal is wrong" apart from "my signal
didn't arrive." This skill is about those three. For the encoding math itself
see [reference.md](reference.md).

## The one architectural rule

**The transmitter learns exactly one trick: emit an explicit train of
`[high_µs, low_µs]` pairs. It never learns a second protocol.**

Every OOK scheme — PWM, PDM, PT2262/PT2260 tri-state, EV1527 — is just a pulse
train at the pin. Put all protocol knowledge in software that *derives* the
pulse train from a captured code, keep the firmware a dumb pulse pump, and you
never reflash to support a new device. Corollary: the device profile (codes +
timings) is the single source of truth; any control CLI, web bundle, or
Home Assistant config is *derived* from it, never hand-maintained alongside it.

## Workflow

```
Confirm dongle → Capture (coordinated) → Decode → Profile → Verify by replay → Switch real device → Record
```

### 1. Confirm the dongle before anything else

```bash
rtl_test -t          # RTL2838 enumerates, tuner recognized? Ctrl-C after ~2s.
```

If "No supported devices found," stop — the dongle isn't plugged in. Don't
burn a capture session discovering this.

### 2. Capture — the coordination race is the whole game

**The trap:** a foreground `rtl_433` that the human is told to "press when it
starts" races the human reading the message. They press before the SDR is
listening, and you capture silence. This *will* happen with a synchronous
say-go/say-done loop.

**The fix — an asynchronous window the human closes:**

1. Start the capture as a **background task** with a generous timeout:
   ```bash
   rtl_433 -f 433.92M -A -S unknown -T 90 > capture.log 2>&1   # run in background
   ```
   - `-A` prints the pulse analysis and a suggested flex decoder live
   - `-S unknown` saves every detected burst to `g###_433.92M_250k.cu8`
   - `-T 90` auto-exits after 90 s so a wandering human never leaves it hung
2. **Signal that the window is open** with something the human can't miss while
   looking away — an audible beep (`osascript -e 'beep 2'` on macOS) or a push
   notification. This is the single highest-leverage habit here: humans multitask.
3. Human presses **one** button, ~1 second, and says "done."
4. **Close early on their word** — don't wait out the timeout:
   ```bash
   pkill -INT rtl_433    # SIGINT = clean flush + save, same as Ctrl-C
   ```
5. Rename the largest `.cu8` to `captures/<device>_<button>.cu8` and delete the
   noise fragments (interference produces many tiny files; the real press is the
   big one).

One button per window. Capture **every** button on **every** physical unit —
comparing units is how you find which bits are the address and which are the
command (see reference.md).

### 3. Decode

`rtl_433 -A` usually prints the code outright, e.g. `codes: {25}eaaa3c8` plus
`short_width`/`long_width`/`reset_limit`. Read the code off the analyzer,
machine-verify your hand-decode of the hex into symbols with a throwaway
script (cheap insurance — see reference.md for the bit→symbol mapping), and
record measured short/long/sync-gap µs. If `-A` is ambiguous, ladder down:
URH → upload the `.cu8` to triq.org/pdv → Audacity on an AM-demod recording.

Sanity check across presses: all repeats of one button must decode identically,
and each press should show several repeated frames. A mangled tail frame is
normal — take the **majority code across frames**, not the first one.

### 4. Write the device profile

One file per device, codes + timings, as the single source of truth. Store the
**full code per button** rather than assuming a clean address/command split —
factor it later only if the capture proves the split is clean (it often isn't).
See [reference.md](reference.md) for a worked profile and the encoder.

### 5. Verify by replay — the SDR is your referee

**Never let the physical device be your first test.** A silent device tells you
nothing: wrong code, dead RF link, and unpaired receiver all look identical.
Instead, put the SDR back on your *own* transmitter:

1. Start the same `rtl_433 -A` capture in the background.
2. Fire the replay from your control software.
3. Diff the decoded output against the remote's original capture. **Pass = same
   code, pulse widths within ~10%.** Now you *know* the air signal is right, and
   any remaining failure is downstream (link or pairing), not encoding.

Only after this passes do you switch the real device.

### 6. When the real device doesn't respond: interference vs. range

Both look like silence; they have opposite fixes. **One capture splits them:**
trigger the dead unit and a known-good unit into the same background window and
compare.

| Evidence | Cause | Fix (cheapest first) |
|---|---|---|
| Your replay's code is wrong / widths skewed (from step 5) | Encoding bug | Fix the profile/encoder — free |
| Dead unit's frames arrive mangled; noise floor raised in the log | **Transient interference** | Retry; it passes on the next window |
| Both units get identical clean frames but only one switches | **Range / dead spot** | Reposition TX a foot; 17.3 cm quarter-wave wire on the ANT pad; 5 V not 3.3 V to the module |
| Fresh capture of the *factory remote* differs from your profile | Bad original capture / learning-code receiver | Re-capture; re-pair |

At 433 MHz (~69 cm wavelength) indoor reflections create **standing-wave nulls**
— a spot where signal cancels. A near unit with clear line-of-sight can sit in a
null while a farther one receives fine; distance and sightline lie. That's why
"move the transmitter a foot" outranks any software change once step 5 has
proven the signal correct. More repeats rescue a *marginal* spot but never fill
a deep null.

### 7. Record for posterity

Commit the `.cu8` captures, the profile, and a protocol doc (measured timings,
the code table, observed address/command structure, and the exact `rtl_433`
command used). The next device follows the same playbook from this record.

## Red flags — you're about to lose a session

- **"Press the button when the capture starts"** (synchronous) → race. Use a
  background window + beep + `pkill -INT`.
- **Testing on the real device first** → you can't tell wrong-code from
  no-signal. Replay-verify with the SDR first.
- **"It's the closest outlet, must be a code bug"** → could be a null. Run the
  A/B capture before touching software.
- **Adding a per-protocol branch to the firmware** → the firmware is a pulse
  pump. Derive the pulse train in software.
- **Hand-editing the derived CLI/web/HA config** → edit the profile, regenerate.

## See also

- [reference.md](reference.md) — OOK encoding families, PT2262/PT2260 tri-state
  math, bit→symbol decode, a worked YAML profile, the pulse-train encoder, and
  firmware validation limits.
