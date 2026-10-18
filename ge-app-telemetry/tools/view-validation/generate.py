#!/usr/bin/env python3
"""Synthetic Antigravity telemetry generator + independent ground truth.

Writes NDJSON files matching ge-app-telemetry/schemas/raw/*.json and a
ground_truth.json computed in Python (independently of the SQL views).

Edge cases deliberately included:
  * duplicate log rows (same insertId + timestamp, later receiveTimestamp)
  * sessions crossing UTC midnight
  * sessions using two models (argon + flash)
  * flash-lite background calls with NO trajectory id
  * missing user / client labels, missing token counts
  * permission accept/reject events WITHOUT a model label (as in live logs)
  * no events within +-3h of the 7-day / 90-day window boundaries
  * code citations on ~3% of responses (1-2 each), some with empty license and
    some without startIndex (protobuf omits 0), including on duplicate rows
"""
import json, os, random, sys, uuid
from collections import defaultdict
from datetime import datetime, timedelta, timezone

OUT = sys.argv[1] if len(sys.argv) > 1 else "."
SEED = 42
N_USERS = 20
N_DAYS = 30
rnd = random.Random(SEED)
crnd = random.Random(SEED + 1)   # separate stream for citations (keeps the rest of the data unchanged)
CITE_URLS = ["https://github.com/example/alpha", "https://github.com/example/beta", "https://gitlab.com/example/gamma"]
CITE_LICENSES = ["", "mit", "apache-2.0"]
NOW = datetime.now(timezone.utc).replace(microsecond=0)
END = NOW - timedelta(hours=1)                    # last event time
START = (END - timedelta(days=N_DAYS)).replace(hour=0, minute=0, second=0)
BOUNDARY_7 = NOW - timedelta(days=7)

USERS = [f"dev{i:02d}@synth.example.com" for i in range(1, N_USERS + 1)]
CLIENTS = ["antigravity_hub", "antigravity_cli"]
VERSIONS = {"antigravity_hub": ["2.0.1", "2.0.2"], "antigravity_cli": ["1.3.4", "1.3.5"]}
MAIN = [("gemini-4-argon", "gemini-4-argon-high"), ("gemini-3.8-flash", "gemini-3.8-flash-high")]
LITE = ("gemini-3.5-flash-lite", "gemini-3.5-flash-lite")
LOG = "projects/synth-project/logs/businessaicode.googleapis.com%2F{}"
RES = {"type": "businessaicode.googleapis.com/BAICInstance",
       "labels": {"location": "us-central1", "resource_container": "projects/123456789"}}

def ts(dt): return dt.strftime("%Y-%m-%d %H:%M:%S.%f UTC")
def near_boundary(dt): return abs((dt - BOUNDARY_7).total_seconds()) < 3 * 3600
def labels(user, client, version, model, traj, req):
    return {"user_id": None if user is None else f"user:{user}", "model": model, "client_name": client,
            "client_version": version, "trajectory_id": traj, "request_id": req}

resp, reqs, ct = [], [], []
truth_resp = []   # unique responses for ground truth
truth_ct = []     # unique client events

def add_response(dt, user, client, version, model, exp, traj, tokens):
    iid = uuid.uuid4().hex[:16]; req = traj or uuid.uuid4().hex[:12]
    lab = labels(user, client, version, model, traj, req)
    meta = None if tokens is None else {
        "totaltokencount": str(tokens[0]), "prompttokencount": str(tokens[1]), "candidatestokencount": str(tokens[2]),
        "thoughtstokencount": str(tokens[3]), "cachedcontenttokencount": str(tokens[4]), "quotatype": "REGULAR_QUOTA"}
    cits = None
    if crnd.random() < 0.03:
        cits = []
        for _ in range(crnd.randint(1, 2)):
            start = crnd.choice([0, crnd.randint(1, 2000)]); end = start + crnd.randint(50, 400)
            c = {"url": crnd.choice(CITE_URLS), "license": crnd.choice(CITE_LICENSES), "endindex": float(end)}
            if start: c["startindex"] = float(start)       # protobuf JSON omits zero values
            cits.append(c)
    output = {"candidates": [{"messages": [{"author": "MODEL", "content": "synthetic output"}]}]}
    if cits:
        output["attributioncontext"] = {"citationmetadata": {
            "_type": "type.googleapis.com/google.cloud.businessaicode.logging.v1.CitationMetadata", "citations": cits}}
    row = {"timestamp": ts(dt), "receiveTimestamp": ts(dt + timedelta(seconds=1)), "insertId": iid,
           "logName": LOG.format("inference_response"), "severity": "INFO", "resource": RES, "labels": lab,
           "jsonpayload_v1_inferenceresponselog": {"_type": "type.googleapis.com/google.cloud.businessaicode.logging.v1.InferenceResponseLog",
               "experience": exp, "metadata": meta, "output": output}}
    resp.append(row)
    truth_resp.append({"dt": dt, "user": user or "unknown", "client": client or "unspecified", "model": model,
                       "exp": exp, "traj": traj, "tokens": tokens, "cits": cits or []})
    reqs.append({"timestamp": ts(dt - timedelta(milliseconds=500)), "receiveTimestamp": ts(dt), "insertId": uuid.uuid4().hex[:16],
                 "logName": LOG.format("inference_request"), "severity": "INFO", "resource": RES, "labels": lab,
                 "jsonpayload_v1_inferencerequestlog": {"_type": "type.googleapis.com/google.cloud.businessaicode.logging.v1.InferenceRequestLog",
                     "experience": exp, "input": {"messages": [{"author": "USER", "content": "synthetic prompt"}]}}})
    if rnd.random() < 0.04:  # duplicate delivery of the same log entry
        dup = json.loads(json.dumps(row)); dup["receiveTimestamp"] = ts(dt + timedelta(seconds=3)); resp.append(dup)

