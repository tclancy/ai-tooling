---
name: diagnosing-house-voltage
description: Use when diagnosing a household electrical complaint against a time-series voltage record from a plug-in monitor (Ting, Sense, Emporia, Shelly) — flickering lights, an unexplained bill increase or phantom load, breakers or pressure switches that keep failing, equipment tripping offline, or "is this circuit or the whole house?". Also when the sensor has been moved between outlets, or when a chart shows a step change that might be an artifact.
---

# Diagnosing house voltage

A voltage record measures **one point** in a house. Everything below exists to stop
you over-reading that point.

## The inversion that traps everyone first

**A sag visible on every circuit is what ONE load looks like.**

Every branch shares the service drop, meter and main panel, so any large load drops
voltage for all of them simultaneously. "It shows up everywhere" therefore says the
load is big — **not** that the fault is distributed, and not that it is the utility's
problem.

People report this backwards almost every time. Expect it, and expect to fall for it
yourself after you have already disproved it once.

## Quick reference

| Question | What answers it |
|---|---|
| Is this circuit or the whole house? | Same known load, measured from two circuits. Not variance comparison. |
| Was that a motor starting? | `sag ≥ 0.4 V` and `sag ≥ 2 × lift` — see Asymmetry below |
| Is the supply itself weak? | `Z = ΔV / I` from a known load. 0.05–0.15 Ω is normal residential |
| Does this explain the bill? | `watts ≈ duty_cycle × running_watts` |
| When did the sensor move? | Latched extremes reset — see Segment first |
| Is that step change real? | Re-measure with a rolling window, not clock-hour bins |

## Segment first — the record is not one experiment

If the sensor has been moved, **every comparison across the move is invalid** until
you know where the boundaries are. Do not trust anyone's memory of when they moved
it, including your own notes.

Most monitors report a running min/max the device latches since power-on. Those are
monotone — the max only rises, the min only falls — so **any reset marks an unplug,
to the minute**. Segment on those resets before analysing anything.

The same property makes each step *down* in the latched minimum a real sub-sample dip
the device caught between your samples: a finer event detector than the per-sample
minimum.

## Asymmetry identifies motors

A motor start collapses the floor and leaves the ceiling alone. General noise moves
both.

```
sag  = mean - min        # within one aggregation window
lift = max - mean
start := sag >= 0.4 and sag >= 2 * lift
```

**Validate the threshold against a load you already know before trusting it.** Have
someone run a large motor at a noted time. Measured separation in one house: known
power tools scored `sag/lift` of 6–16, quiet periods 1–2, no overlap. Your numbers
will differ; the *separation* is what you are checking for.

A run also has a shape — sharp inrush, deepest at start, then easing as the load
settles or a tank pressurises. Shape survives being mimicked; amplitude does not.

## Never hardcode an amplitude

The same load reads differently from every outlet, because each vantage sits behind a
different amount of branch wiring. One well pump measured 0.64–0.71 V across three
circuits in the same house. **Derive thresholds per segment**, the way a baseline is
derived per hour-of-day, or the skill breaks the moment the sensor moves.

## Controlled stimulus beats observation

Comparing quiet-period variance between two circuits is dominated by time-of-day
confounds — grid load, household activity, weather — and can burn days.

**Ask for a load you can repeat**: a power tool, a pump, an oven element. One labelled
start settles more than a week of watching. Prefer a **240 V** load if you have one:
it draws on both legs, so its sag appears whichever leg your sensor is on, which
removes an entire class of invalid comparison.

If a load already cycles on its own — a pump, a compressor — it is a free repeating
stimulus. Use it and ask nobody for anything.

## Duty cycle is the bridge to the bill

Voltage records feel disconnected from money. They are not:

```
average_watts ≈ duty_cycle × running_watts
```

A ~250 W phantom against a ~900 W pump is ~28% duty. That converts a utility-bill
complaint into something a voltage log can confirm or refute in an evening — and it
is often the only number anyone will act on.

**Quote a duty cycle with the window it came from, or it means nothing.** The same
pump over one 30-hour record read 46% with the house awake, 20% after midnight, and
10.6% between 03:00 and 06:00 (measured in `tclancy/parsons-pulse#33`; these four
figures come from a private record, so unlike the Tooling section below they cannot be
re-derived from this repo — cite the source rather than re-deriving them from memory). Only the whole-stint 28.7% is comparable to a monthly
bill; the overnight figure is three times under it and would have refuted a load that
was really there. Pick the window that matches what you are comparing against.

**The gradient is itself a diagnostic.** A pure leak runs at a constant rate, so it
reads flat across those windows. A duty cycle that tracks household activity is
serving something, not escaping from something — that is a load, and it has an owner.

**Depression against a rolling percentile is a sound way to find runs, but the
reference has a neighbourhood — and when the load dominates that neighbourhood the
estimate fails toward zero, silently.** A high percentile of the surrounding hour is
only a *resting* voltage while resting windows outnumber running ones inside it. So
**a low duty cycle is evidence of a small load only once you have ruled out a
near-continuous one.** Calibrate against a record whose answer you already know before
quoting a number; the Tooling section has the measured failure boundaries and a
generator for making such records.

