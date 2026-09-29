#!/usr/bin/env python3
"""Checks generated files against the PRD metrics and the planted stories.

Computes, from out/*.jsonl.gz, the same derived metrics the Admin Analytics
PRD defines (expertise tiers with default bands, activity mix, autonomy
percentiles, rework by experience, client-version and model mix, background
overhead, retention of the pilot cohort, runaways, sensitive strings).

Usage: python3 check_distributions.py [out_dir]
"""
import collections
import datetime as dt
import gzip
import json
import os
import re
import statistics
import sys

OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")
SECRET = re.compile(r"AIza[0-9A-Za-z_\-]{35}|(?i:password\s*=)|\b[A-Z]{5}[0-9]{4}[A-Z]\b|\b\d{4} \d{4} \d{4}\b")


def rows(name):
    with gzip.open(os.path.join(OUT, f"{name}.jsonl.gz"), "rt", encoding="utf-8") as f:
        for line in f:
            yield json.loads(line)


def pct(xs, p):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(p * len(xs)))] if xs else None


def day(s):
    return dt.date.fromisoformat(s[:10])


summary = json.load(open(os.path.join(OUT, "summary.json")))
end = dt.date.fromisoformat(summary["window"][1])
win_start = end - dt.timedelta(days=29)

traj = collections.defaultdict(lambda: {"steps": set(), "turns": set(), "first": None, "user": None,
                                        "exp": None, "feat": set(), "approvals": 0})
aux = collections.Counter()
calls = collections.Counter()
ver_calls, ver_aux = collections.Counter(), collections.Counter()
week_model = collections.defaultdict(collections.Counter)
secret_rows = 0
user_days = collections.defaultdict(set)
for r in rows("inference_request"):
    lb = r["labels"]
    content = r["jsonpayload_v1_inferencerequestlog"]["input"]["messages"][0]["content"]
    if SECRET.search(content):
        secret_rows += 1
    ver_calls[lb["client_version"]] += 1
    tid = lb.get("trajectory_id")
    if not tid:
        aux[r["jsonpayload_v1_inferencerequestlog"]["experience"]] += 1
        ver_aux[lb["client_version"]] += 1
        continue
    t = traj[tid]
    t["steps"].add(lb["request_id"])
    t["user"] = lb["user_id"][5:]
    t["exp"] = r["jsonpayload_v1_inferencerequestlog"]["experience"]
    if t["first"] is None or r["timestamp"] < t["first"]:
        t["first"] = r["timestamp"]
    if "<USER_REQUEST>" in content:
        t["turns"].add(hash(content.split("</USER_REQUEST>")[0]))
        if "is a [Slash Command]" in content: t["feat"].add("slash")
        if "mentioned some items in the form @[ITEM]" in content: t["feat"].add("mention")
        if "<SKILL>" in content: t["feat"].add("skill")
        if "<SUBAGENT>" in content: t["feat"].add("subagent")
        m = re.search(r"Model Selection from (.+?) to ", content)
        if m and m.group(1) != "None": t["feat"].add("switch")
    user_days[lb["user_id"][5:]].add(r["timestamp"][:10])
    wk = day(r["timestamp"]).isocalendar()[1]
    week_model[wk][lb["model"]] += 1
    calls["traj"] += 1

tok_prompt, tok_breakdown_missing, tok_total_rows = [], 0, 0
for r in rows("inference_response"):
    md = r["jsonpayload_v1_inferenceresponselog"]["metadata"]
    tok_total_rows += 1
    if "prompttokencount" not in md:
        tok_breakdown_missing += 1
    elif r["labels"].get("trajectory_id"):
        tok_prompt.append(int(md["prompttokencount"]))

props = collections.defaultdict(collections.Counter)
resolved = set()
perm = collections.Counter()
for r in rows("client_telemetry"):
    p = r["jsonpayload_v1_clienttelemetrylog"]
    tid = r["labels"].get("trajectory_id")
    if p["eventtype"] == "InferenceResolved":
        resolved.add(tid)
    it = p["metadata"].get("interactiontype")
    if it == "PERMISSION_GRANT":
        perm[p["metadata"]["interactionoutcome"]] += 1
        if tid in traj: traj[tid]["approvals"] += 1
    elif it == "PROPOSAL_ACCEPTANCE":
        exp = traj[tid]["exp"] if tid in traj else "?"
        props[exp][p["metadata"]["interactionoutcome"]] += 1

# --- expertise tiers (PRD Section 1 defaults) -------------------------------
def band(v, cuts):
    return sum(v >= c for c in cuts)

