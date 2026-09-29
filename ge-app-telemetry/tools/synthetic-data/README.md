# Synthetic telemetry for ge-app-telemetry

Generates realistic, fully synthetic Antigravity (Gemini Enterprise
`businessaicode`) telemetry for a fictional software company, "Cymbal", and
loads it into BigQuery in the same shape the log sink writes. Use it to demo
the dashboards and to test new views without real user data.

**Everything here is fake.** Names, emails (`@cymbalgroup.com`), GCP projects,
prompts and the secret-shaped strings are invented.

## Quick start

```bash
python3 generate.py --users 200 --days 91 --end-date 2026-09-29 --seed 42
python3 check_distributions.py           # verify the stories before loading
./load.sh --project <your-project>       # dataset ge_app_agy_telemetry, us-central1
```

Then point the dashboard at it:

```bash
cd ../../dashboards/local-web
./fetch_data.sh <your-project> ge_app_agy_telemetry
PORT=8086 node server.mjs
```

Re-run all three steps with a new `--end-date` before a demo so the 30-day
window stays current. `load.sh` replaces the tables (`--replace`), so re-runs
don't duplicate rows.

## Files

| File | Purpose |
|---|---|
| `org.yaml` | Org roles and counts, GCP projects, tiers, rollout, client releases, models, scenario rates |
| `prompts/*.jsonl` | 1,500 typed prompts, 150 per activity category, each tagged with its intended category ([BRIEF.md](prompts/BRIEF.md)) |
| `generate.py` | Simulates users and trajectories; writes gzip JSONL per table |
| `check_distributions.py` | Recomputes the PRD metrics from the files and prints them |
| `load.sh` | Creates the dataset and tables, loads, deploys `../../views` |
| `schemas/` | Table schemas copied from a live deployment, plus `ground_truth.json` |

## What the data shows

| Story | Where it shows |
|---|---|
| July pilot (15% of users), rollout in August, plateau in September; ~35% of the pilot churns | Daily trends, retention cohorts |
| Expert, advanced, intermediate, beginner and sparse users by role | Expertise tiers, User Insights |
| Experts use skills, subagents, slash commands, @-mentions, model switches | Customization adoption, tiers |
| Role-driven activity mix (SRE → infra, PM → docs, UX → UI) | Activity types |
| Client releases 2.10 → 2.17; ~10% of users stuck on old versions; 2.16.0 roughly doubles background calls | Fleet, background overhead |
| Clients before 2.12 report only `totaltokencount` | Token-breakdown degraded state |
| gemini-3.8-flash from 2 Sep ramps to ~90%; a few users stay on gemini-3.5-flash (deprecated) | Model mix |
| gemini-3.7-flash-medium and 3.5-flash have ~2x the proposal rework rate | Rework rate |
| 3 runaway trajectories (380–460 steps) | Runaway alerts |
| Fake API keys, passwords, PAN/Aadhaar-shaped numbers in ~1.5% of human turns and ~3% of terminal-check calls | Sensitive data in prompts |
| High-tier trajectories with ≤3 steps | Reasoning-tier right-sizing |

Kept neutral on purpose: one corporate domain, no budget breach, no guardrail
blocks, no automation identities, ordinary approval latency.

## Row shape

Matches the reference deployment:

- one `inference_request` row per model call, carrying only the latest turn,
  re-logged on every agent step and wrapped in `<USER_REQUEST>` /
  `<ADDITIONAL_METADATA>` (plus `<SKILL>`, `<SUBAGENT>`,
  `<USER_SETTINGS_CHANGE>` when used);
- one `inference_response` row per call with STRING token counts; about half
  of the steps have no text (tool-call steps);
- `client_telemetry` events: `PERMISSION_GRANT`, `PROPOSAL_ACCEPTANCE`,
  `TEXT_CLARIFICATION`, `InferenceResolved`;
- auxiliary calls (worktree naming, terminal-output checks, compaction,
  prompt echo, image generation) have no `trajectory_id`;
- `request_id` = `<trajectory_id>-<step>`; `resource_container` is the fake
  project number and `logName` carries the fake project ID.

`_synth_ground_truth` holds each trajectory's intended activity category,
archetype and flags. The views don't read it; use it to score an activity
classifier (PRD acceptance criterion A1).

## Assumptions

Distribution shapes (steps, turns, approvals, token sizes, model and
experience names, client versions) are anchored to one real single-user
deployment and then varied by archetype. Release dates, the deprecated
model, adoption curves and all rates in `org.yaml` are invented for the demo.
