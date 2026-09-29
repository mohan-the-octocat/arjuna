#!/usr/bin/env python3
"""Validates a prompt library JSONL file against prompts/BRIEF.md.

Usage: python3 validate_prompts.py <category_key>.jsonl [--expect N]
Prints OK or a list of problems (exit code 1).
"""
import json
import os
import re
import sys

CATEGORIES = {
    "build_feature": "Build a feature",
    "debug_fix": "Debug and fix",
    "refactor_migrate": "Refactor and migrate",
    "understand_code": "Understand code",
    "test_verify": "Test and verify",
    "ui_frontend": "UI and front-end",
    "devops_infra": "DevOps, cloud and infra",
    "data_analysis": "Data and analysis",
    "research_docs": "Research and docs",
    "other": "Other",
}
ROLES = {"swe_backend", "swe_frontend", "swe_mobile", "swe_platform", "qa",
         "sre", "pm", "ux", "data", "em", "other"}
LENGTHS = {"short": (1, 79), "medium": (80, 400), "long": (401, 1600)}
FORBIDDEN = [
    (re.compile(r"</?(USER_REQUEST|ADDITIONAL_METADATA|SKILL|SUBAGENT|"
                r"USER_SETTINGS_CHANGE|SYSTEM_MESSAGE)>", re.I), "wrapper tag"),
    (re.compile(r"AIza[0-9A-Za-z_\-]{20,}"), "API-key shape"),
    (re.compile(r"(?i)\b(password|passwd|secret|token)\s*[=:]\s*\S{6,}"),
     "credential assignment"),
    (re.compile(r"\b[A-Z]{5}[0-9]{4}[A-Z]\b"), "PAN shape"),
    (re.compile(r"\b\d{4}\s?\d{4}\s?\d{4}\b"), "Aadhaar shape"),
    (re.compile(r"(?m)^\s*/[a-z][a-z\-]+\b(?!/)"), "slash command"),
]


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        sys.exit(2)
    path = args[0]
    expect = int(args[args.index("--expect") + 1]) if "--expect" in args else 150
    key = os.path.basename(path).removesuffix(".jsonl")
    problems = []
    if key not in CATEGORIES:
        problems.append(f"file name {key!r} is not a category key")
    ids, texts = set(), set()
    lengths = {"short": 0, "medium": 0, "long": 0}
    followup_counts = {0: 0, 1: 0, 2: 0}
    n = 0
    with open(path, encoding="utf-8") as f:
        for lineno, line in enumerate(f, 1):
            if not line.strip():
                continue
            n += 1
            try:
                r = json.loads(line)
            except json.JSONDecodeError as e:
                problems.append(f"line {lineno}: bad JSON ({e})")
                continue
            rid = r.get("id", "")
            if not re.fullmatch(rf"{re.escape(key)}-\d{{3}}", rid):
                problems.append(f"line {lineno}: bad id {rid!r}")
            if rid in ids:
                problems.append(f"line {lineno}: duplicate id {rid}")
            ids.add(rid)
            if r.get("category") != CATEGORIES.get(key):
                problems.append(f"{rid}: category {r.get('category')!r}")
            roles = r.get("roles", [])
            if not roles or len(roles) > 4 or not set(roles) <= ROLES:
                problems.append(f"{rid}: bad roles {roles}")
            text = r.get("text", "")
            ln = r.get("length")
            if ln not in LENGTHS:
                problems.append(f"{rid}: bad length {ln!r}")
            else:
                lo, hi = LENGTHS[ln]
                if not lo <= len(text) <= hi:
                    problems.append(
                        f"{rid}: length {ln} but text is {len(text)} chars")
                lengths[ln] += 1
            norm = re.sub(r"\W+", " ", text.lower()).strip()
            if norm in texts:
                problems.append(f"{rid}: duplicate text")
            texts.add(norm)
            fups = r.get("followups", [])
            if not isinstance(fups, list) or len(fups) > 3 or not all(
                    isinstance(x, str) and x.strip() for x in fups):
                problems.append(f"{rid}: bad followups")
            else:
                followup_counts[min(len(fups), 2)] += 1
            for s in [text] + (fups if isinstance(fups, list) else []):
                for rx, what in FORBIDDEN:
                    if rx.search(s or ""):
                        problems.append(f"{rid}: contains {what}")
    if n != expect:
        problems.append(f"expected {expect} records, found {n}")
    if n and key != "other":
        def share(c):
            return c / n
        if not 0.2 <= share(lengths["short"]) <= 0.4:
            problems.append(f"short share {share(lengths['short']):.0%} (want ~30%)")
        if not 0.4 <= share(lengths["medium"]) <= 0.6:
            problems.append(f"medium share {share(lengths['medium']):.0%} (want ~50%)")
        if not 0.12 <= share(lengths["long"]) <= 0.3:
            problems.append(f"long share {share(lengths['long']):.0%} (want ~20%)")
        if not 0.3 <= share(followup_counts[0]) <= 0.5:
            problems.append(f"0-followup share {share(followup_counts[0]):.0%} (want ~40%)")
        if share(followup_counts[2]) < 0.12:
            problems.append(f"2-3-followup share {share(followup_counts[2]):.0%} (want ~20%)")
    if problems:
        print("\n".join(problems[:60]))
        if len(problems) > 60:
            print(f"... and {len(problems) - 60} more")
        sys.exit(1)
    print(f"OK ({n} records; lengths {lengths}; followups {followup_counts})")


if __name__ == "__main__":
    main()