per_user = collections.defaultdict(lambda: {"traj": 0, "days": set(), "spt": [], "feat": set()})
for tid, t in traj.items():
    if day(t["first"]) < win_start:
        continue
    u = per_user[t["user"]]
    u["traj"] += 1
    u["days"].add(t["first"][:10])
    if t["turns"]:
        u["spt"].append(len(t["steps"]) / len(t["turns"]))
    u["feat"] |= t["feat"]
tiers = collections.Counter()
for email, u in per_user.items():
    if u["traj"] < 3:
        tiers["Not enough data"] += 1
        continue
    score = band(len(u["days"]), [3, 6, 12]) + band(u["traj"] / (30 / 7), [1, 3, 10]) + \
        band(statistics.median(u["spt"]) if u["spt"] else 0, [3, 10, 30]) + band(len(u["feat"]), [1, 2, 3])
    tiers["Beginner" if score <= 3 else "Intermediate" if score <= 6 else "Advanced" if score <= 9 else "Expert"] += 1
    u["tier"] = "Beginner" if score <= 3 else "Intermediate" if score <= 6 else "Advanced" if score <= 9 else "Expert"

gt = list(rows("ground_truth"))
cat_mix = collections.Counter(g["category"] for g in gt if day(g["started_at"]) >= win_start)
steps = [len(t["steps"]) for t in traj.values()]
turns = [len(t["turns"]) for t in traj.values() if t["turns"]]
spt = [len(t["steps"]) / len(t["turns"]) for t in traj.values() if t["turns"]]
appr = [t["approvals"] for t in traj.values()]

roster = {}
import csv
with open(os.path.join(OUT, "roster.csv")) as f:
    for r in csv.DictReader(f):
        roster[r["email"]] = r
pilot = [e for e, r in roster.items() if r["cohort"] == "pilot"]
def active_in(e, a, b):
    return any(a <= dt.date.fromisoformat(d) <= b for d in user_days.get(e, ()))
jul = (dt.date(end.year, 7, 1), dt.date(end.year, 7, 31))
sep = (dt.date(end.year, 9, 1), end)

report = {
    "rows": summary["rows"],
    "trajectories": len(traj),
    "active_users_last_30d": len(per_user),
    "expertise_tiers_last_30d": dict(tiers),
    "archetype_to_tier": {a: dict(collections.Counter(per_user[e].get("tier", "Not enough data") for e, r in roster.items() if r["archetype"] == a and e in per_user)) for a in ["expert", "advanced", "intermediate", "beginner", "sparse"]},
    "activity_mix_last_30d": dict(cat_mix.most_common()),
    "autonomy": {
        "steps_per_trajectory": {"median": pct(steps, .5), "p90": pct(steps, .9), "max": max(steps)},
        "human_turns_per_trajectory": {"median": pct(turns, .5), "p90": pct(turns, .9), "max": max(turns)},
        "steps_per_human_turn": {"median": round(pct(spt, .5), 1), "p90": round(pct(spt, .9), 1)},
        "approvals_per_trajectory": {"mean": round(statistics.mean(appr), 2), "median": pct(appr, .5)},
    },
    "prompt_tokens_per_step_median": pct(tok_prompt, .5),
    "rows_without_token_breakdown": f"{tok_breakdown_missing / tok_total_rows:.1%}",
    "resolution_rate": f"{len(resolved & set(traj)) / len(traj):.1%}",
    "permission_reject_rate": f"{perm['REJECTED'] / max(1, sum(perm.values())):.1%}",
    "rework_by_experience": {e: f"{(c['MODIFIED'] + c['REJECTED']) / sum(c.values()):.0%} of {sum(c.values())}"
                             for e, c in sorted(props.items())},
    "aux_share_overall": f"{sum(aux.values()) / (sum(aux.values()) + calls['traj']):.1%}",
    "aux_share_by_version": {v: f"{ver_aux[v] / ver_calls[v]:.1%}" for v in sorted(ver_calls, key=lambda x: tuple(map(int, x.split('.'))))},
    "calls_by_version": dict(sorted(ver_calls.items(), key=lambda kv: tuple(map(int, kv[0].split('.'))))),
    "model_share_by_iso_week": {w: {m: f"{n / sum(c.values()):.0%}" for m, n in c.most_common()} for w, c in sorted(week_model.items())},
    "pilot_cohort": {"size": len(pilot), "active_in_july": sum(active_in(e, *jul) for e in pilot),
                     "active_in_sept": sum(active_in(e, *sep) for e in pilot)},
    "runaways": [{"steps": g["agent_steps"], "user": g["user_email"], "started": g["started_at"][:10]} for g in gt if g["runaway"]],
    "request_rows_with_secret_shapes": secret_rows,
    "high_tier_short_trajectories": sum(1 for t in traj.values() if t["exp"] and t["exp"].endswith("-high") and len(t["steps"]) <= 3),
}
print(json.dumps(report, indent=2))
