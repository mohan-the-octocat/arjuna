#!/usr/bin/env python3
"""Checks every generated row against the BigQuery schema before loading.

Catches unknown fields, wrong types and bad TIMESTAMP strings locally, so a
`bq load` doesn't fail halfway. Usage: python3 check_schema.py [out_dir]
"""
import gzip
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "out")
TS = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?Z$")
TYPES = {"STRING": str, "INTEGER": int, "BOOLEAN": bool, "TIMESTAMP": str, "FLOAT": (int, float)}


def check(obj, fields, path, errors):
    by_name = {f["name"]: f for f in fields}
    for k, v in obj.items():
        f = by_name.get(k)
        p = f"{path}.{k}" if path else k
        if f is None:
            errors.add(f"unknown field {p}")
            continue
        items = v if f.get("mode") == "REPEATED" else [v]
        if f.get("mode") == "REPEATED" and not isinstance(v, list):
            errors.add(f"{p} should be a list")
            continue
        for it in items:
            if it is None:
                continue
            if f["type"] in ("RECORD", "STRUCT"):
                if not isinstance(it, dict):
                    errors.add(f"{p} should be an object")
                else:
                    check(it, f["fields"], p, errors)
            elif not isinstance(it, TYPES[f["type"]]):
                errors.add(f"{p} type {type(it).__name__} != {f['type']}")
            elif f["type"] == "TIMESTAMP" and not TS.match(it):
                errors.add(f"{p} bad timestamp {it!r}")


ok = True
for table in ("inference_request", "inference_response", "client_telemetry", "ground_truth"):
    schema = json.load(open(os.path.join(HERE, "schemas", f"{table}.json")))
    errors, n = set(), 0
    with gzip.open(os.path.join(OUT, f"{table}.jsonl.gz"), "rt", encoding="utf-8") as f:
        for line in f:
            check(json.loads(line), schema, "", errors)
            n += 1
    print(f"{table}: {n} rows, {'OK' if not errors else 'ERRORS'}")
    for e in sorted(errors)[:20]:
        print("   ", e)
    ok = ok and not errors
sys.exit(0 if ok else 1)
