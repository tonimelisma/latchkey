#!/usr/bin/env python3
"""Splits the tests that run one at a time (page-suites.txt, timing-suites.txt) into N groups
of about equal time, for mac-build.yml's side-by-side jobs (Toni, 2026-11-26: "split the slow
step into parallel jobs, get it to 5 minutes").

Usage: shard-suites.py <jobs> <job index> [<seconds already in job 0>]
Prints the suites for that job, one per line. Times come from suite-seconds.txt ("seconds
suite" per line, measured in CI; each run prints fresh ones as SUITE lines); a suite not
listed counts 20 s. Largest first into the emptiest job (always the same answer for the same
files, so every job agrees on the split).
"""
import pathlib
import sys

here = pathlib.Path(__file__).parent
jobs, index = int(sys.argv[1]), int(sys.argv[2])
head = float(sys.argv[3]) if len(sys.argv) > 3 else 0.0
suites = []
for name in ("page-suites.txt", "timing-suites.txt"):
    for line in (here / name).read_text().split("\n"):
        if line.strip() and line.strip() not in suites:
            suites.append(line.strip())
seconds = {}
known = here / "suite-seconds.txt"
if known.exists():
    for line in known.read_text().split("\n"):
        parts = line.split()
        if len(parts) == 2:
            seconds[parts[1]] = float(parts[0])
load = [head] + [0.0] * (jobs - 1)
given = [[] for _ in range(jobs)]
for s in sorted(suites, key=lambda s: (-seconds.get(s, 20.0), s)):
    j = min(range(jobs), key=lambda j: (load[j], j))
    load[j] += seconds.get(s, 20.0)
    given[j].append(s)
print("\n".join(given[index]))
print(f"shard {index}: about {load[index]:.0f} s of tests", file=sys.stderr)
