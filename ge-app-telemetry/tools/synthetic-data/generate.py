#!/usr/bin/env python3
"""Generates synthetic Antigravity (GE businessaicode) telemetry.

Writes sink-shaped NEWLINE_DELIMITED_JSON (gzip) for the three tables the
ge-app-telemetry log sink creates, plus a roster and a ground-truth file:

  out/inference_request.jsonl.gz
  out/inference_response.jsonl.gz
  out/client_telemetry.jsonl.gz
  out/ground_truth.jsonl.gz     -> table _synth_ground_truth (not read by views)
  out/roster.csv                -> human-readable org roster
  out/summary.json              -> counts and distribution checks

Row shapes follow the reference deployment (stratosphere-461622): one
request row per model call carrying only the latest turn (re-logged on
every agent step), one response row per call with STRING token counts, and
client_telemetry events for approvals, proposals and resolutions. Auxiliary
calls have no trajectory_id.

Usage:
  python3 generate.py --users 200 --days 90 --end-date 2026-09-29 --seed 42
"""
import argparse
import csv
import datetime as dt
import gzip
import json
import math
import os
import random
import string
import sys
import uuid

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
UTC = dt.timezone.utc
CATEGORY_NAMES = {
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
CODE_CATEGORIES = {"build_feature", "debug_fix", "refactor_migrate",
                   "test_verify", "ui_frontend", "devops_infra",
                   "data_analysis"}
ARCHETYPES = ["expert", "advanced", "intermediate", "beginner", "sparse"]

FIRST_NAMES_IN = """Aarav Aditi Akash Ananya Arjun Bhavna Chetan Deepa Dev Divya
Gaurav Harini Ishaan Janani Karthik Kavya Lakshmi Manish Meera Mohit Nandini
Naveen Neha Nikhil Pooja Pranav Priya Rahul Ramya Rohan Sahana Sanjay Shreya
Siddharth Sneha Srinivas Swati Tanvi Tarun Uma Varun Vidya Vikram Vivek Yash
Zoya Abhishek Anjali Farhan Gayatri Hemant Irfan Jyoti Kiran Lavanya Madhav
Nisha Omkar Pallavi Raghav Ritika Sameer Shalini Suresh Tejas Usha Vandana
Aditya Asha Harsh Keerthi Mansi Prakash Rekha Sunil""".split()
LAST_NAMES_IN = """Sharma Iyer Reddy Nair Rao Menon Gupta Patel Krishnan Joshi
Kulkarni Desai Pillai Bhat Hegde Shetty Agarwal Verma Mehta Chatterjee Das
Banerjee Mukherjee Kapoor Malhotra Srinivasan Subramanian Ramesh Naidu
Chowdhury Khan Sinha Mishra Pandey Tiwari Saxena Bose Ghosh Jain Kamath
Venkatesh Mathew Varghese Thomas Fernandes""".split()
FIRST_NAMES_US = """Emily Jacob Olivia Ethan Sophia Noah Ava Liam Mia Lucas
Grace Owen Chloe Ryan Hannah Nathan Zoe Caleb Leah Daniel Maya Adrian Nora
Marcus Elena Tyler Priyanka Kevin Julia Sean""".split()
LAST_NAMES_US = """Johnson Miller Davis Garcia Wilson Anderson Taylor Thomas
Moore Martin Lee Clark Lewis Walker Young Allen King Wright Scott Hill Green
Baker Nelson Carter Mitchell Roberts Turner Phillips Campbell Parker""".split()

REPOS = {
    "swe_backend": ["checkout-service", "payments-gateway", "catalog-api"],
    "swe_frontend": ["storefront-web", "merchant-portal"],
    "swe_mobile": ["cymbal-android", "cymbal-ios"],
    "swe_platform": ["infra", "platform-tools"],
    "sre": ["infra", "runbooks"],
    "qa": ["e2e-tests", "storefront-web", "checkout-service"],
    "data": ["data-platform"],
    "pm": ["product-docs"], "ux": ["storefront-web", "design-system"],
    "em": ["checkout-service", "product-docs"], "other": ["docs-site"],
}
FILES = {
    "checkout-service": ["src/main/java/com/cymbal/checkout/controller/OrderController.java", "src/main/java/com/cymbal/checkout/service/CartPricingService.java", "pom.xml"],
    "payments-gateway": ["internal/refund/refund_handler.go", "internal/upi/upi_adapter.go", "cmd/server/main.go"],
    "catalog-api": ["search/ranker.py", "models/product.py", "api/routes.py"],
    "storefront-web": ["components/ProductCard.tsx", "app/checkout/page.tsx", "tailwind.config.ts"],
    "merchant-portal": ["src/app/settlements/settlements.component.ts", "angular.json"],
    "cymbal-android": ["app/src/main/java/com/cymbal/cart/CartViewModel.kt", "app/build.gradle.kts"],
    "cymbal-ios": ["Cymbal/Checkout/CheckoutView.swift", "Cymbal.xcodeproj/project.pbxproj"],
    "infra": ["terraform/modules/gke/main.tf", "charts/checkout/values.yaml", "cloudbuild.yaml"],
    "platform-tools": ["cmd/cymctl/main.go", "Makefile"],
    "runbooks": ["payments-gateway/oncall.md", "slo/checkout.md"],
    "e2e-tests": ["e2e/checkout.spec.ts", "load/k6_checkout.js"],
    "data-platform": ["dbt/models/marts/fct_orders.sql", "dags/daily_settlement.py"],
    "product-docs": ["prd/upi-intent.md", "roadmap/q4.md"],
    "design-system": ["tokens/colors.json", "components/Button.tsx"],
    "docs-site": ["docs/api/payments.md", "docs/security/pci.md"],
}
LANG = {".java": "java", ".go": "go", ".py": "python", ".tsx": "typescriptreact",
        ".ts": "typescript", ".kt": "kotlin", ".swift": "swift", ".tf": "terraform",
        ".yaml": "yaml", ".md": "markdown", ".sql": "sql", ".js": "javascript",
        ".json": "json", ".xml": "xml", ".kts": "kotlin"}
SLASH = ["/goal", "/plan", "/browser", "/grill-me", "/schedule"]
SKILLS = ["cymbal-code-review", "spring-boot-upgrade", "terraform-module",
          "playwright-e2e", "bq-cost-guard", "release-notes"]
SUBAGENTS = ["browser", "research", "test-runner"]
TIER_LABEL = {"high": "High", "medium": "Medium", "low": "Low"}
SYSTEM_TURNS = [
    ("USER", "Error: The stream was interrupted. Please continue from where you left off."),
    ("USER", "Error: model output error: model output must contain either output text or tool calls, these cannot both be empty"),
    ("USER", "<SYSTEM_MESSAGE>\nTask notification: background command finished with exit code 0.\n</SYSTEM_MESSAGE>"),
    ("MODEL", "Got task notification. Continuing."),
    ("MODEL", "I am waiting for the build to finish before checking the result."),
]
THOUGHTS = {
    "build_feature": ["Planning the new endpoint", "Scaffolding the module", "Wiring the handler", "Adding the data model"],
    "debug_fix": ["Reproducing the failure", "Tracing the null value", "Inspecting the stack trace", "Checking the failing assertion"],
    "refactor_migrate": ["Mapping current dependencies", "Updating imports", "Extracting the interface", "Checking deprecated APIs"],
    "understand_code": ["Reading the call path", "Summarizing the module", "Locating the configuration", "Following the request flow"],
    "test_verify": ["Listing test scenarios", "Writing the test cases", "Running the suite", "Checking coverage gaps"],
    "ui_frontend": ["Laying out the component", "Applying design tokens", "Adjusting responsive breakpoints", "Checking accessibility labels"],
    "devops_infra": ["Reviewing the Terraform plan", "Updating the pipeline", "Checking IAM bindings", "Tuning the autoscaler"],
    "data_analysis": ["Drafting the SQL", "Checking the partition filter", "Validating row counts", "Building the aggregation"],
    "research_docs": ["Outlining the document", "Gathering references", "Drafting the summary", "Structuring the sections"],
    "other": ["Clarifying the request", "Considering the question"],
}
REPLIES = [
    "I've made the change and verified it builds.",
    "Done. Summary of what changed is below.",
    "Here's what I found.",
    "I've updated the files and run the tests; all pass.",
    "The root cause is identified; the fix is applied.",
    "Draft is ready for your review.",
]
TERMINAL_CMDS = ["./gradlew test", "npm run build", "go test ./...", "pytest -q",
                 "terraform plan", "kubectl rollout status deploy/checkout",
                 "dbt run --select fct_orders", "mvn -q verify", "npx playwright test"]


# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

def lognormal(rng, median, sigma):
    return median * math.exp(rng.gauss(0.0, sigma))


def poisson(rng, lam):
    # Knuth; lam is small here.
    l, k, p = math.exp(-lam), 0, 1.0
    while True:
        p *= rng.random()
        if p <= l:
            return k
        k += 1


def weighted(rng, weights):
    keys = list(weights)
    return rng.choices(keys, weights=[weights[k] for k in keys])[0]


def alloc(total, shares):
    """Largest-remainder allocation of an integer total by shares."""
    raw = [total * s for s in shares]
    base = [int(x) for x in raw]
    rem = total - sum(base)
    order = sorted(range(len(raw)), key=lambda i: raw[i] - base[i], reverse=True)
    for i in order[:rem]:
        base[i] += 1
    return base


def ts(t):
    return t.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def vkey(v):
    return tuple(int(x) for x in v.split("."))


class Ids:
    def __init__(self, rng):
        self.rng = rng
        self.seen = set()

    def insert_id(self):
        while True:
            s = "".join(self.rng.choices(string.ascii_lowercase + string.digits,
                                         k=self.rng.choice([11, 12, 13])))
            if s not in self.seen:
                self.seen.add(s)
                return s

    def uuid(self):
        return str(uuid.UUID(int=self.rng.getrandbits(128), version=4))


# ----------------------------------------------------------------------------
# Org roster
# ----------------------------------------------------------------------------

def build_roster(cfg, n_users, start, days, rng):
    roles = cfg["roles"]
    base_total = sum(r["count"] for r in roles.values())
    counts = dict(zip(roles, alloc(n_users, [r["count"] / base_total for r in roles.values()])))
    users, emails = [], set()
    ro = cfg["rollout"]
    for role, n in counts.items():
        rc = roles[role]
        tier_counts = alloc(n, rc["tiers"])
        archs = [a for a, c in zip(ARCHETYPES, tier_counts) for _ in range(c)]
        rng.shuffle(archs)
        for arch in archs:
            tz = "PT" if rng.random() < cfg["pt_share"] else "IST"
            fn, ln = (rng.choice(FIRST_NAMES_US), rng.choice(LAST_NAMES_US)) if tz == "PT" and rng.random() < 0.6 \
                else (rng.choice(FIRST_NAMES_IN), rng.choice(LAST_NAMES_IN))
            local = f"{fn}.{ln}".lower()
            email, i = f"{local}@{cfg['company']['domain']}", 2
            while email in emails:
                email, i = f"{local}{i}@{cfg['company']['domain']}", i + 1
            emails.add(email)
            projects = rc["projects"]
            home = weighted(rng, projects)
            second = None
            if len(projects) > 1 and rng.random() < 0.25:
                second = rng.choice([p for p in projects if p != home])
            users.append({
                "email": email, "name": f"{fn} {ln}", "role": role,
                "title": rc["title"], "archetype": arch, "tz": tz,
                "home_project": home, "second_project": second,
            })
    # Tier preference, upgrade lag, deprecated-model users, features.
    lag_cfg = cfg["upgrade_lag"]
    for u in users:
        u["tier_pref"] = weighted(rng, cfg["models"]["tier_pref"])
        r = rng.random()
        if r < lag_cfg["fast"]["share"]:
            u["lag_kind"], u["lag_days"] = "fast", rng.randint(*lag_cfg["fast"]["days"])
        elif r < lag_cfg["fast"]["share"] + lag_cfg["normal"]["share"]:
            u["lag_kind"], u["lag_days"] = "normal", rng.randint(*lag_cfg["normal"]["days"])
        else:
            u["lag_kind"], u["lag_days"] = "laggard", 0
        u["features"] = pick_features(cfg["archetypes"][u["archetype"]]["features"], rng)
        u["deprecated"] = False
    # Deprecated model: laggards first, non-experts.
    n_dep = max(1, round(len(users) * cfg["models"]["deprecated_user_share"]))
    cands = sorted(users, key=lambda u: (u["lag_kind"] != "laggard", u["archetype"] == "expert", rng.random()))
    for u in cands[:n_dep]:
        u["deprecated"] = True
    # Rollout: pilot, main rollout, late joiners; churn.
    pilot_n = round(len(users) * ro["pilot_share"])
    pilot_pool = sorted(
        [u for u in users if u["role"] in ro["pilot_roles"]],
        key=lambda u: (ARCHETYPES.index(u["archetype"]) > 2, rng.random()))
    pilot = set(id(u) for u in pilot_pool[:pilot_n])
    rest = [u for u in users if id(u) not in pilot]
    rng.shuffle(rest)
    late_n = round(len(rest) * ro["late_joiner_share"])
    for u in users:
        u["churn_date"] = None
        if id(u) in pilot:
            u["cohort"] = "pilot"
            u["onboard"] = start + dt.timedelta(days=rng.randint(0, 9))
        elif u in rest[:late_n]:
            u["cohort"] = "late"
            u["onboard"] = start + dt.timedelta(days=rng.randint(max(0, days - 30), days - 4))
        else:
            u["cohort"] = "rollout"
            off = ro["rollout_start_offset"] + int(abs(rng.gauss(0, ro["rollout_span_days"] / 2.2)))
            off = min(off, ro["rollout_start_offset"] + ro["rollout_span_days"])
            u["onboard"] = start + dt.timedelta(days=min(off, days - 1))
    pilots = [u for u in users if u["cohort"] == "pilot"]
    churners = sorted(pilots, key=lambda u: (u["archetype"] in ("expert", "advanced"), rng.random()))
    for u in churners[:round(len(pilots) * ro["pilot_churn_share"])]:
        u["churn_date"] = start + dt.timedelta(days=rng.randint(24, 50))
    rollouts = [u for u in users if u["cohort"] == "rollout" and u["archetype"] in ("beginner", "intermediate")]
    rng.shuffle(rollouts)
    for u in rollouts[:round(len([x for x in users if x["cohort"] == "rollout"]) * ro["rollout_churn_share"])]:
        u["churn_date"] = u["onboard"] + dt.timedelta(days=rng.randint(12, 30))
    # Laggards stay on the version they had at onboarding (or mid-July).
    for u in users:
        u["client_cap"] = None
        if u["lag_kind"] == "laggard":
            anchor = max(u["onboard"], start + dt.timedelta(days=14))
            u["client_cap"] = latest_release(cfg, anchor, 0, None)["version"]
    return users


def pick_features(spec, rng):
    feats = set()
    for f in spec:
        if f == "slash_or_skill":
            feats.add(rng.choice(["slash", "skill"]))
        elif f.startswith("mention_"):
            if rng.random() < int(f.split("_")[1]) / 100:
                feats.add("mention")
        elif rng.random() < 0.92:
            feats.add(f)
    return feats


def latest_release(cfg, day, lag_days, cap):
    best = cfg["client_releases"][0]
    for r in cfg["client_releases"]:
        rd = dt.date.fromisoformat(r["date"]) + dt.timedelta(days=lag_days)
        if rd <= day and (cap is None or vkey(r["version"]) <= vkey(cap)):
            best = r
    return best


# ----------------------------------------------------------------------------
# Prompt library
# ----------------------------------------------------------------------------

def load_prompts():
    lib = {}
    pdir = os.path.join(HERE, "prompts")
    for key in CATEGORY_NAMES:
        with open(os.path.join(pdir, f"{key}.jsonl"), encoding="utf-8") as f:
            lib[key] = [json.loads(l) for l in f if l.strip()]
    return lib


def vary(text, rng):
    """Light surface variation so repeated prompts are not byte-identical."""
    r = rng.random()
    if r < 0.12:
        text = rng.choice(["pls ", "hey, ", "can you ", "quick one: ", "ok so "]) + text[:1].lower() + text[1:]
    elif r < 0.20:
        text = text + rng.choice([" thanks", " ty", "?", " asap", " - urgent"])
    elif r < 0.26 and len(text) > 30:
        i = rng.randrange(5, len(text) - 5)
        if text[i].isalpha() and text[i + 1].isalpha():
            text = text[:i] + text[i + 1] + text[i] + text[i + 2:]
    return text


# ----------------------------------------------------------------------------
# Content builders
# ----------------------------------------------------------------------------

def fake_secret(rng):
    alnum = string.ascii_letters + string.digits
    kind = rng.choice(["apikey", "env", "pan", "aadhaar", "contact"])
    if kind == "apikey":
        return f"\nusing key AIzaSy{''.join(rng.choices(alnum + '_-', k=33))} for the maps call"
    if kind == "env":
        return ("\n\n.env:\nDB_HOST=10.20.4.17\nDB_USER=checkout_app\n"
                f"DB_PASSWORD={''.join(rng.choices(alnum, k=14))}\n"
                f"password={''.join(rng.choices(alnum, k=10))}")
    if kind == "pan":
        pan = "".join(rng.choices(string.ascii_uppercase, k=3)) + "P" + rng.choice(string.ascii_uppercase) + \
            "".join(rng.choices(string.digits, k=4)) + rng.choice(string.ascii_uppercase)
        return f"\ntest customer PAN {pan} fails KYC validation"
    if kind == "aadhaar":
        a = str(rng.randint(2, 9)) + "".join(rng.choices(string.digits, k=11))
        return f"\ncustomer aadhaar {a[:4]} {a[4:8]} {a[8:]} in the payload"
    phone = "+91 9" + "".join(rng.choices(string.digits, k=9))
    return f"\nrepro account: {rng.choice(FIRST_NAMES_IN).lower()}.test{rng.randint(10, 99)}@gmail.com, phone {phone}"


def local_time_str(t, tz_off):
    lt = t + dt.timedelta(hours=tz_off)
    sign = "+" if tz_off >= 0 else "-"
    h, m = divmod(int(abs(tz_off) * 60), 60)
    return lt.strftime("%Y-%m-%dT%H:%M:%S") + f"{sign}{h:02d}:{m:02d}"


def model_display(exp):
    parts = exp.split("-")   # gemini-3.8-flash-high
    tier = TIER_LABEL.get(parts[-1], parts[-1].title())
    return f"Gemini {parts[1]} Flash ({tier})"


def build_turn_content(u, text, t, tz_off, feats_used, settings_from, settings_to, rng, home_dir):
    user_text = text
    meta = [f"The current local time is: {local_time_str(t, tz_off)}."]
    blocks = []
    if "slash" in feats_used:
        cmd = rng.choice(SLASH)
        user_text = f"{cmd} {user_text}"
        meta.append(f"{cmd} is a [Slash Command]:\n<{cmd[1:].upper().replace('-', '_')}>\n"
                    f"The user invoked {cmd}. Follow its workflow.\n</{cmd[1:].upper().replace('-', '_')}>")
    repo = rng.choice(REPOS[u["role"]])
    path = f"{home_dir}/code/{repo}/{rng.choice(FILES[repo])}"
    if "mention" in feats_used:
        user_text = f"{user_text} @[{path}]"
        meta.append("The user has mentioned some items in the form @[ITEM]. Here is extra information "
                    "about the items that were mentioned by the user, in the order that they appear:\n"
                    f"@[{path}] is a [File]:\n{path}")
    if u["role"].startswith("swe") or u["role"] in ("qa", "sre", "data"):
        if rng.random() < 0.45:
            ext = os.path.splitext(path)[1]
            meta.append(f"Active Document: {path} (LANGUAGE_{LANG.get(ext, 'plaintext').upper()})\n"
                        f"Cursor is on line: {rng.randint(1, 400)}")
            if rng.random() < 0.4:
                other = f"{home_dir}/code/{repo}/{rng.choice(FILES[repo])}"
                meta.append(f"Other open documents:\n- {other}")
    if "skill" in feats_used:
        blocks.append(f"<SKILL>The user requested you read and use the \"{rng.choice(SKILLS)}\" skill "
                      "for this task.</SKILL>")
    if "subagent" in feats_used:
        blocks.append(f"<SUBAGENT>The user has explicitly added the `{rng.choice(SUBAGENTS)}` subagent "
                      "to this conversation.</SUBAGENT>")
    if settings_to:
        frm = "None" if settings_from is None else model_display(settings_from)
        blocks.append(f"<USER_SETTINGS_CHANGE>\nModel Selection from {frm} to {model_display(settings_to)}\n"
                      "</USER_SETTINGS_CHANGE>")
    out = f"<USER_REQUEST>\n{user_text}\n</USER_REQUEST>\n<ADDITIONAL_METADATA>\n" + \
        "\n\n".join(meta) + "\n</ADDITIONAL_METADATA>"
    if blocks:
        out += "\n" + "\n".join(blocks)
    return out


# ----------------------------------------------------------------------------
# Row builders
# ----------------------------------------------------------------------------

class Writer:
    def __init__(self, out_dir):
        os.makedirs(out_dir, exist_ok=True)
        self.files = {k: gzip.open(os.path.join(out_dir, f"{k}.jsonl.gz"), "wt", encoding="utf-8")
                      for k in ("inference_request", "inference_response", "client_telemetry", "ground_truth")}
        self.counts = {k: 0 for k in self.files}

    def write(self, table, row):
        self.files[table].write(json.dumps(row, separators=(",", ":")) + "\n")
        self.counts[table] += 1

    def close(self):
        for f in self.files.values():
            f.close()


def base_row(log, ctx, t, rng, ids):
    return {
        "logName": f"projects/{ctx['project']}/logs/businessaicode.googleapis.com%2F{log}",
        "resource": {"type": "businessaicode.googleapis.com/BAICInstance",
                     "labels": {"resource_container": ctx["project_number"], "location": "global"}},
        "timestamp": ts(t),
        "receiveTimestamp": ts(t + dt.timedelta(milliseconds=rng.randint(250, 1500))),
        "severity": "INFO",
        "insertId": ids.insert_id(),
    }


def labels(ctx, model, request_id, trajectory_id):
    lb = {"model": model, "client_version": ctx["client_version"], "request_id": request_id,
          "user_id": f"user:{ctx['email']}", "client_name": ctx["client_name"]}
    if trajectory_id:
        lb["trajectory_id"] = trajectory_id
    return lb


def emit_call(w, ctx, t_req, latency_s, model, exp, request_id, trajectory_id, author, content,
              tokens, reply_text, rng, ids, quota_type):
    req = base_row("inference_request", ctx, t_req, rng, ids)
    req["jsonpayload_v1_inferencerequestlog"] = {
        "input": {"messages": [{"author": author, "content": content}]},
        "_type": "type.googleapis.com/google.cloud.businessaicode.logging.v1.InferenceRequestLog",
        "experience": exp,
    }
    req["labels"] = labels(ctx, model, request_id, trajectory_id)
    w.write("inference_request", req)
    t_resp = t_req + dt.timedelta(seconds=latency_s)
    resp = base_row("inference_response", ctx, t_resp, rng, ids)
    md = {"totaltokencount": str(tokens["total"])}
    if ctx["breakdown"]:
        md.update({"prompttokencount": str(tokens["prompt"]),
                   "candidatestokencount": str(tokens["candidates"]),
                   "cachedcontenttokencount": str(tokens["cached"])})
        if tokens["thoughts"]:
            md["thoughtstokencount"] = str(tokens["thoughts"])
        if quota_type:
            md["quotatype"] = quota_type
    msgs = [{"content": reply_text, "author": "MODEL"}] if reply_text else []
    resp["jsonpayload_v1_inferenceresponselog"] = {
        "_type": "type.googleapis.com/google.cloud.businessaicode.logging.v1.InferenceResponseLog",
        "metadata": md, "experience": exp,
        "output": {"candidates": [{"messages": msgs}]},
    }
    resp["labels"] = labels(ctx, model, request_id, trajectory_id)
    w.write("inference_response", resp)
    return t_resp


def emit_event(w, ctx, t, model, request_id, trajectory_id, event_type, itype, outcome, rng, ids):
    row = base_row("client_telemetry", ctx, t, rng, ids)
    md = {}
    if itype:
        md = {"interactiontype": itype, "interactionoutcome": outcome}
    row["jsonpayload_v1_clienttelemetrylog"] = {
        "eventtype": event_type, "metadata": md,
        "_type": "type.googleapis.com/google.cloud.businessaicode.logging.v1.ClientTelemetryLog",
    }
    row["labels"] = labels(ctx, model, request_id, trajectory_id)
    w.write("client_telemetry", row)


# ----------------------------------------------------------------------------
# Trajectory simulation
# ----------------------------------------------------------------------------

class Sim:
    def __init__(self, cfg, users, lib, start, days, now, rng, w):
        self.cfg, self.users, self.lib = cfg, users, lib
        self.start, self.days, self.now = start, days, now
        self.rng, self.w, self.ids = rng, w, Ids(rng)
        self.quota_type = cfg.get("quota_type")
        self.stats = {"trajectories": 0, "aux_calls": 0, "steps": 0, "runaways": 0,
                      "sensitive_turns": 0, "sensitive_aux": 0}
        self.current_ga = dt.date.fromisoformat(cfg["models"]["current_ga"])

    # --- model choice -------------------------------------------------------
    def choose_exp(self, u, day, client_version):
        tier = u["tier_pref"]
        if self.rng.random() < 0.12:
            tier = self.rng.choice(["high", "medium", "low"])
        if u["deprecated"] and self.rng.random() < 0.85:
            tier = "medium" if tier == "low" else tier
            return "gemini-3.5-flash", f"gemini-3.5-flash-{tier}"
        can_new = day >= self.current_ga and vkey(client_version) >= vkey(self.cfg["models"]["min_client_for_current"])
        if can_new:
            ramp = min(1.0, 0.35 + (day - self.current_ga).days / 20)
            if self.rng.random() < ramp:
                return "gemini-3.8-flash", f"gemini-3.8-flash-{tier}"
        if tier == "low":
            tier = "medium"
        return "gemini-3.7-flash", f"gemini-3.7-flash-{tier}"

    # --- per-user timeline -------------------------------------------------
    def run(self):
        runaway_slots = self.pick_runaways()
        for u in self.users:
            arch = self.cfg["archetypes"][u["archetype"]]
            tz_off = self.cfg["timezones"][u["tz"]]
            holidays = set(self.cfg["holidays"][u["tz"]])
            home_dir = f"/Users/{u['email'].split('@')[0].split('.')[0]}"
            for d in range(self.days):
                day = self.start + dt.timedelta(days=d)
                if day < u["onboard"] or (u["churn_date"] and day >= u["churn_date"]):
                    continue
                p = arch["p_active"]
                if (day - u["onboard"]).days < 7:
                    p *= 0.6
                if day.weekday() >= 5:
                    p *= 0.07 if u["archetype"] == "expert" else 0.02
                if day.isoformat() in holidays:
                    p *= 0.1
                if u["churn_date"] and (u["churn_date"] - day).days < 10:
                    p *= 0.5
                if runaway_slots.pop((u["email"], day), None):
                    self.trajectory(u, arch, day, tz_off, home_dir, True)
                if self.rng.random() >= p:
                    continue
                n = 1 + poisson(self.rng, max(0.0, arch["traj_per_day"] - 1))
                for _ in range(n):
                    self.trajectory(u, arch, day, tz_off, home_dir, False)

    def pick_runaways(self):
        slots = {}
        pool = [u for u in self.users if u["archetype"] in ("expert", "advanced") and not u["churn_date"]]
        self.rng.shuffle(pool)
        n = self.cfg["runaways"]
        last = self.start + dt.timedelta(days=self.days - 1)
        for u in pool[:n]:
            while True:
                day = last - dt.timedelta(days=self.rng.randint(2, 25))
                if day.weekday() < 5 and day >= u["onboard"]:
                    break
            slots[(u["email"], day)] = True
        return slots

    def start_time(self, day, tz_off, arch_name):
        # Local business hours with a lunch dip; experts sometimes late.
        r = self.rng.random()
        if arch_name == "expert" and r < 0.10:
            hour = self.rng.uniform(20.5, 23.5)
        else:
            hour = self.rng.choice([self.rng.uniform(9.5, 13.0), self.rng.uniform(14.0, 18.5),
                                    self.rng.uniform(10.0, 17.5)])
        local = dt.datetime.combine(day, dt.time(0), tzinfo=UTC) + dt.timedelta(hours=hour)
        return local - dt.timedelta(hours=tz_off)

    def ctx_for(self, u, day, t):
        rel = latest_release(self.cfg, day, u["lag_days"], u["client_cap"])
        project = u["home_project"]
        if u["second_project"] and self.rng.random() < 0.2:
            project = u["second_project"]
        return {"project": project, "project_number": self.cfg["gcp_projects"][project],
                "email": u["email"], "client_name": self.cfg["company"]["client_name"],
                "client_version": rel["version"], "breakdown": rel["breakdown"],
                "aux_rate": rel["aux_rate"]}

    # --- one trajectory ----------------------------------------------------
    def trajectory(self, u, arch, day, tz_off, home_dir, runaway):
        rng = self.rng
        t = self.start_time(day, tz_off, u["archetype"])
        if t > self.now:
            return
        t0 = t
        ctx = self.ctx_for(u, day, t)
        model, exp = self.choose_exp(u, day, ctx["client_version"])
        traj_id = self.ids.uuid()
        cat = weighted(rng, self.cfg["roles"][u["role"]]["categories"])
        cands = self.lib[cat]
        preferred = [p for p in cands if u["role"] in p["roles"]]
        prompt = rng.choice(preferred if preferred and rng.random() < 0.85 else cands)
        turns = [vary(prompt["text"], rng)]
        for f in prompt["followups"]:
            if rng.random() < arch["followup_p"]:
                turns.append(f)
            else:
                break
        if runaway:
            turns = turns[:2]
        feat_p = arch["feature_p"]
        used_any = set()
        step_n, cum_growth = 0, 0
        base_ctx = int(rng.uniform(14000, 26000))
        prev_prompt = 0
        resolved_p = 0.72 + {"expert": 0.10, "advanced": 0.05, "intermediate": 0.0,
                             "beginner": -0.06, "sparse": -0.10}[u["archetype"]]
        if cat == "other":
            resolved_p -= 0.20
        rework = self.cfg["models"]["rework"]
        settings_from = None
        switched = False
        runaway_steps = rng.randint(320, 480) if runaway else 0
        stopped_early = False

        if rng.random() < self.cfg["aux"]["worktree_p"]:
            self.aux_call(ctx, t - dt.timedelta(seconds=rng.uniform(1, 3)), "gemini-2.5-flash",
                          f"Generate a worktree name for this task: {turns[0][:120]}", small=True)

        for ti, text in enumerate(turns):
            # features for this human turn
            used = {f for f in u["features"] if f in feat_p and f != "switch" and rng.random() < feat_p[f]}
            settings_to = None
            if ti == 0 and rng.random() < 0.72:
                settings_to = exp
                settings_from = None
            elif "switch" in u["features"] and not switched and rng.random() < feat_p.get("switch", 0):
                tier = rng.choice([x for x in ("high", "medium", "low") if not exp.endswith(x)])
                new_exp = exp.rsplit("-", 1)[0] + "-" + tier
                if new_exp.startswith("gemini-3.7-flash-low"):
                    new_exp = "gemini-3.7-flash-high"
                settings_from, settings_to = exp, new_exp
                exp, switched = new_exp, True
                used.add("switch")
            used_any |= used
            if rng.random() < self.cfg["sensitive"]["human_turn_p"]:
                text = text + fake_secret(rng)
                self.stats["sensitive_turns"] += 1
            content = build_turn_content(u, text, t, tz_off, used, settings_from, settings_to, rng, home_dir)
            author = "USER"
            if rng.random() < self.cfg["aux"]["prompt_echo_p"]:
                self.aux_call(ctx, t + dt.timedelta(seconds=rng.uniform(0.2, 1.5)), "gemini-3.5-flash-lite", text,
                              small=True)
            cum_growth += len(text) // 4
            # steps in this turn
            if runaway:
                n_steps = runaway_steps // len(turns)
            else:
                n_steps = max(1, int(round(lognormal(rng, arch["steps_per_turn"], 0.9))))
                n_steps = min(n_steps, 150)
            sys_switch_at = rng.randint(1, n_steps) if n_steps > 2 and rng.random() < 0.06 else None
            for si in range(n_steps):
                step_n += 1
                if sys_switch_at is not None and si == sys_switch_at:
                    author, content = rng.choice(SYSTEM_TURNS)
                req_id = f"{traj_id}-{step_n}"
                # tokens
                growth = lognormal(rng, 1700 if not runaway else 3200, 0.7)
                cum_growth += int(growth)
                prompt_tok = base_ctx + cum_growth
                if not runaway and prompt_tok > self.cfg["aux"]["compaction_tokens"]:
                    self.aux_call(ctx, t, "gemini-3.5-flash-lite",
                                  "Please generate a continuation summary of this session so far.", small=False)
                    cum_growth = int(rng.uniform(12000, 25000))
                    prompt_tok = base_ctx + cum_growth
                prompt_tok = min(prompt_tok, 1_000_000)
                cached = 0 if step_n == 1 else int(min(prev_prompt, prompt_tok) * rng.uniform(0.72, 0.95))
                prev_prompt = prompt_tok
                has_text = rng.random() < (0.35 if si < n_steps - 1 else 0.95)
                candidates = int(lognormal(rng, 380 if has_text else 110, 0.6))
                tier = exp.rsplit("-", 1)[1]
                thoughts = 0
                if rng.random() < 0.85:
                    thoughts = int(lognormal(rng, {"high": 650, "medium": 260, "low": 70}.get(tier, 0), 0.7))
                tokens = {"prompt": prompt_tok, "cached": cached, "candidates": candidates,
                          "thoughts": thoughts, "total": prompt_tok + candidates + thoughts}
                reply = None
                if has_text:
                    head = rng.choice(THOUGHTS[cat])
                    reply = f"**{head}**\n\n" + (rng.choice(REPLIES) if si == n_steps - 1 else
                                                  f"{head.split(' ', 1)[0]} relevant files before making changes.")
                lat = lognormal(rng, {"high": 7.0, "medium": 3.8, "low": 2.2}.get(tier, 3.0), 0.5)
                if t > self.now:
                    stopped_early = True
                    break
                t_resp = emit_call(self.w, ctx, t, lat, model, exp, req_id, traj_id, author, content,
                                   tokens, reply, rng, self.ids, self.quota_type)
                self.stats["steps"] += 1
                t = t_resp
                # terminal-output checks (aux)
                if rng.random() < ctx["aux_rate"]:
                    self.terminal_check(ctx, t + dt.timedelta(seconds=rng.uniform(5, 8)))
                # permission approval
                if si < n_steps - 1 and rng.random() < 0.22:
                    decide = lognormal(rng, 7.0, 1.0)
                    t += dt.timedelta(seconds=decide)
                    rej_p = 0.07 + (0.05 if u["archetype"] in ("beginner", "sparse") else 0.0)
                    outcome = "REJECTED" if rng.random() < rej_p else "ACCEPTED"
                    emit_event(self.w, ctx, t, model, req_id, traj_id, "InferenceInteraction",
                               "PERMISSION_GRANT", outcome, rng, self.ids)
                elif si < n_steps - 1 and rng.random() < 0.01:
                    t += dt.timedelta(seconds=lognormal(rng, 30, 0.8))
                    emit_event(self.w, ctx, t, model, req_id, traj_id, "InferenceInteraction",
                               "TEXT_CLARIFICATION", "ACCEPTED", rng, self.ids)
                t += dt.timedelta(seconds=lognormal(rng, 4.0 if not runaway else 9.0, 0.9))
            if stopped_early:
                break
            # proposals at the end of a code-changing turn
            if cat in CODE_CATEGORIES and rng.random() < 0.7:
                probs = rework.get(exp, rework["default"])
                if used_any & {"skill", "subagent", "slash"}:
                    probs = [probs[0] + 0.06, max(0.0, probs[1] - 0.04), max(0.0, probs[2] - 0.02)]
                for _ in range(rng.randint(1, 3)):
                    t += dt.timedelta(seconds=lognormal(rng, 20, 0.8))
                    outcome = rng.choices(["ACCEPTED", "MODIFIED", "REJECTED"], weights=probs)[0]
                    emit_event(self.w, ctx, t, model, f"{traj_id}-{step_n}", traj_id, "InferenceInteraction",
                               "PROPOSAL_ACCEPTANCE", outcome, rng, self.ids)
                    if outcome != "ACCEPTED":
                        resolved_p -= 0.04
            # gap to the next human turn
            if ti < len(turns) - 1:
                if rng.random() < 0.06:
                    t += dt.timedelta(hours=rng.uniform(14, 20))
                else:
                    t += dt.timedelta(seconds=lognormal(rng, 240, 0.9))
        # resolution
        if used_any & {"skill", "subagent", "slash"}:
            resolved_p += 0.08
        if exp in rework and exp != "default":
            resolved_p -= 0.10
        resolved = (not runaway) and (not stopped_early) and rng.random() < resolved_p
        t_res = t + dt.timedelta(seconds=rng.uniform(1, 20))
        if resolved and t_res <= self.now:
            emit_event(self.w, ctx, t_res, model, f"{traj_id}-{step_n}", traj_id, "InferenceResolved",
                       None, None, rng, self.ids)
        if cat == "ui_frontend" and rng.random() < self.cfg["aux"]["image_p_ui"]:
            self.aux_call(ctx, t, "gemini-3-pro-image", "Generate an image asset: " + turns[0][:100],
                          small=True, model_override="gemini-3-pro-image")
        self.stats["trajectories"] += 1
        self.stats["runaways"] += int(runaway)
        self.w.write("ground_truth", {
            "trajectory_id": traj_id, "user_email": u["email"], "role": u["role"],
            "archetype": u["archetype"], "category": CATEGORY_NAMES[cat], "prompt_id": prompt["id"],
            "human_turns": len(turns), "agent_steps": step_n, "experience": exp,
            "client_version": ctx["client_version"], "project": ctx["project"],
            "customization": sorted(used_any & {"skill", "subagent", "slash"}),
            "features": sorted(used_any), "resolved": resolved, "runaway": runaway,
            "started_at": ts(t0),
        })

    # --- auxiliary calls ---------------------------------------------------
    def aux_call(self, ctx, t, exp, text, small=True, model_override=None):
        if t > self.now:
            return
        rng = self.rng
        prompt = int(lognormal(rng, 900 if small else 60000, 0.5))
        cand = int(lognormal(rng, 30 if small else 1800, 0.5))
        tokens = {"prompt": prompt, "cached": 0, "candidates": cand, "thoughts": 0, "total": prompt + cand}
        emit_call(self.w, ctx, t, lognormal(rng, 1.2, 0.4), model_override or self.cfg["aux"]["model"], exp,
                  self.ids.uuid(), None, "USER", text, tokens, "ok" if small else "**Summary**\n\nSession summary.",
                  rng, self.ids, self.quota_type)
        self.stats["aux_calls"] += 1

    def terminal_check(self, ctx, t):
        cmd = self.rng.choice(TERMINAL_CMDS)
        out = self.rng.choice(["BUILD SUCCESSFUL in 41s", "Tests: 212 passed, 0 failed",
                               "Compiling 38 files...", "Waiting for rollout to finish: 2 of 3 updated replicas",
                               "Plan: 3 to add, 1 to change, 0 to destroy."])
        if self.rng.random() < self.cfg["sensitive"]["terminal_check_p"]:
            out += fake_secret(self.rng)
            self.stats["sensitive_aux"] += 1
        self.aux_call(ctx, t, "gemini-2.5-flash-lite",
                      f"Command: {cmd}\nThe output has not changed for 5s. Recent output:\n{out}", small=True)


# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--users", type=int, default=200)
    ap.add_argument("--days", type=int, default=90)
    ap.add_argument("--end-date", default=dt.datetime.now(UTC).date().isoformat())
    ap.add_argument("--now", default=None, help="UTC cutoff (ISO); default: current time, or end of --end-date if earlier")
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--config", default=os.path.join(HERE, "org.yaml"))
    ap.add_argument("--quota-type", default=None, help="overrides quota_type in the config")
    ap.add_argument("--out", default=os.path.join(HERE, "out"))
    args = ap.parse_args()

    with open(args.config, encoding="utf-8") as f:
        cfg = yaml.safe_load(f)
    if args.quota_type:
        cfg["quota_type"] = args.quota_type
    end = dt.date.fromisoformat(args.end_date)
    start = end - dt.timedelta(days=args.days - 1)
    eod = dt.datetime.combine(end, dt.time(23, 59, 59), tzinfo=UTC)
    now = dt.datetime.fromisoformat(args.now).astimezone(UTC) if args.now else min(dt.datetime.now(UTC), eod)
    cfg["runaways"] = max(1, round(cfg["runaways"] * args.users / 200))

    rng = random.Random(args.seed)
    users = build_roster(cfg, args.users, start, args.days, rng)
    lib = load_prompts()
    w = Writer(args.out)
    sim = Sim(cfg, users, lib, start, args.days, now, rng, w)
    sim.run()
    w.close()

    with open(os.path.join(args.out, "roster.csv"), "w", newline="", encoding="utf-8") as f:
        cols = ["email", "name", "role", "title", "archetype", "tz", "home_project", "second_project",
                "cohort", "onboard", "churn_date", "lag_kind", "lag_days", "client_cap", "tier_pref",
                "deprecated", "features"]
        cw = csv.DictWriter(f, fieldnames=cols)
        cw.writeheader()
        for u in users:
            row = {c: u.get(c) for c in cols}
            row["features"] = " ".join(sorted(u["features"]))
            cw.writerow(row)
    summary = {"window": [start.isoformat(), end.isoformat()], "now": ts(now), "seed": args.seed,
               "users": len(users), "rows": w.counts, **sim.stats}
    with open(os.path.join(args.out, "summary.json"), "w", encoding="utf-8") as f:
        json.dump(summary, f, indent=2)
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    sys.exit(main())
