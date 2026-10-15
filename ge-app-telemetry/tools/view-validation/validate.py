#!/usr/bin/env python3
"""Compare the views in a (synthetic) views dataset against generate.py's ground truth.

Usage: validate.py <ground_truth.json> <PROJECT_ID> [VIEWS_DATASET=ge_app_agy_telemetry_synth]
Exit code 0 if all checks pass, 1 otherwise.
"""
import json, subprocess, sys
from collections import defaultdict

if len(sys.argv) < 3:
    sys.exit(__doc__)
P = sys.argv[2]
V = f"{P}.{sys.argv[3] if len(sys.argv) > 3 else 'ge_app_agy_telemetry_synth'}"
GT = json.load(open(sys.argv[1]))
results = []

def q(sql):
    out = subprocess.run(["bq", "query", f"--project_id={P}", "--use_legacy_sql=false", "--format=json",
                          "--max_rows=1000000", "--quiet", sql], capture_output=True, text=True, check=True).stdout
    return json.loads(out or "[]")

def n(v): return 0 if v in (None, "") else int(float(v))

def check(name, expected, actual):
    ok = expected == actual
    results.append((name, ok, "" if ok else f"expected={expected} actual={actual}"))

# 1. daily_sessions: every CUBE row, exact
rows = q(f"SELECT CAST(event_date AS STRING) d, user_email u, client_name c, model m, sessions, active_users, inferences FROM `{V}.v_ge_app_agy_daily_sessions`")
view = {f"{r['d']}|{r['u']}|{r['c']}|{r['m']}": r for r in rows}
gt = GT["daily_sessions"]
check("daily_sessions: same set of rows", sorted(gt.keys()) == sorted(view.keys()), True)
bad = [k for k, e in gt.items() if k in view and (n(view[k]["sessions"]), n(view[k]["active_users"]), n(view[k]["inferences"])) != (e["sessions"], e["active_users"], e["inferences"])]
check(f"daily_sessions: sessions/users/inferences exact on {len(gt)} rows", 0, len(bad))
if bad: print("  sample mismatch:", bad[:3], [view.get(k) for k in bad[:3]], [gt[k] for k in bad[:3]])

# 2. adoption: daily inferences + DAU
rows = q(f"SELECT CAST(event_date AS STRING) d, user_email, total_inferences FROM `{V}.v_ge_app_agy_adoption`")
inf, users = defaultdict(int), defaultdict(set)
for r in rows: inf[r["d"]] += n(r["total_inferences"]); users[r["d"]].add(r["user_email"])
check("adoption: daily inferences (all days)", {k: v["inferences"] for k, v in GT["daily"].items()}, dict(inf))
check("adoption: daily active users (all days)", {k: v["active_users"] for k, v in GT["daily"].items()}, {k: len(v) for k, v in users.items()})

# 3. token_economics: tokens by model
rows = q(f"SELECT model, SUM(total_inferences) i, SUM(total_tokens) t, SUM(prompt_tokens) p, SUM(candidates_tokens) c, SUM(thoughts_tokens) th, SUM(cached_content_tokens) ca FROM `{V}.v_ge_app_agy_token_economics` GROUP BY model")
act = {r["model"]: {"inferences": n(r["i"]), "total": n(r["t"]), "prompt": n(r["p"]), "candidates": n(r["c"]), "thoughts": n(r["th"]), "cached": n(r["ca"])} for r in rows}
check("token_economics: tokens by type & inferences per model", GT["tokens_by_model"], act)

# 4. trust_quality: permissions + events
r = q(f"SELECT SUM(permission_requests_total) req, SUM(permission_grants_accepted) acc, SUM(permission_grants_rejected) rej, SUM(inference_resolved_events) res, SUM(total_events) ev FROM `{V}.v_ge_app_agy_trust_quality`")[0]
check("trust_quality: permissions & events", GT["permissions"], {"requests": n(r["req"]), "accepted": n(r["acc"]), "rejected": n(r["rej"]), "resolved_events": n(r["res"]), "client_events": n(r["ev"])})

# 5. user_summary (7d / 90d, every user + all_users)
rows = q(f"SELECT * FROM `{V}.v_ge_app_agy_user_summary`")
keys = ["inferences", "trajectories", "active_days", "active_users", "total_tokens", "prompt_tokens",
        "permission_requests_total", "permission_grants_accepted", "permission_grants_rejected"]
for w in ("7", "90"):
    exp = GT["windows"][w]["users"]
    act = {("__all__" if r["scope"] == "all_users" else r["user_email"]): {k: n(r[k]) for k in keys} for r in rows if r["window_days"] == w}
    check(f"user_summary {w}d: all users + all_users row, {len(exp)} rows x {len(keys)} metrics", exp, act)
    share = sum(float(r["token_share"] or 0) for r in rows if r["window_days"] == w and r["scope"] == "user")
    check(f"user_summary {w}d: token_share sums to ~1", True, abs(share - 1) < 0.001 * len(exp))

# 6. model_summary (7d / 90d)
rows = q(f"SELECT * FROM `{V}.v_ge_app_agy_model_summary`")
mkeys = ["inferences", "trajectories", "active_days", "active_users", "total_tokens", "prompt_tokens"]
for w in ("7", "90"):
    exp = GT["windows"][w]["models"]
    act = {("__all__" if r["scope"] == "all_models" else r["model"]): {k: n(r[k]) for k in mkeys} for r in rows if r["window_days"] == w}
    check(f"model_summary {w}d: all models + all_models row", exp, act)

w = max(len(x[0]) for x in results)
for name, ok, detail in results:
    print(f"{'PASS' if ok else 'FAIL'}  {name.ljust(w)}  {detail[:300]}")
passed = sum(ok for _, ok, _ in results)
print(f"\n{passed}/{len(results)} checks passed")
sys.exit(0 if passed == len(results) else 1)
