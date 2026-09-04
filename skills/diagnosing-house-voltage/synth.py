#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Write a voltage record with a KNOWN duty cycle, to calibrate detect.py.

detect.py estimates duty cycle by depression against a rolling 75th percentile.
That estimate is exact over a wide band and silently wrong outside it, and no
real record tells you which side you are on -- real data has no answer key.
This writes one that does.

    ./synth.py 0.6 4 25 out.csv     # 0.6 V diurnal wander, 4-min runs every 25 min
    ./detect.py out.csv --hi-col '' --lo-col ''

It prints the truth it wrote. Compare that against what detect.py reports, and
in particular against the run-length line -- that is the tell described in
SKILL.md under Tooling.

Schema matches Ting's minute rows; pass --hi-col '' --lo-col '' to detect.py
since a synthetic record has no sensor power-cycles to segment on.
"""

import argparse
import csv
import datetime as dt
import math

BASE_VOLTS = 118.0
RUNNING_SAG = 0.70  # steady depression while the load runs
INRUSH_SAG = 1.60  # extra dip in the first window of a run, for motor detection
JITTER = 0.10  # intra-window spread when nothing is starting


def rows(n, drift, run_len, period, start):
    """One row per minute. A window is 'running' for the first run_len of each period.

    Yields (running, row) so the caller counts the answer key off what was actually
    written. A calibration fixture whose printed truth is recomputed from the same
    expression twice can drift from its own data; this one cannot.
    """
    for i in range(n):
        running = (i % period) < run_len
        starting = (i % period) == 0
        # Slow sinusoidal wander over the whole record -- the diurnal drift a
        # fixed baseline would misread as load.
        mean = BASE_VOLTS + drift * math.sin(2 * math.pi * i / n) - (RUNNING_SAG if running else 0.0)
        yield running, {
            "observed_at": (start + dt.timedelta(minutes=i)).isoformat(),
            "volts_mean": f"{mean:.3f}",
            "volts_min": f"{mean - (INRUSH_SAG if starting else JITTER):.3f}",
            "volts_max": f"{mean + JITTER:.3f}",
            "volts_hi_max": "121.000",
            "volts_lo_min": "111.000",
        }


def main():
    p = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    p.add_argument("drift", type=float,
                   help="amplitude in volts of the slow baseline wander -- one full sine"
                        " cycle across the whole record, so peak-to-peak is twice this")
    p.add_argument("run_len", type=int, help="windows the load runs for")
    p.add_argument("period", type=int, help="windows between the start of one run and the next")
    p.add_argument("csv", help="output path")
    p.add_argument("--windows", type=int, default=720, help="rows to write (default 720)")
    args = p.parse_args()

    if args.run_len > args.period:
        p.error("run_len cannot exceed period -- the load would never stop")
    if args.run_len < 0:
        p.error("run_len cannot be negative")
    if args.period < 1:
        p.error("period must be at least 1 window")
    if args.windows < 1:
        p.error("--windows must be at least 1")

    start = dt.datetime(2026, 8, 19, 6, 0, tzinfo=dt.UTC)
    out = list(rows(args.windows, args.drift, args.run_len, args.period, start))
    with open(args.csv, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(out[0][1]))
        w.writeheader()
        w.writerows(row for _, row in out)

    busy = sum(running for running, _ in out)
    print(
        f"GROUND TRUTH: {100 * busy / len(out):.1f}% duty, "
        f"runs of {args.run_len} windows every {args.period}, "
        f"{args.drift} V drift amplitude, {len(out)} windows"
    )


if __name__ == "__main__":
    main()