def add_ct(dt, user, client, version, traj, etype, itype=None, outcome=None, model=None):
    lab = labels(user, client, version, model, traj, traj)
    row = {"timestamp": ts(dt), "receiveTimestamp": ts(dt + timedelta(seconds=1)), "insertId": uuid.uuid4().hex[:16],
           "logName": LOG.format("client_telemetry"), "severity": "INFO", "resource": RES, "labels": lab,
           "jsonpayload_v1_clienttelemetrylog": {"_type": "type.googleapis.com/google.cloud.businessaicode.logging.v1.ClientTelemetryLog",
               "eventtype": etype, "metadata": None if itype is None else {"interactiontype": itype, "interactionoutcome": outcome}}}
    ct.append(row)
    truth_ct.append({"dt": dt, "user": user or "unknown", "client": client or "unspecified", "model": model or "unspecified",
                     "etype": etype, "itype": itype, "outcome": outcome})
    if rnd.random() < 0.04:
        dup = json.loads(json.dumps(row)); dup["receiveTimestamp"] = ts(dt + timedelta(seconds=3)); ct.append(dup)

def tokens_for(model):
    if rnd.random() < 0.03: return None                       # missing token counts
    if "lite" in model: p = rnd.randint(80, 900)
    elif "argon" in model: p = rnd.randint(15000, 60000)
    else: p = rnd.randint(5000, 30000)
    c, t = rnd.randint(50, 800), rnd.randint(0, 2500); cached = rnd.randint(0, p // 2)
    return (p + c + t, p, c, t, cached)

day = START
while day.date() <= END.date():
    for ui, user in enumerate(USERS):
        if rnd.random() < (0.35 if ui >= 15 else 0.75):       # some users less active
            continue
        client = CLIENTS[ui % 2] if rnd.random() < 0.85 else CLIENTS[(ui + 1) % 2]
        for _ in range(rnd.randint(1, 3)):                     # sessions per day
            start = day + timedelta(hours=rnd.choice([9, 10, 11, 14, 15, 16, 23]), minutes=rnd.randint(0, 50))
            traj = uuid.uuid4().hex[:24]
            label_user = None if rnd.random() < 0.01 else user   # rare missing user label
            label_client = None if rnd.random() < 0.01 else client
            version = rnd.choice(VERSIONS[client])
            t = start
            for step in range(rnd.randint(2, 7)):
                t += timedelta(minutes=rnd.randint(3, 25))         # may cross midnight for 23:xx starts
                if t > END or near_boundary(t): break
                model, exp = MAIN[0] if rnd.random() < 0.6 else MAIN[1]    # sessions can mix models
                add_response(t, label_user, label_client, version, model, exp, traj, tokens_for(model))
                add_ct(t, label_user, label_client, version, traj, "InferenceResolved", model=model)
                if rnd.random() < 0.25:                            # permission prompt (no model label)
                    add_ct(t + timedelta(seconds=5), label_user, label_client, version, traj, "InferenceInteraction",
                           "PERMISSION_GRANT", "ACCEPTED" if rnd.random() < 0.8 else "REJECTED")
                if rnd.random() < 0.7:                             # background flash-lite call, no trajectory
                    bt = t + timedelta(seconds=2)
                    if not near_boundary(bt) and bt <= END:
                        add_response(bt, label_user, label_client, version, LITE[0], LITE[1], None, tokens_for(LITE[0]))
    day += timedelta(days=1)

# ---------------------------------------------------------------- ground truth
def d(x): return x["dt"].strftime("%Y-%m-%d")
gt = {"generated_at": NOW.isoformat(), "daily": {}, "daily_sessions": {}, "windows": {}, "tokens_by_model": {}, "permissions": {}}
by_day = defaultdict(lambda: {"inf": 0, "users": set(), "sess": set()})
cube = defaultdict(lambda: {"sess": set(), "users": set(), "inf": 0})
for r in truth_resp:
    k = d(r); by_day[k]["inf"] += 1; by_day[k]["users"].add(r["user"])
    if r["traj"]: by_day[k]["sess"].add(r["traj"])
    for u in (r["user"], "(all)"):
        for c in (r["client"], "(all)"):
            for m in (r["model"], "(all)"):
                e = cube[f"{k}|{u}|{c}|{m}"]; e["inf"] += 1; e["users"].add(r["user"])
                if r["traj"]: e["sess"].add(r["traj"])
gt["daily"] = {k: {"inferences": v["inf"], "active_users": len(v["users"]), "sessions": len(v["sess"])} for k, v in sorted(by_day.items())}
gt["daily_sessions"] = {k: {"sessions": len(v["sess"]), "active_users": len(v["users"]), "inferences": v["inf"]} for k, v in cube.items()}

def window_stats(rows, keyfn):
    out = defaultdict(lambda: {"inf": 0, "sess": set(), "days": set(), "users": set(), "tok": 0, "ptok": 0})
    for r in rows:
        for k in (keyfn(r), "__all__"):
            e = out[k]; e["inf"] += 1; e["days"].add(d(r)); e["users"].add(r["user"])
            if r["traj"]: e["sess"].add(r["traj"])
            if r["tokens"]: e["tok"] += r["tokens"][0]; e["ptok"] += r["tokens"][1]
    return {k: {"inferences": v["inf"], "trajectories": len(v["sess"]), "active_days": len(v["days"]),
                "active_users": len(v["users"]), "total_tokens": v["tok"], "prompt_tokens": v["ptok"]} for k, v in out.items()}
for w in (7, 90):
    cut = NOW - timedelta(days=w)
    rows = [r for r in truth_resp if r["dt"] >= cut]
    cts = [c for c in truth_ct if c["dt"] >= cut and c["itype"] == "PERMISSION_GRANT"]
    users = window_stats(rows, lambda r: r["user"])
    for u, v in users.items():
        cu = [c for c in cts if u == "__all__" or c["user"] == u]
        v["permission_requests_total"] = len(cu)
        v["permission_grants_accepted"] = sum(c["outcome"] == "ACCEPTED" for c in cu)
        v["permission_grants_rejected"] = sum(c["outcome"] == "REJECTED" for c in cu)
    gt["windows"][str(w)] = {"users": users, "models": window_stats(rows, lambda r: r["model"])}
tbm = defaultdict(lambda: [0, 0, 0, 0, 0, 0])
for r in truth_resp:
    e = tbm[r["model"]]; e[5] += 1
    if r["tokens"]:
        for i in range(5): e[i] += r["tokens"][i]
gt["tokens_by_model"] = {m: dict(zip(["total", "prompt", "candidates", "thoughts", "cached", "inferences"], v)) for m, v in tbm.items()}
perm = [c for c in truth_ct if c["itype"] == "PERMISSION_GRANT"]
gt["permissions"] = {"requests": len(perm), "accepted": sum(c["outcome"] == "ACCEPTED" for c in perm),
                     "rejected": sum(c["outcome"] == "REJECTED" for c in perm),
                     "resolved_events": sum(c["etype"] == "InferenceResolved" for c in truth_ct),
                     "client_events": len(truth_ct)}
cits = [c for r in truth_resp for c in r["cits"]]
by_url, by_lic = defaultdict(int), defaultdict(int)
for c in cits:
    by_url[c["url"]] += 1; by_lic[c["license"] or "unknown"] += 1
gt["citations"] = {"total": len(cits), "by_url": dict(by_url), "by_license": dict(by_lic),
                   "matched_chars": int(sum(c["endindex"] - c.get("startindex", 0) for c in cits)),
                   "responses": sum(1 for r in truth_resp if r["cits"])}

os.makedirs(OUT, exist_ok=True)
for name, rows in (("inference_response", resp), ("inference_request", reqs), ("client_telemetry", ct)):
    with open(os.path.join(OUT, f"{name}.ndjson"), "w") as f:
        for r in rows: f.write(json.dumps(r) + "\n")
with open(os.path.join(OUT, "ground_truth.json"), "w") as f:
    json.dump(gt, f, indent=1, default=list)
print(json.dumps({"responses_rows": len(resp), "responses_unique": len(truth_resp), "requests": len(reqs),
                  "client_rows": len(ct), "client_unique": len(truth_ct), "days": len(gt["daily"]),
                  "citations": gt["citations"]["total"],
                  "range": [START.isoformat(), END.isoformat()]}))
