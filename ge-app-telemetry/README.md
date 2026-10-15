# Google Antigravity in Gemini Enterprise: Telemetry & Observability
`ge-app-telemetry`

This repository provides an end-to-end telemetry and observability pipeline for Google Antigravity developer usage within Gemini Enterprise (GE).

It routes events from Cloud Logging into a **locked raw BigQuery dataset** and exposes **authorized views** (no prompt text) for adoption, agent trust (permission accept/reject) and token usage, plus reporting interfaces.

> **All logs land in a locked raw dataset that only project owners can read. Dashboards use a separate views dataset that never returns prompt text.**

For background on Google Antigravity enterprise features, models, and administrative policies, see the Google Cloud announcement: [Expanding Google Antigravity for enterprise customers](https://cloud.google.com/blog/products/ai-machine-learning/expanding-google-antigravity-for-enterprise-customers?e=48754805).

---

## Architecture Overview

```
┌────────────────────────────────────────────────────────────────────────┐
│               Developer Workstations & Client Surfaces                 │
│      Antigravity 2.0 Hub  │  Antigravity CLI (agy)  │  IDE Extensions  │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ (Authenticated via Gemini Enterprise)
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│                    Google Cloud Logging                                │
│       Resource: businessaicode.googleapis.com/BAICInstance            │
│       Streams: inference_response, client_telemetry, inference_request│
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ (Log Router sink, no exclusions)
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│  RAW dataset: `ge_app_agy_raw`  (owners only)                           │
│   ├── businessaicode_googleapis_com_inference_response  (tokens, output)│
│   ├── businessaicode_googleapis_com_client_telemetry    (interactions)  │
│   ├── businessaicode_googleapis_com_inference_request   (prompts)       │
│   └── Daily partitions, retention -r (default 90d)                     │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ authorized views (no prompt text)
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│  VIEWS dataset: `ge_app_agy_telemetry`  (owners only, views only)       │
│   ├── v_ge_app_agy_user_summary    (7d / 90d per user + all users)     │
│   ├── v_ge_app_agy_adoption        (inferences, sessions per day)      │
│   ├── v_ge_app_agy_trust_quality   (permission accept/reject per day)  │
│   ├── v_ge_app_agy_token_economics (token counters by type per day)    │
│   ├── v_ge_app_agy_model_summary   (7d / 90d per model + all models)   │
│   └── v_ge_app_agy_daily_sessions  (exact sessions per day, any filter)│
└───────────────────┬────────────────────────────────┬───────────────────┘
                    │                                │
                    ▼                                ▼
┌──────────────────────────────────────┐  ┌──────────────────────────────┐
│        Looker Studio (Cloud BI)      │  │    Local Web Dashboard       │
│  • Owner's-credentials data source   │  │  • Node.js + Chart.js        │
│  • Native BigQuery connector         │  │  • Run fetch_data as owner   │
│  • Executive sharing & drill-downs   │  │  • Live BQ refresh button    │
└──────────────────────────────────────┘  └──────────────────────────────┘
```

---

## Repository Structure

```text
ge-app-telemetry/
├── README.md                               # This operator guide
├── SPEC.md                                 # Original technical specification (partly outdated)
├── schemas/raw/                            # RAW table schemas (pre-created by deploy.sh)
│
├── direct-log-sink-to-bq/                  # Track 1: Ingestion & Storage
│   ├── deploy.sh                           # One-command deployer (datasets, lock-down, sink, views)
│   ├── backfill.sh                         # Historical log backfill (not yet updated, see module README)
│   ├── cleanup.sh                          # Pipeline teardown script
│   ├── config.example.yaml                 # Configuration template
│   ├── README.md                           # Ingestion module guide
│   └── terraform/                          # Terraform module (not yet updated to this layout)
│
├── views/                                  # Track 2: Authorized views (no prompt text)
│   ├── 00_v_ge_app_agy_user_summary.sql    # Per-user 7d/90d summary + all-users rows
│   ├── 01_v_ge_app_agy_adoption.sql        # Daily adoption
│   ├── 02_v_ge_app_agy_trust_quality.sql   # Daily permission accept/reject
│   ├── 03_v_ge_app_agy_token_economics.sql # Daily token counters by type
│   ├── 04_v_ge_app_agy_model_summary.sql   # Per-model 7d/90d summary + all-models rows
│   ├── 05_v_ge_app_agy_daily_sessions.sql  # Exact daily sessions for any user/client/model filter
│   ├── deploy_views.sh                     # View deployer + RAW authorization
│   └── README.md                           # View catalog & sample queries
│
├── tools/view-validation/                  # Synthetic-data test: checks every view against known answers
│
└── dashboards/                             # Track 3: Reporting & Visualizations
    └── local-web/                          # Standalone Executive Dashboard
        ├── server.mjs                      # Zero-dependency Node.js HTTP server
        ├── fetch_data.sh                   # BigQuery data extractor (reads views only)
        ├── start.sh / stop.sh              # Service lifecycle scripts
        ├── public/index.html               # Responsive Chart.js dashboard
        └── README.md                       # Local dashboard operational guide
```

---

## Step-by-Step Setup Guide

### Step 1: Deploy (datasets, lock-down, sink, views)
```bash
cd ge-app-telemetry/direct-log-sink-to-bq

# Interactive deployment:
./deploy.sh

# Headless deployment:
./deploy.sh -p <PROJECT_ID> -l us-central1 -r 90 -y
```
This single command creates `ge_app_agy_raw` and its tables, creates `ge_app_agy_telemetry`, locks both to project owners, points the sink at RAW, and deploys and authorizes the 6 views. See [`direct-log-sink-to-bq/README.md`](direct-log-sink-to-bq/README.md).

### Step 2: Visualize & Report

#### Option A: Looker Studio
1. Open the [BigQuery Console](https://console.cloud.google.com/bigquery) as a project owner.
2. Navigate to `<PROJECT_ID>` > `ge_app_agy_telemetry` > **`v_ge_app_agy_user_summary`** (or another view).
3. Click **Explore data** > **Explore with Looker Studio**.
4. In the data source settings, use **Owner's credentials** so report viewers don't need BigQuery access.

#### Option B: Standalone Local Web Dashboard
Run as a project owner (both datasets are owner-only):

```bash
cd ../dashboards/local-web

# Launch server:
./start.sh 8085

# View in browser:
# http://localhost:8085

# Stop server when done:
./stop.sh
```
> [!NOTE]
> The local dashboard has no login and listens on all network interfaces. Use it on trusted machines only. Tabs: Overview · Adoption & Enablement · Fleet & Models · Usage & Tokens · Value & Quality (see [`dashboards/local-web/README.md`](dashboards/local-web/README.md)).

---

## Command Reference

### `direct-log-sink-to-bq/deploy.sh`: deploy everything
| Flag | Short | Default | Description |
| :--- | :--- | :--- | :--- |
| `--config FILE` | `-c` | `config.yaml` if present | YAML/JSON config file (see `config.example.yaml`) |
| `--project-id ID` | `-p` | Active `gcloud` project | Source project where Antigravity is active (where the sink is created) |
| `--dest-project-id ID` | `-d` | Same as `--project-id` | Project hosting the BigQuery datasets |
| `--raw-dataset-id ID` | | `ge_app_agy_raw` | RAW dataset: all fields incl. prompts, owners only |
| `--dataset-id ID` | | `ge_app_agy_telemetry` | Views dataset: no prompt text, owners only |
| `--location REGION` | `-l` | `us-central1` | Residency for both datasets (e.g. `asia-northeast1`, `EU`, `US`) |
| `--sink-name NAME` | `-s` | `ge-app-agy-telemetry-sink` | Cloud Logging sink name |
| `--retention-days DAYS` | `-r` | `90` | RAW partition expiration in days (`0` = never). Under 90 shortens the 90-day user summary |
| `--impersonate-sa EMAIL` | | | Service account to impersonate for `gcloud` calls |
| `--yes` / `--headless` | `-y` | off | Non-interactive (no prompts) |
| `--help` | `-h` | | Show help |
| `--exclude-prompts`, `--enable-prompt-audit`, `--audit-dataset-id`, `--audit-sink-name`, `--audit-retention-days` | | | Deprecated: accepted with a warning, no effect |

```bash
./deploy.sh                                              # interactive
./deploy.sh -p my-ge-project -l us-central1 -r 365 -y    # headless
./deploy.sh -c config.yaml -y                            # from config file
```

### `direct-log-sink-to-bq/cleanup.sh`: remove everything
| Flag | Short | Default | Description |
| :--- | :--- | :--- | :--- |
| `--config FILE` | `-c` | `config.yaml` if present | YAML/JSON config file |
| `--project-id ID` | `-p` | Active `gcloud` project | Project where the sink is deployed |
| `--dest-project-id ID` | `-d` | Same as `--project-id` | Project hosting the BigQuery datasets |
| `--raw-dataset-id ID` | | `ge_app_agy_raw` | RAW dataset to remove |
| `--dataset-id ID` | | `ge_app_agy_telemetry` | Views dataset to remove |
| `--location REGION` | `-l` | `us-central1` | Dataset location (used to find leftovers of older versions) |
| `--sink-name NAME` | `-s` | `ge-app-agy-telemetry-sink` | Sink to remove |
| `--clean-audit` | | off | Also delete a legacy prompts audit dataset (older versions) |
| `--audit-dataset-id ID` | | `ge_app_agy_prompts_audit` | Name of that legacy audit dataset |
| `--audit-sink-name NAME` | | `ge-app-agy-prompts-audit-sink` | Legacy audit sink (always removed if present) |
| `--clean-sa` | | off | Also delete a legacy `agy-curation` service account (older versions) |
| `--force` | `-f` | off | Delete datasets without per-table prompts |
| `--yes` / `--headless` | `-y` | off | Non-interactive (no confirmation) |
| `--help` | `-h` | | Show help |

```bash
./cleanup.sh                                  # interactive, asks for confirmation
./cleanup.sh -p my-ge-project -y -f           # headless
```
Always removed: the sink, the RAW dataset and the views dataset. It aborts if `gcloud` credentials have expired.

### `views/deploy_views.sh`: redeploy the views only
`deploy.sh` already runs this; use it on its own only after editing a view.

| Flag | Short | Default | Description |
| :--- | :--- | :--- | :--- |
| `--config FILE` | `-c` | `config.yaml` if present | YAML config file |
| `--project-id ID` | `-p` | Active `gcloud` project | Project hosting the datasets |
| `--dataset-id ID` | `-d` | `ge_app_agy_telemetry` | Views dataset. **Note:** `-d` here is the dataset, not the destination project as in `deploy.sh` |
| `--raw-dataset-id ID` | | `ge_app_agy_raw` | RAW dataset the views read from |
| `--impersonate-sa EMAIL` | | | Service account to impersonate |
| `--yes` / `--headless` | `-y` | off | Non-interactive |
| `--help` | `-h` | | Show help |

```bash
./deploy_views.sh -p my-ge-project -d ge_app_agy_telemetry --raw-dataset-id ge_app_agy_raw -y
```

---

## View Catalog

| View | Grain | Key Metrics |
| :--- | :--- | :--- |
| **`v_ge_app_agy_user_summary`** | 7d / 90d window × user, plus all users | Active users, inferences, sessions, active days, tokens by type, top model, clients, permission accept/reject, token share |
| **`v_ge_app_agy_adoption`** | Day × user × client × version × model | Inferences, sessions, inferences per session, active hours |
| **`v_ge_app_agy_trust_quality`** | Day × user × client × model | Client events, sessions, finished turns, permission requests / accepted / rejected / rate |
| **`v_ge_app_agy_token_economics`** | Day × user × client × model × experience | Total, prompt, output (candidates), thinking, and cached tokens; avg/min/max per inference |
| **`v_ge_app_agy_model_summary`** | 7d / 90d window × model, plus all models | Users, inferences, sessions, tokens by type, avg/max per inference, experiences, clients, inference & token share |
| **`v_ge_app_agy_daily_sessions`** | Day × every user/client/model combination (`'(all)'` = combined) | Exact daily sessions, active users, inferences |

No cost estimates, proposal metrics or "resolution rates" are reported. See [`views/README.md`](views/README.md) for the reasons.

---

## Key Design Principles

1. **Locked raw, prompt-free views:** all fields, including prompts, land in `ge_app_agy_raw`, which only project owners can read. Consumers use authorized views that never return prompt text.
2. **Honest privacy statement:** prompts are stored for the RAW retention period. Project-level Editor and BigQuery Admin IAM roles still inherit read access. Stricter options (a separate locked project, a "don't store prompts" mode) are planned.
3. **Deterministic fresh installs:** RAW tables are pre-created with the sink's schema, so views deploy before any traffic arrives.
4. **Verified views:** `tools/view-validation/run.sh` checks every view against synthetic data with known answers.
5. **Deduplication in every view:** `QUALIFY ROW_NUMBER() OVER (PARTITION BY insertId, timestamp ORDER BY receiveTimestamp DESC) = 1`.
6. **Facts only:** views report logged counters and events. There are no cost or billing estimates.
