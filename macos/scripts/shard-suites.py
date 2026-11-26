#!/usr/bin/env python3
"""Splits the tests that run one at a time (page-suites.txt, timing-suites.txt) into N groups
of about equal time, for mac-build.yml's side-by-side jobs (Toni, 2026-11-26: "split the slow
step into parallel jobs, get it to 5 minutes").

Usage: shard-suites.py quiet
Prints the suites of quiet-suites.txt: tests of short time limits that job 0 runs alone, with
nothing else on the runner (2026-11-26: a 0.5 s limit measured 0.514 s beside another test
program). The groups below leave them out.

Usage: shard-suites.py <groups> <group index> [<seconds already in each of the first groups>
[<how many groups have them>]]
Prints the suites for that group, one per line. A group is one test program of one job (each
job runs two side by side); the first groups belong to job 0, which runs the unit tests first. Times come from suite-seconds.txt ("seconds
suite" per line, measured in CI; each run prints fresh ones as SUITE lines); a suite not
listed counts 20 s. Largest first into the emptiest job (always the same answer for the same
files, so every job agrees on the split).
"""
import pathlib
import re
import sys

# Suites longer than a group's share, split by test (each test an equal part of the suite's
# time): the suite's file holds only that suite, so its tests are its file's @Test functions.
split = {"SignInFillTests": "SignInFillTests.swift"}

here = pathlib.Path(__file__).parent
quiet = [l.strip() for l in (here / "quiet-suites.txt").read_text().split("\n") if l.strip()]
if sys.argv[1] == "quiet":
    print("\n".join(quiet))
    sys.exit(0)
jobs, index = int(sys.argv[1]), int(sys.argv[2])
head = float(sys.argv[3]) if len(sys.argv) > 3 else 0.0
headed = int(sys.argv[4]) if len(sys.argv) > 4 else 1
suites = []
for name in ("page-suites.txt", "timing-suites.txt"):
    for line in (here / name).read_text().split("\n"):
        if line.strip() and line.strip() not in suites and line.strip() not in quiet:
            suites.append(line.strip())
seconds = {}
known = here / "suite-seconds.txt"
if known.exists():
    for line in known.read_text().split("\n"):
        parts = line.split()
        if len(parts) == 2:
            seconds[parts[1]] = float(parts[0])
units = []
for s in suites:
    if s in split:
        text = (here.parent / "Tests" / split[s]).read_text()
        names = re.findall(r"@Test(?:\([^)]*\))?\s+func\s+(\w+)\(\)", text)
        for n in names:
            units.append(f"{s}/{n}()")
            seconds[f"{s}/{n}()"] = seconds.get(s, 20.0) / len(names)
    else:
        units.append(s)
suites = units
load = [head if j < headed else 0.0 for j in range(jobs)]
given = [[] for _ in range(jobs)]
for s in sorted(suites, key=lambda s: (-seconds.get(s, 20.0), s)):
    j = min(range(jobs), key=lambda j: (load[j], j))
    load[j] += seconds.get(s, 20.0)
    given[j].append(s)
print("\n".join(given[index]))
print(f"shard {index}: about {load[index]:.0f} s of tests", file=sys.stderr)
