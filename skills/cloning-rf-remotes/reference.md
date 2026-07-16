# Cloning RF Remotes — Reference

Encoding families, decode math, and worked code for the [SKILL.md](SKILL.md)
workflow. Load this when you're actually decoding a capture or writing the
profile/encoder.

## OOK encoding families

OOK (on-off keying) switches the carrier fully on or off — every scheme below
is just *how long* it stays on vs. off per symbol. The receiver only cares about
the pulse train, which is why one generic transmitter replays all of them.

| Family | Symbol encoding | Seen in |
|---|---|---|
| **PWM** (pulse-width) | bit value = which of high/low is the long one | many fans, EV1527 |
| **PDM** (pulse-distance) | fixed short pulse, gap length carries the bit | some fans |
| **PT2262 / PT2260 / HS2260** | tri-state: `0`, `1`, **`F`** (floating) | outlets, light switches |
| **EV1527 / PT2260 learning** | 24-bit code, receiver learns it on pairing | ZAP-style outlets |

Don't trust the family name from memory — `rtl_433 -A` measures the actual pulse
widths and prints a flex-decoder spec. Believe the measurement.

## PT2262/PT2260 tri-state math

Base clock **α** (short pulse), typically 150–320 µs. Everything is a multiple:

- short = 1α, long = 3α, sync gap = 31α (the long LOW that ends a frame)
- A **symbol** is two pulse *halves*:
  - `0` = (short-high, long-low) then (short-high, long-low)  → "11" in raw pulses
  - `1` = (long-high, short-low) then (long-high, short-low)  → "00"
  - `F` = (short-high, long-low) then (long-high, short-low)  → "10" (floating)
- 12 symbols/frame → 24 pulse halves + 1 sync pair = **25 pairs**
- Real remotes send ~5–15 repeated frames per press; a receiver wants several
  clean consecutive ones.

**Why `F` matters:** an encoder that only knows `0`/`1` will *usually* produce
the right waveform anyway (F's raw pulses look like a 0-then-1), so three units
work and the one whose code needs a true F fails. Handle F explicitly.

### Decoding rtl_433's hex into symbols

`rtl_433` OOK_PWM emits raw bits: **short pulse → `1`, long pulse → `0`**. Pair
them up and map back to tri-state symbols; the 25th bit is the sync pulse.

```python
# rtl_433 code like {25}eaaa3c8  → 12 tri-state symbols
PAIR = {"11": "0", "00": "1", "10": "F"}   # inverse of the symbol table above

def hex_to_tristate(hexcode: str, n_bits: int = 25) -> str:
    bits = bin(int(hexcode, 16))[2:].zfill(len(hexcode) * 4)[:n_bits]
    data, sync = bits[:24], bits[24]
    assert sync == "1", "sync bit should be a short pulse"
    return "".join(PAIR[data[i:i+2]] for i in range(0, 24, 2))
```

Run this over every captured button and machine-verify it matches what you'll
put in the profile — a 30-second script that catches transcription errors before
they reach hardware.

## Finding address vs. command bits

Capture the *same button* on two physical units, then *different buttons* on one
unit. Bits constant across units but varying across buttons = command. Bits
constant across buttons but varying across units = address. **But**: cheap
remotes don't always split cleanly (a one-hot position marker walking through the
"address" region, ON/OFF in the last two symbols, etc.). If the split isn't
obviously clean, **store the whole code per button** and move on — the encoder
doesn't care.

## Worked device profile

One file per device; codes and timings are the single source of truth.

