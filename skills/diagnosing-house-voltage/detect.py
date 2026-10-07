#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Segment a voltage record on sensor power-cycles, flag motor starts, report duty cycle.

Assumes nothing about your monitor's schema -- every column name is an argument.
Needs one row per aggregation window (a minute is typical) with at least a
timestamp and mean/min/max voltage for that window.

    ./detect.py log.csv --tz America/New_York
    ./detect.py log.csv --hi-col hi_max --lo-col lo_min --window 20:00-22:00

Latched-extreme columns are optional but worth wiring up if your monitor has them
(Ting: volts_hi_max / volts_lo_min): they turn "when was the sensor moved?" from a
question for the owner into a fact from the data.
"""

import argparse
import csv
import datetime as dt
import statistics as st
from itertools import pairwise
from zoneinfo import ZoneInfo


def load(path, args):
    rows = []
    with open(path) as f:
        for raw in csv.DictReader(f):
            row = {"t": dt.datetime.fromisoformat(raw[args.time_col])}
            if row["t"].tzinfo is None:
                row["t"] = row["t"].replace(tzinfo=dt.UTC)
            for key, col in (
                ("mean", args.mean_col),
                ("min", args.min_col),
                ("max", args.max_col),
            ):
                row[key] = float(raw[col]) if raw[col] not in ("", None) else None
            for key, col in (("hi", args.hi_col), ("lo", args.lo_col)):
                row[key] = (
                    float(raw[col]) if col and raw.get(col) not in ("", None) else None
                )
            if row["mean"] is not None:
                rows.append(row)
    rows.sort(key=lambda r: r["t"])
    for r in rows:
        r["sag"] = r["mean"] - r["min"]
        r["lift"] = r["max"] - r["mean"]
        r["motor"] = r["sag"] >= args.sag and r["sag"] >= args.ratio * r["lift"]
    return rows


def segments(rows):
    """Split on sensor power-cycles.

    Latched extremes are monotone while the device stays powered -- the high only
    rises, the low only falls. Either moving the wrong way means the device lost
    power, which in practice means somebody unplugged it and moved it. Comparing
    voltages across such a boundary compares two different vantages, so this split
    has to happen before any other analysis.

    With no latch columns the whole record is one segment, which is correct only if
    you know the sensor never moved.
    """
    if not rows or rows[0]["hi"] is None:
        return [rows]
    out, cur = [], [rows[0]]
    for prev, row in pairwise(rows):
        if row["hi"] < prev["hi"] - 0.05 or row["lo"] > prev["lo"] + 0.05:
            out.append(cur)
            cur = []
        cur.append(row)
    out.append(cur)
    return out


def runs(rows, threshold, half_width=30, percentile=0.75):
    """Contiguous windows depressed below a local reference = one load running.

    The reference is a high percentile of a sliding neighbourhood rather than a
    fixed number, so it tracks the diurnal drift of the supply instead of fighting
    it. A fixed baseline reports every evening as a fault.

    The neighbourhood is the assumption: the 75th percentile is only a resting
    voltage while resting windows outnumber running ones inside it. Once the load
    dominates -- duty above ~70%, or a single run comparable to 2*half_width --
    the reference sinks into the runs and duty is under-reported, silently and
    all the way to zero.

    Measured against synth.py fixtures, the run-length limb needs half_width at
    roughly 1.5x the longest run for an exact answer -- errors are mild up to
    half_width and severe by 2x. The duty limb has no such fix: past ~70% no
    half_width recovers the truth, and a wide one on a drifting record returns a
    plausible wrong answer instead of an obvious zero.
    """
    for i, row in enumerate(rows):
        near = sorted(
            x["mean"] for x in rows[max(0, i - half_width) : i + half_width + 1]
        )
        row["dep"] = near[int(percentile * len(near))] - row["mean"]
    out, cur = [], []
    for row in rows:
        if row["dep"] >= threshold:
            cur.append(row)
        elif cur:
            out.append(cur)
            cur = []
    if cur:
        out.append(cur)
    return [c for c in out if len(c) >= 2]


def report(rows, args, tz):
    starts = [r for r in rows if r["motor"]]
    gaps = [(b["t"] - a["t"]).total_seconds() / 60 for a, b in pairwise(starts)]
    active = runs(
        rows, args.depression, args.reference_window, args.reference_percentile
    )
    busy = sum(len(c) for c in active)

    print(
        f"    {len(rows)} windows, {rows[0]['t'].astimezone(tz):%Y-%m-%d %H:%M}"
        f" -> {rows[-1]['t'].astimezone(tz):%H:%M}"
    )
    print(
        f"    mean {st.fmean(r['mean'] for r in rows):.2f} V"
        f"  (sd {st.pstdev([r['mean'] for r in rows]):.3f})"
    )
    print(
        f"    motor starts: {len(starts)}"
        + (f", median gap {st.median(gaps):.0f} min" if gaps else "")
    )
    if starts:
        s = sorted(r["sag"] for r in starts)
        print(
            f"    start sag: median {st.median(s):.2f} V, range {min(s):.2f}-{max(s):.2f}"
        )
        print("      NOTE: sag amplitude is specific to THIS outlet. Do not compare it")
        print("      across segments without re-validating against a known load.")
    print(
        f"    duty cycle: {100 * busy / len(rows):.1f}%  ({busy} of {len(rows)} windows"
        f" depressed >= {args.depression} V, in {len(active)} runs)"
    )
    if active:
        lens = [len(c) for c in active]
        print(f"    run length: median {st.median(lens):.0f} windows, max {max(lens)}")


def main():
    p = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    p.add_argument("csv")
    p.add_argument("--time-col", default="observed_at")
    p.add_argument("--mean-col", default="volts_mean")
    p.add_argument("--min-col", default="volts_min")
    p.add_argument("--max-col", default="volts_max")
    p.add_argument(
        "--hi-col", default="volts_hi_max", help="latched running max; '' to disable"
    )
    p.add_argument(
        "--lo-col", default="volts_lo_min", help="latched running min; '' to disable"
    )
    p.add_argument(
        "--tz", default="UTC", help="timezone for display, e.g. America/New_York"
    )
    p.add_argument(
        "--sag", type=float, default=0.4, help="volts; minimum sag for a motor start"
    )
    p.add_argument(
        "--ratio", type=float, default=2.0, help="sag must exceed this multiple of lift"
    )
    p.add_argument(
        "--depression",
        type=float,
        default=0.20,
        help="volts below local reference to count a window as 'load running'",
    )
    p.add_argument(
        "--reference-window",
        type=int,
        default=30,
        metavar="WINDOWS",
        help="half-width of the neighbourhood the reference percentile is taken"
        " over (default 30, i.e. +/-30 min on minute rows). Wants ~1.5x the"
        " longest run you expect; below that, duty is under-reported",
    )
    p.add_argument(
        "--reference-percentile",
        type=float,
        default=0.75,
        metavar="P",
        help="quantile of the neighbourhood used as the resting voltage"
        " (default 0.75). Raise it to measure a load whose duty cycle"
        " exceeds it; see SKILL.md for what that costs",
    )
    args = p.parse_args()
    if args.reference_window < 1:
        p.error("--reference-window must be at least 1 window")

    tz = ZoneInfo(args.tz)
    rows = load(args.csv, args)
    segs = segments(rows)
    print(
        f"{len(rows)} windows in {len(segs)} segment(s)"
        + (" -- split on sensor power-cycles" if len(segs) > 1 else "")
    )
    if len(segs) > 1:
        print("Each segment is a DIFFERENT VANTAGE. Compare across them only via a")
        print("load you can repeat, never by absolute voltage or variance.\n")
    for i, seg in enumerate(segs, 1):
        if len(seg) < 10:
            continue
        print(f"\n=== segment {i} ===")
        report(seg, args, tz)


if __name__ == "__main__":
    main()
