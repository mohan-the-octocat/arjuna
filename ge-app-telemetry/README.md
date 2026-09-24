# Google Antigravity in Gemini Enterprise: Telemetry & Observability
`ge-app-telemetry`

This repository provides an end-to-end telemetry and observability pipeline for Google Antigravity developer usage within Gemini Enterprise (GE).

It routes events from Cloud Logging into BigQuery, provides analytical SQL views (data marts) with automated deduplication, and delivers reporting interfaces for adoption tracking, agent trust/quality evaluation, and FinOps cost attribution.

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
                                    │ (Log Router Sink: Zero Data Retention)
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│           Dedicated BigQuery Dataset: `ge_app_agy_telemetry`           │
│   ├── Partitioned Raw Tables (Daily partition on timestamp)           │
│   │   ├── businessaicode_googleapis_com_inference_response            │
│   │   ├── businessaicode_googleapis_com_client_telemetry              │
│   │   └── businessaicode_googleapis_com_inference_request             │
│   │                                                                    │
│   ├── Retention Engine (Auto-expiring daily partitions, default: 90d)  │
│   │                                                                    │
│   └── Analytical SQL Marts (Views with embedded deduplication)         │
│       ├── v_ge_app_agy_adoption        (DAU, sessions, inferences)     │
│       ├── v_ge_app_agy_trust_quality   (Resolutions, grants, proposals)│
│       └── v_ge_app_agy_token_economics (Tokens, list vs discount cost) │
└───────────────────┬────────────────────────────────┬───────────────────┘
                    │                                │
                    ▼                                ▼
┌──────────────────────────────────────┐  ┌──────────────────────────────┐
│        Looker Studio (Cloud BI)      │  │    Local Web Dashboard       │
│  • 1-Click via BigQuery Console      │  │  • Node.js + Chart.js        │
│  • Native BigQuery connector         │  │  • Port 8085 on Workstation  │
│  • Executive sharing & drill-downs   │  │  • Live BQ refresh button    │
└──────────────────────────────────────┘  └──────────────────────────────┘
```

---

## Repository Structure

```text
ge-app-telemetry/
├── README.md                               # This operator guide
├── SPEC.md                                 # Full technical architecture specification
│
├── direct-log-sink-to-bq/                  # Track 1: Ingestion & Storage
│   ├── deploy.sh                           # Automated CLI deployer (interactive and headless)
│   ├── backfill.sh                         # Historical log backfill script with deduplication
│   ├── cleanup.sh                          # Pipeline teardown script
│   ├── config.example.yaml                 # Configuration template
│   ├── README.md                           # Ingestion module guide
│   └── terraform/                          # Production Terraform IaC module
│       ├── main.tf                         # Dataset, sink, and IAM bindings
│       ├── variables.tf                    # Input parameter declarations
│       ├── outputs.tf                      # Output attributes
│       └── terraform.tfvars.example
│
├── views/                                  # Track 2: Analytical SQL Data Marts
│   ├── 01_v_ge_app_agy_adoption.sql        # Adoption & developer velocity view
│   ├── 02_v_ge_app_agy_trust_quality.sql   # Agent trust & human-in-the-loop quality view
│   ├── 03_v_ge_app_agy_token_economics.sql # Token volume & cost attribution view
│   ├── deploy_views.sh                     # Automated SQL view deployer
│   └── README.md                           # View catalog & sample queries
│
└── dashboards/                             # Track 3: Reporting & Visualizations
    └── local-web/                          # Standalone Executive Dashboard
        ├── server.mjs                      # Zero-dependency Node.js HTTP server
        ├── fetch_data.sh                   # BigQuery data extractor
        ├── start.sh / stop.sh              # Service lifecycle scripts
        ├── public/index.html               # Responsive Chart.js dashboard
        └── README.md                       # Local dashboard operational guide
