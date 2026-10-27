#!/usr/bin/env python3
"""Rewrite a log in place without the entries listed in Scripts/known-errors.txt; print how many were left out.

Usage: filter-known-errors.py <log> <known-errors.txt>
An entry is a timestamped line plus the continuation lines after it.
"""
import re, sys

log, known = sys.argv[1], sys.argv[2]
allow = [l.strip() for l in open(known) if l.strip() and not l.startswith("#")]
entries = []
for line in open(log, errors="replace"):
    if re.match(r"\d{4}-\d\d-\d\d ", line) or not entries:
        entries.append(line)
    else:
        entries[-1] += line
kept = [e for e in entries if not any(a in e for a in allow)]
open(log, "w").write("".join(kept))
print(len(entries) - len(kept))
