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

## Tooling

`detect.py` in this directory: segments a CSV on latch resets, flags motor starts,
and reports duty cycle per segment. Column names are arguments — it assumes nothing
about your monitor's schema. Run with `--help`.