```

---

## Step-by-Step Setup Guide

### Step 1: Deploy Log Sink & BigQuery Dataset
Routes live Antigravity events (`businessaicode.googleapis.com`) to BigQuery with Zero Data Retention (prompts excluded):

```bash
cd ge-app-telemetry/direct-log-sink-to-bq

# Interactive deployment:
./deploy.sh

# Headless deployment (default Zero Data Retention):
./deploy.sh -p <PROJECT_ID> -l us-central1 -d ge_app_agy_telemetry -y

# Optional: Enable secondary isolated prompt audit dataset (30-day retention):
./deploy.sh -p <PROJECT_ID> -l us-central1 -d ge_app_agy_telemetry \
  --enable-prompt-audit \
  --audit-dataset-id ge_app_agy_prompts_audit \
  --audit-retention-days 30 -y
```

### Step 2: Backfill Historical Data (Optional)
Scans Cloud Logging for historical entries and inserts them with `insertId` deduplication:

```bash
# Backfill last 7 days:
./backfill.sh --days=7 -p <PROJECT_ID> -d ge_app_agy_telemetry
```

### Step 3: Deploy BigQuery Analytical Views
Deploys the three data mart views with embedded deduplication:

```bash
cd ../views

# Deploy views to active project:
./deploy_views.sh -p <PROJECT_ID> -d ge_app_agy_telemetry -y
```

### Step 4: Visualize & Report

#### Option A: Looker Studio (1-Click via Cloud Console)
1. Open the [BigQuery Console](https://console.cloud.google.com/bigquery).
2. Navigate to `<PROJECT_ID>` > `ge_app_agy_telemetry` > **`v_ge_app_agy_adoption`**.
3. Click **Explore data** > **Explore with Looker Studio**.
4. Looker Studio opens with your dataset pre-connected and authenticated.

#### Option B: Standalone Local Web Dashboard
Launches a local Node.js dashboard featuring 3 KPI cards, 6 interactive Chart.js graphs, and a per-user attribution table:

```bash
cd ../dashboards/local-web

# Launch server:
./start.sh 8085

# View in browser:
# http://sanjitmehta-work-1.c.googlers.com:8085 (or http://localhost:8085)

# Stop server when done:
./stop.sh
```

---

## Data Mart View Catalog

| View | Granularity | Key Metrics |
| :--- | :--- | :--- |
| **`v_ge_app_agy_adoption`** | Daily per user, surface, model | Distinct DAU, active trajectories, total inferences, inferences per trajectory, operational hours. |
| **`v_ge_app_agy_trust_quality`** | Daily per user, surface, model | Trajectory resolution rate (`InferenceResolved`), permission grant rate (accepted vs. rejected), proposal acceptance and modification rates. |
| **`v_ge_app_agy_token_economics`** | Daily per user, model, experience tier | Input/output tokens, average context size, list cost ($0.15/1M), 50% Flash discount cost ($0.075/1M), flat-rate seat status (`SEAT_INCLUDED`). |

---

## Key Design Principles

1. **Zero Data Retention (ZDR) by Default:** The primary Log Router sink excludes `jsonPayload.contents`, ensuring proprietary code, prompt text, and model responses are never stored in the general telemetry dataset.
2. **Dual-Plane Security Isolation:** Because BigQuery IAM permissions inherit downwards (`Project -> Dataset -> Table`) and cannot be denied at table-level, raw prompt/completion audit logs (if required for compliance) are isolated into a separate dataset (`ge_app_agy_prompts_audit`) with restricted IAM and an independent 30-day retention policy.
3. **Two-Tier Deduplication:** `backfill.sh` deduplicates at ingestion against existing `insertId`s, and all SQL views embed `QUALIFY ROW_NUMBER() OVER(PARTITION BY insertId ORDER BY timestamp DESC) = 1`.
4. **Seat vs. Consumption Separation:** Flat-rate interactive developer usage ($10/$15 PUPM) is explicitly flagged as `SEAT_INCLUDED` to differentiate from pay-as-you-go headless agent consumption.