**A match against the bill is a real result — state its uncertainty rather than
discounting it.** Duty-cycle-times-nameplate and a utility bill share no assumptions,
so agreement between them is the most load-bearing thing a voltage log can produce.
It carries error bars on both sides: pump size is usually a guess, and the appliance
that keeps the pump running draws its own power too. Give the range (a 230–277 W bill
figure against a 258 W derived one is a match) instead of a single number.

## Isolate physically; halve the search space

When something cycles that shouldn't, don't reason about which of six causes it is.
Have someone close valves or open breakers in sequence, one window each, and watch
whether the cycling stops. Each step eliminates a whole branch of the tree, costs
nothing, and produces a result a tradesperson will accept.

## A null result needs a positive control

"The trace was flat during the event" only means something if the instrument was
demonstrably capable of seeing it. Establish sensitivity first — a known load, or a
count of ordinary events it does detect — then a flat trace **localises** the fault
downstream of the sensor rather than proving nothing happened.

## Common mistakes

| Mistake | Reality |
|---|---|
| "It's on every circuit, so it's the utility" | That is what one large load looks like. See the inversion above. |
| Comparing circuits by quiet-period variance | Time-of-day confounds swamp the difference. Use a known load. |
| Trusting a recalled sensor-move time | Derive it from the latch reset. Memory is wrong often enough to matter. |
| Bucketing by clock hour, then reporting a step | Hour bins put every edge on an hour boundary. Re-measure with a rolling window before believing any step change. |
| Bucketing days in UTC for a house | Local midnight is what a household experiences; UTC days start mid-evening and file evening events under tomorrow. |
| Calling a component faulty because it failed twice | Contacts pit from *operations × arc energy*. Two failures usually means something upstream is cycling it, not that the part is bad. |
| Publishing a verdict from a window that just ended | Wait for the recovery. A restart can arrive minutes after you have declared everything healthy. |
| A derived number that matches what you expected | Agreement with a prior estimate is a reason to re-check the derivation, not to stop. Two wrong things can agree. |
| Naming the machine behind a regular cadence | A cadence proves a timer, not *which* timer. Confirm it by switching the candidate off and watching the rhythm stop — a fridge compressor cycles every 20–40 min and mimics almost anything. |
| A near-zero duty cycle on a load somebody can hear running | A percentile-referenced detector reports "always on" as "never on". Re-run at a higher `--reference-percentile` before you report an absence — if the answer moves, the first one was past its ceiling. |

## Tooling

`detect.py` in this directory: segments a CSV on latch resets, flags motor starts,
and reports duty cycle per segment. Column names are arguments — it assumes nothing
about your monitor's schema. Run with `--help`.

`synth.py` alongside it: writes a record whose duty cycle and run length you already
know, so `detect.py` can be calibrated against ground truth before it is pointed at
data whose answer nobody has. It prints the truth it wrote.

`calibrate.sh` runs the sweeps below and prints them as markdown. **Every duty-cycle
figure in this section is its output.** Re-run it after any change to `detect.py` and
paste the result back rather than editing a number by hand — a document describing a
tool's failure boundaries has to be derived from the tool, or it ends up describing a
tool that no longer exists.

### Read the run-length line, not just the duty cycle

`runs()` marks a window as running when it sits `--depression` volts below the 75th
percentile of a neighbourhood `--reference-window` wide either side. That reference is
only a *resting* voltage while resting windows outnumber running ones inside it, so the
estimate has boundaries — and the run-length line printed underneath is what makes two
of the three legible before you quote the number.

**The figures below are from a noiseless, single-load fixture. They are the optimistic
case.** Real minute means carry supply noise and overlapping loads, both of which push
the reference down; treat the boundaries as the best the estimator will ever do, not as
its typical behaviour.

### 1. Duty above the reference percentile — the cliff, and only one lever moves it

`calibrate.sh`, run length and drift held, period varied:

| true duty | reported | run length (median / max) |
|---|---|---|
| 50.0% | 50.0% | 10 / 10 |
| 60.0% | 60.0% | 12 / 12 |
| 65.0% | 64.4% | 13 / 13 |
| 70.0% | 68.3% | 14 / 14 |
| 75.0% | **25.7%** | 5 / 15 |
| 80.0% | **0.8%** | 6 / 6 |
| 85.0% | **0.0%** | — / — |
| 90.0% | **0.0%** | — / — |

Past ~70% the 75th percentile is *inside* the runs and the estimate collapses downward.
**The ceiling is the percentile — literally.** `--reference-percentile` moves it:

