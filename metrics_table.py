#!/usr/bin/env python3
"""
Extract per-shard time series for the three counters tracked in this
harness:

  * scylla_commitlog_flush
  * scylla_reactor_aio_retries
  * scylla_reactor_io_threaded_fallbacks  (summed across all "reason" labels)

Reads runs/<run-id>/metrics.log produced by run_test.sh — one /metrics
dump per scrape, each prefixed with "=== <UTC ts> ===" — and prints a
table with one row per scrape: cumulative counter values plus the
per-second rate over the bucket since the previous scrape.

Usage:
    ./metrics_table.py <shard> [run-dir]

If <run-dir> is omitted the most recent runs/* directory is used.
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys
from datetime import datetime

METRICS = (
    "scylla_commitlog_flush",
    "scylla_reactor_aio_retries",
    "scylla_reactor_io_threaded_fallbacks",
)

HEADER_RE = re.compile(r"^=== (\S+) ===$")
LINE_RE = re.compile(r"^([a-zA-Z_:][a-zA-Z0-9_:]*)\{([^}]*)\}\s+([0-9eE+\-.]+)$")
SHARD_RE = re.compile(r'shard="([^"]+)"')


def parse(metrics_log: pathlib.Path, shard: str) -> list[tuple[str, dict[str, float]]]:
    snapshots: list[tuple[str, dict[str, float]]] = []
    cur_ts: str | None = None
    cur: dict[str, float] = {}
    with metrics_log.open() as f:
        for line in f:
            line = line.rstrip("\n")
            h = HEADER_RE.match(line)
            if h:
                if cur_ts is not None:
                    snapshots.append((cur_ts, cur))
                cur_ts = h.group(1)
                cur = {m: 0.0 for m in METRICS}
                continue
            if not line or line.startswith("#"):
                continue
            m = LINE_RE.match(line)
            if not m:
                continue
            name, labels, value = m.group(1), m.group(2), float(m.group(3))
            if name not in METRICS:
                continue
            sm = SHARD_RE.search(labels)
            if not sm or sm.group(1) != shard:
                continue
            cur[name] += value
    if cur_ts is not None:
        snapshots.append((cur_ts, cur))
    return snapshots


def parse_ts(s: str) -> datetime:
    return datetime.strptime(s, "%Y%m%dT%H%M%SZ")


def latest_run_dir() -> pathlib.Path:
    here = pathlib.Path(__file__).resolve().parent
    runs = sorted((here / "runs").glob("*Z"))
    if not runs:
        sys.exit("No runs/<id>/ directories found.")
    return runs[-1]


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("shard", help='shard id (the value of the shard="N" label).')
    ap.add_argument("run_dir", nargs="?", help="path to a runs/<id>/ directory (default: latest).")
    args = ap.parse_args()

    run_dir = pathlib.Path(args.run_dir) if args.run_dir else latest_run_dir()
    metrics_log = run_dir / "metrics.log"
    if not metrics_log.is_file():
        sys.exit(f"{metrics_log} not found")

    snapshots = parse(metrics_log, args.shard)

    print(f"run={run_dir.name}  shard={args.shard}  snapshots={len(snapshots)}")
    print(
        f"{'timestamp':<17} {'dt':>4} {'commitlog_flush':>16} {'aio_retries':>13} "
        f"{'io_threaded_fb':>15}   {'rate_flush':>10} {'rate_aio':>9} {'rate_iofb':>10}"
    )
    prev: tuple[str, dict[str, float]] | None = None
    for ts, vals in snapshots:
        cf = vals["scylla_commitlog_flush"]
        ar = vals["scylla_reactor_aio_retries"]
        io = vals["scylla_reactor_io_threaded_fallbacks"]
        if prev is None:
            print(f"{ts:<17} {'-':>4} {cf:>16.0f} {ar:>13.0f} {io:>15.0f}   {'-':>10} {'-':>9} {'-':>10}")
        else:
            dt = (parse_ts(ts) - parse_ts(prev[0])).total_seconds()
            rf = (cf - prev[1]["scylla_commitlog_flush"]) / dt if dt else 0
            ra = (ar - prev[1]["scylla_reactor_aio_retries"]) / dt if dt else 0
            ri = (io - prev[1]["scylla_reactor_io_threaded_fallbacks"]) / dt if dt else 0
            print(
                f"{ts:<17} {dt:>4.0f} {cf:>16.0f} {ar:>13.0f} {io:>15.0f}   "
                f"{rf:>10.2f} {ra:>9.2f} {ri:>10.2f}"
            )
        prev = (ts, vals)


if __name__ == "__main__":
    main()