```yaml
# Etekcity ZAP 5LX outlet remote
frequency_mhz: 433.92        # documentation-only: the TX module is SAW-locked here
encoding: PT2260

timing:
  short_us: 184              # measured α (rtl_433 timing distribution)
  long_us: 548               # ~3α
  sync_gap_us: 5684          # ~31α, the long LOW ending each frame
  repeat_count: 6            # frames per transmit; receiver wants a few clean ones

# Full 12-symbol code per button — no address/command factoring assumed.
units:
  window:  { position: 2, codes: { on: "0FFFFFFF1001", off: "0FFFFFFF1010" } }
  couch:   { position: 3, codes: { on: "0FFFFFF10001", off: "0FFFFFF10010" } }
  speaker: { position: 4, codes: { on: "0FFFFF1F0001", off: "0FFFFF1F0010" } }
  chairs:  { position: 5, codes: { on: "0FFFF1FF0001", off: "0FFFF1FF0010" } }
```

## The pulse-train encoder

Derives the transmitter payload from a code string. This is the *only* place
that knows PT2260; the firmware never does.

```python
# Each tri-state symbol → two (high_us, low_us) pulse halves.
_SYMBOLS = {
    "0": (("short", "long"), ("short", "long")),
    "1": (("long", "short"), ("long", "short")),
    "F": (("short", "long"), ("long", "short")),
}

def pt2260_pulses(code: str, timing: dict) -> list[tuple[int, int]]:
    """Encode a tri-state code as [(high_us, low_us), ...]; sync pair last."""
    dur = {"short": timing["short_us"], "long": timing["long_us"]}
    pulses = []
    for symbol in code:
        if symbol not in _SYMBOLS:
            raise ValueError(f"invalid PT2260 symbol {symbol!r} (want 0/1/F)")
        for high, low in _SYMBOLS[symbol]:
            pulses.append((dur[high], dur[low]))
    pulses.append((timing["short_us"], timing["sync_gap_us"]))  # sync ends LOW
    return pulses
```

The sync pair is appended **last** so repeated frames are contiguous valid
codewords and the TX pin is always left LOW between frames.

## Firmware: the generic pulse pump

The microcontroller exposes one transmit path: accept `{"pulses": [[h,l],...],
"repeat_count": n}` and bit-bang it. Mirror these validation limits on **both**
sides (host rejects with a readable message; firmware rejects malformed input):

| Limit | Value | Why |
|---|---|---|
| µs per value | 1..100000 | sane pulse bounds |
| pulse pairs | 1..256 | one frame fits comfortably |
| repeat_count | 1..100 | |
| total duration | `repeat_count × Σ(high+low) ≤ 5,000,000 µs` | `delayMicroseconds` busy-waits; the ESP8266 soft-WDT resets at ~3.2 s |

Feed the watchdog **inside** the pulse loop (per pair), not per frame —
`delayMicroseconds` is a busy-wait and a long frame will otherwise trip the WDT.

```cpp
void transmitPulses(JsonArrayConst pairs, int repeat_count) {
    for (int r = 0; r < repeat_count; r++) {
        for (JsonArrayConst pair : pairs) {
            digitalWrite(TX_PIN, HIGH); delayMicroseconds(pair[0].as<uint32_t>());
            digitalWrite(TX_PIN, LOW);  delayMicroseconds(pair[1].as<uint32_t>());
            ESP.wdtFeed();   // per pair: delayMicroseconds is a busy-wait
        }
    }
}
```

## Timing-skew note

Cheap TX modules have asymmetric rise/fall: they stretch HIGH pulses and shorten
LOWs by ~20 µs. `rtl_433 -A` on the *remote* may report e.g. 204/576 µs highs
and 160/528 µs lows around a true 184/548 α. Store the symmetric chip-level
timings (the underlying α and 3α) in the profile; if your replay's widths drift
>10% from the remote's in the step-5 verification, nudge the profile timings —
never the firmware.

## Hardware notes

- **Antenna is the biggest free win.** A bare TX module radiates a whisper.
  Solder a **17.3 cm** (quarter-wave at 433 MHz) straight wire to the ANT pad —
  often 10–20 dB, more than any software change.
- **Power scales output.** Feed the module 5 V (VIN) not 3.3 V where it tolerates it.
- **`.cu8`** = raw 8-bit IQ samples at 250 ksps, rtl_433's archival format. Keep
  them; they let you re-decode with new parameters without re-pressing buttons.