| true duty | `0.75` (default) | `0.90` | `0.95` |
|---|---|---|---|
| 20.0% | 20.0% | 20.0% | 20.0% |
| 50.0% | 50.0% | 50.0% | 50.0% |
| 70.0% | 68.3% | 70.0% | 70.0% |
| 75.0% | 25.7% | 75.0% | 75.0% |
| 80.0% | 0.8% | 80.0% | 80.0% |
| 90.0% | 0.0% | 12.8% | 90.0% |
| 95.0% | 0.0% | 0.0% | 4.0% |

Each column is exact right up to a true duty of about its own percentile, then falls off
the same cliff. So the knob exists — but you cannot set it correctly in advance, because
setting it requires the answer you are trying to measure.

**Use the disagreement instead.** Run it twice, at `0.75` and `0.90`. At a true 50% both
return 50.0%; at a true 80% they return 0.8% and 80.0%. **A duty cycle that moves when
you raise the percentile was below its ceiling at the lower setting** — that is the
warning the single-run output cannot give you, and it costs one extra invocation.

Do not simply default to `0.95` and forget it. This fixture is noiseless, so it prices
the benefit and not the cost: on a real record a high quantile sits up in the noise band
rather than on the resting voltage, inflating every window's depression. Raise it
deliberately, for a load you have reason to think is near-continuous, and sanity-check
the result against the run-length line.

Widening `--reference-window` is *not* the lever here, and reaching for it makes things
worse rather than merely not-better. Same 80%-duty fixture, drift varied:

| drift amplitude | `--reference-window 30` | `120` | `300` |
|---|---|---|---|
| 0.0 V | 0.0% | 0.0% | 0.0% |
| 0.2 V | 0.0% | 0.0% | 28.2% |
| 0.4 V | 0.0% | 41.4% | 44.9% |
| 0.6 V | 0.0% | **52.8%** | **53.5%** |

With no baseline wander a wide window keeps returning an obvious `0.0%`. With realistic
wander it returns **53% on a true 80% load**, stable across window widths — so a sweep
that settles reads exactly like a converged answer. **A `--reference-window` sweep that
stops moving is not evidence you have escaped the ceiling.** Only the percentile
disagreement above is.

**The thing to carry: at the default settings this detector cannot tell "no load" from
"load almost always on".** A duty cycle that comes back near zero — or merely lower than
expected — on a complaint that began with somebody hearing a pump run is this case until
a second percentile, a shorter window, or a clamp meter says otherwise.

### 2. Runs long relative to `--reference-window` — recoverable, but silent at the mild end

Duty held at 50%, run length varied against the default `--reference-window 30`:

| runs of | reported (true 50%) | run length (median / max) |
|---|---|---|
| 5 windows | 50.0% | 5 / 5 |
| 10 windows | 50.0% | 10 / 10 |
| 20 windows | 50.0% | 20 / 20 |
| 30 windows | 48.8% | 30 / 30 |
| 45 windows | 46.0% | 45 / 45 |
| 60 windows | **22.9%** | **15** / 15 |

Note where the tell appears and where it does not. At 30 and 45 windows the duty cycle
is already drifting down while the run length reads *correctly* — no symptom at all. It
only announces itself at 60, by reporting a median of 15 against a load that runs 60.

`--reference-window` fixes this limb, but it is not monotone — do not just make it huge:

| `--reference-window` | true 50%, runs of 60 | true 80%, runs of 8 |
|---|---|---|
| 30 | 22.9% | 0.0% |
| 60 | 50.0% | 33.3% |
| 90 | 50.0% | 48.2% |
| 120 | 50.0% | 52.8% |
| 300 | **66.5%** | 53.5% |

Aim for roughly 1.5× the longest run you expect. Below that it under-reports; far above
it, the reference starts tracking the drift instead of the supply and it over-reports.
Because the mild end has no symptom, **set this deliberately for any load that runs for
tens of minutes** rather than waiting for the run-length line to complain.

### 3. `--depression` below the drift gradient — over-reports, and does say so

Same fixture (true 16.1%) at every threshold:

| `--depression` | reported | run length (median / max) |
|---|---|---|
| 0.05 V | **47.8%** | 4 / **117** |
| 0.10 V | 16.9% | 4 / 6 |
| 0.20 V | 16.1% | 4 / 4 |
| 0.40 V | 16.1% | 4 / 4 |
| 0.60 V | 16.1% | 4 / 4 |

This is the one failure the run-length line catches unambiguously: a `max` of 117 against
a load that runs 4 windows. The threshold has to clear the baseline wander across
±`--reference-window`, or the falling limb of the drift is itself counted as load. Above
that it barely matters — 0.2, 0.4 and 0.6 V all return the exact answer. **Raise
`--depression` until `max` settles near the median**, then stop.

### What `synth.py` does not calibrate

Only the duty-cycle path. Its motor starts are a fixed 1.60 V sag against a fixed 0.10 V
lift, so every start scores a `sag/lift` of 16 and `--sag` / `--ratio` pass at any setting
a reader would try. The 6–16 separation the Asymmetry section is about has to be
established against a real load on the real outlet; there is no substitute here.
