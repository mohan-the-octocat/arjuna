# Technical Specification: `ge-app-telemetry`
## Antigravity Telemetry & Observability Pipeline for Gemini Enterprise

**Version:** 1.1.0  
**Status:** Approved Specification  
**Target Environment:** Google Cloud Platform (Gemini Enterprise)  
**Backend Service:** `businessaicode.googleapis.com`  

---

## 1. Executive Summary & Problem Statement

Enterprises deploying **Google Antigravity** via **Gemini Enterprise (GE)** (e.g., Antigravity 2.0 Hub, Antigravity CLI, IDE extensions) require continuous visibility across three key operational pillars:
1. **Adoption & Velocity:** Tracking Daily/Weekly Active Users (DAU/WAU), session depth, and developer surface preference.
2. **Agent Trust & Quality:** Quantifying autonomous developer interactions, including code proposal acceptance rates, modification rates, and terminal/tool permission grant rates.
3. **FinOps & Cost Attribution:** Aggregating token consumption by model, user, and team to project burn rates and allocate showback/chargebacks against Gemini Enterprise quota.

This module, `ge-app-telemetry`, defines a production-grade, zero-ETL streaming pipeline routing native Antigravity logs from **Cloud Logging** directly into a **dedicated BigQuery dataset**, accompanied by analytical SQL data marts, automated retention lifecycle management, and operational dashboard templates.

---

## 2. End-to-End Architecture & Data Flow

```
┌─────────────────────────────────────────────────────────────────────────┐
│               Developer Workstations & Client Surfaces                   │
│    Antigravity 2.0 Hub  │  Antigravity CLI (agy)  │  IDE Extensions     │
└────────────────────────────────────┬────────────────────────────────────┘
                                     │ (Authenticated via GE App)
                                     ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                     Google Cloud Logging                                 │
│        Resource: businessaicode.googleapis.com/BAICInstance             │
│        Streams: inference_response, client_telemetry, inference_request │
└────────────────────────────────────┬────────────────────────────────────┘
                                     │ (Push Log Router Sink: ZDR)
                                     ▼
┌─────────────────────────────────────────────────────────────────────────┐
│           Dedicated BigQuery Dataset: `ge_app_agy_telemetry`            │
│  ├── Partitioned Raw Tables (Daily partition on timestamp)              │
│  │   ├── businessaicode_googleapis_com_inference_response               │
│  │   ├── businessaicode_googleapis_com_client_telemetry                 │
│  │   └── businessaicode_googleapis_com_inference_request                │
│  │                                                                      │
│  ├── Retention Engine (Auto-expiring daily partitions, default: 90d)    │
│  │                                                                      │
│  └── Analytical SQL Marts (Views with embedded deduplication)           │
│      ├── v_ge_app_agy_adoption        (DAU, sessions, inferences)       │
│      ├── v_ge_app_agy_trust_quality   (Resolutions, grants, proposals)  │
│      └── v_ge_app_agy_token_economics (Tokens, list vs discount cost)   │
└───────────────────┬────────────────────────────────┬────────────────────┘
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

## 3. Log Schema & Taxonomy (Empirically Verified)

All telemetry is emitted under the monitored resource type:
* **`resource.type`**: `businessaicode.googleapis.com/BAICInstance`
* **`resource.labels.location`**: `global` (or regional where applicable)
* **`resource.labels.resource_container`**: Numeric GCP Project Number

### 3.1 Universal Common Labels
Every log record carries uniform context labels:

| Label Key | Type | Description | Example |
| :--- | :--- | :--- | :--- |
| `labels.user_id` | `STRING` | Authenticated corporate developer identity | `user:user_alpha@sanjitmehta.altostrat.com` |
| `labels.trajectory_id` | `STRING` | UUID identifying the agentic session/conversation | `12a0becc-84ab-4af2-b25b-9b0a6b48db28` |
| `labels.request_id` | `STRING` | Unique step/turn identifier within trajectory | `12a0becc-84ab-4af2-b25b-9b0a6b48db28-118` |
| `labels.client_name` | `STRING` | Antigravity developer surface | `antigravity_hub`, `antigravity_cli`, `vscode` |
| `labels.client_version` | `STRING` | Client build version | `2.11.0` |
| `labels.model` | `STRING` | Underlying foundation model | `gemini-3.7-flash` |

### 3.2 Log Stream Payloads

#### A. `businessaicode.googleapis.com%2Finference_response`
Emitted upon completion of every model inference turn.
* **Protobuf Type (`jsonPayload.@type`):** `type.googleapis.com/google.cloud.businessaicode.logging.v1.InferenceResponseLog`
* **Key Fields:**
  * `jsonPayload.metadata.totalTokenCount` (`STRING`): Total tokens consumed by request and response.
  * `jsonPayload.contents` (`ARRAY`): Conversational prompt and model response payload (governed by privacy exclusion filter).

#### B. `businessaicode.googleapis.com%2Fclient_telemetry`
Emitted for developer interaction events and lifecycle milestones.
* **Protobuf Type (`jsonPayload.@type`):** `type.googleapis.com/google.cloud.businessaicode.logging.v1.ClientTelemetryLog`
* **Key Fields:**
  * `jsonPayload.eventType`:
    * `InferenceInteraction`: Developer responded to an agent proposal or action prompt.
    * `InferenceResolved`: Entire trajectory successfully completed.
  * `jsonPayload.metadata.interactionType`:
    * `PROPOSAL_ACCEPTANCE`: Code diff or file change proposal.
    * `PERMISSION_GRANT`: Terminal command execution, file write, or external tool invocation.
  * `jsonPayload.metadata.interactionOutcome`:
    * `ACCEPTED`: Developer confirmed proposal/action without edits.
    * `REJECTED`: Developer declined proposal/action.
    * `MODIFIED`: Developer edited code before accepting.

#### C. `businessaicode.googleapis.com%2Finference_request`
Emitted when an inference call is initiated.
* **Protobuf Type (`jsonPayload.@type`):** `type.googleapis.com/google.cloud.businessaicode.logging.v1.InferenceRequestLog`
* **Key Fields:** Request timestamp, parameter configurations.

---

## 4. Ingestion & Storage Architecture

### 4.1 Dedicated BigQuery Dataset (Mandatory)
* **Dataset ID:** Configurable (Default: `ge_app_agy_telemetry`).
* **Location:** Explicitly pinned (e.g., `us-central1`, `asia-northeast1`, `australia-southeast1`, `europe-west1`, `EU`, `US`).
* **Isolation Benefits:**
  * Strict IAM least-privilege boundary (the sink writer service account receives access *only* to this dataset).
  * Data residency and sovereignty compliance (SZPT / DRZ).
  * Isolated default partition expiration policies without impacting other project tables.

### 4.2 Cloud Logging Router Sink
* **Sink Name:** Configurable (Default: `ge-app-agy-telemetry-sink`).
* **Destination:** `bigquery.googleapis.com/projects/${DEST_PROJECT_ID}/datasets/${DATASET_ID}`.
* **Ingestion Flags:** `--use-partitioned-tables` (creates daily partitions on `timestamp`).
* **Filter Expression:**
  ```sql
  resource.type="businessaicode.googleapis.com/BAICInstance"
  AND logName =~ "businessaicode.googleapis.com"
  ```
* **Privacy & Zero Data Retention (ZDR) Filter (Configurable):**
  When `exclude_prompt_contents = true`, raw code diffs and conversational text bodies are stripped at ingestion, persisting only operational metadata, tokens, and telemetry:
  ```sql
  -- Exclusion filter applied to sink
  logName =~ "businessaicode.googleapis.com%2Finference_response"
  AND jsonPayload.contents:*
  ```

### 4.3 Data Lifecycle & Archiving Engine

```
[Day 0] Ingestion ──> Active BigQuery Storage ($0.02/GB/mo)
                          │
[Day 90] Auto-Tier ──> Long-Term Storage ($0.01/GB/mo, 50% discount, zero query penalty)
                          │
[Day 90 - 180] ───────┬──> BigQuery Partition Expiration (Auto-purge at zero cost)
                      │
                      └──> [Optional] Scheduled Parquet Export ──> GCS Coldline/Archive ($0.0012/GB/mo)
```

1. **Active Storage (Days 1–89):** High-velocity querying and real-time dashboarding.
2. **Automatic Long-Term Pricing (Day 90+):** Any partition unmodified for 90 days drops automatically to \$0.01/GB/mo.
3. **Partition Auto-Expiration:** Dataset-level `default_partition_expiration_ms` auto-deletes raw log partitions beyond the retention window (e.g., 90, 180, or 365 days).
4. **Cold Archive Export (Optional):** Scheduled SQL exports older partitions to a regional Cloud Storage bucket in compressed Parquet format before expiration for multi-year audit compliance.

---

## 5. Configuration Schema & Precedence Contract

All parameters are 100% configurable and share an identical contract across configuration files, CLI flags, and Terraform.

### 5.1 Master Parameter Catalog

| Parameter | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `project_id` | `string` | *(Auto-detected from gcloud)* | Source GCP project where Antigravity logs are emitted. |
| `destination_project_id` | `string` | `${project_id}` | Target GCP project hosting the BigQuery dataset. |
| `dataset_id` | `string` | `ge_app_agy_telemetry` | Name of the dedicated BigQuery dataset. |
| `dataset_location` | `string` | `us-central1` | Data residency location (e.g., `asia-northeast1`, `australia-southeast1`). |
| `sink_name` | `string` | `ge-app-agy-telemetry-sink` | Cloud Logging Log Router sink identifier. |
| `partition_expiration_days` | `number` | `90` | Daily partition lifespan in days (`0` = never expire). |
| `exclude_prompt_contents` | `bool` | `true` | Privacy gate: drops raw prompt/code text bodies from BigQuery. |
| `flash_discount_applied` | `bool` | `true` | Applies 50% promotional rate discount for Gemini 3.5/3.7 Flash models. |
| `billing_export_table` | `string` | `""` | Optional fully-qualified BigQuery Billing export table for invoice joins. |
| `resource_labels` | `map` | `{ "managed-by": "antigravity-extensions" }` | GCP resource labels for FinOps tagging. |

### 5.2 Standard Configuration File Schema (`config.yaml` / `config.json`)

```yaml
# config.yaml (Environment Configuration)
project_id: "sanjit-ge-pilot"
destination_project_id: "sanjit-ge-pilot"
dataset_id: "ge_app_agy_telemetry"
dataset_location: "asia-northeast1"
sink_name: "ge-app-agy-telemetry-sink"
partition_expiration_days: 90
exclude_prompt_contents: true
flash_discount_applied: true
billing_export_table: ""
resource_labels:
  environment: "pilot"
  team: "cloud-ce"
  managed-by: "antigravity-extensions"
```

### 5.3 Resolution Precedence
Values resolve in a strict cascading order:
1. **Explicit CLI Flags** (e.g., `--location=australia-southeast1`)
2. **Specified Config File** (e.g., `--config=environments/prod.yaml`)
3. **Default Config File** (`config.yaml` in current working directory if present)
4. **Environment Variables / Active Context** (`GOOGLE_CLOUD_PROJECT` or `gcloud config`)
5. **Built-in System Defaults**

---

## 6. BigQuery Analytical Data Marts (SQL Views)

Three standard views are deployed into the dedicated dataset:

### View 1: `v_ge_app_agy_adoption`
* **Granularity:** Daily per user per client surface per model.
* **Key Metrics:**
  * `daily_active_users`: Distinct active user emails.
  * `active_trajectories`: Distinct session identifiers (`trajectory_id`).
  * `total_inferences`: Inferences executed (`request_id`).
  * `inferences_per_trajectory`: Session depth (interaction density).
  * `active_hours_count`: Number of active operational hours per day.

### View 2: `v_ge_app_agy_trust_quality`
* **Granularity:** Daily per user per client surface per model.
* **Key Metrics:**
  * `proposal_acceptance_rate`: Ratio of accepted code proposals.
  * `proposal_modification_rate`: Ratio of proposals accepted with developer modifications.
  * `permission_grant_rate`: Ratio of granted filesystem/terminal execution permissions.
  * `trajectory_resolution_rate`: Ratio of completed agent tasks (`InferenceResolved`) vs. total.

### View 3: `v_ge_app_agy_token_economics`
* **Granularity:** Daily per user per model per experience tier.
* **Key Metrics:**
  * `total_tokens`: Total token volume (`metadata.totalTokenCount`).
  * `avg_tokens_per_inference`: Average context size per turn.
  * `estimated_cost_usd_list`: Standard blended list rate ($0.15 / 1M tokens).
  * `estimated_cost_usd_discounted`: Rate applying 50% Flash promotional discount ($0.075 / 1M tokens).
  * `subscription_tier_type`: Classifies flat-rate interactive usage (`SEAT_INCLUDED`) vs. consumption.

---

## 7. Visualizations & Reporting Surfaces (Track 3)

The pipeline provides two primary visualization modalities, accompanied by architectural analysis of Google Cloud Monitoring:

### 7.1 Looker Studio (Cloud BI)
* **Integration Mechanism:** Native BigQuery connector with zero data movement or middleware.
* **1-Click Launch:** In Google Cloud Console under BigQuery Studio, selecting `v_ge_app_agy_adoption` > **Explore data** > **Explore with Looker Studio** instantly opens a pre-authenticated reporting workspace.
* **Capabilities:** Multi-dimension filtering (by developer email, model, surface), drill-down tables, and executive report sharing across enterprise stakeholders.

### 7.2 Standalone Local Web Dashboard (`dashboards/local-web/`)
* **Architecture:** Zero-dependency Node.js HTTP server (`server.mjs`) serving an interactive single-page application (`public/index.html`) rendered with Chart.js.
* **Data Ingestion:** Automated shell extractor (`fetch_data.sh`) querying the BigQuery views via `bq query --format=json`.
* **Visual Components:**
  * **3 KPI Cards:** Developer Adoption (DAU, sessions, inferences), Agent Trust & Quality (Resolution rate %, permission grant rate %, turn density), and FinOps Token Economics (Total tokens, list cost, 50% Flash discount cost).
  * **6 Interactive Charts:** Daily inference trends, active trajectories, tool permission approvals (accepted vs. rejected), model distribution, daily token volume, and cost attribution over time.
  * **Model & Tier Attribution Table:** Granular date-by-date breakdown of model usage, token consumption, and flat-rate seat classifications (`SEAT_INCLUDED`).
  * **Live Synchronization:** An interactive `↻ Refresh from BigQuery` button triggering live view extraction without server restart.
* **Default Port:** `8085` (`http://sanjitmehta-work-1.c.googlers.com:8085` or `http://localhost:8085`).

### 7.3 Google Cloud Monitoring (GCM) Engine Boundary
* **Log Analytics Boundary:** Cloud Monitoring's SQL feature (`opsAnalyticsQuery`) routes queries exclusively to the **Cloud Logging Log Analytics engine**, which requires 4-part table references (`project.location.bucket.view`).
* **BigQuery Dataset Incompatibility:** Standard 3-part BigQuery dataset views (`project.dataset.view`) cannot be queried by Cloud Monitoring (`Query error: Request contains an invalid argument.`).
* **Clean Boundary:** Non-functional Cloud Monitoring code has been excluded from the repository to prevent configuration errors. All reporting is served natively via Looker Studio (Cloud BI) and the local web dashboard.

---

## 8. Delivery Modalities & Repository Layout

```
ge-app-telemetry/
├── SPEC.md                                  # Technical specification & architecture design
├── README.md                                # Operator quickstart & architecture guide
│
├── direct-log-sink-to-bq/                   # Track 1: Push Log Router sink & BigQuery storage
│   ├── deploy.sh                            # Interactive & headless CLI deployer
│   ├── backfill.sh                          # Historical log backfill with deduplication
│   ├── cleanup.sh                           # Teardown script
│   ├── config.example.yaml                  # Full configuration parameter template
│   └── terraform/                           # Production IaC module
│       ├── main.tf                          # Dataset, sink, and IAM bindings
│       ├── variables.tf                     # Input declarations
│       ├── outputs.tf                       # Output attributes
│       └── terraform.tfvars.example
│
├── views/                                   # Track 2: Analytical SQL data marts
│   ├── 01_v_ge_app_agy_adoption.sql         # Adoption & usage mart
│   ├── 02_v_ge_app_agy_trust_quality.sql    # Trust, quality, and permission mart
│   ├── 03_v_ge_app_agy_token_economics.sql  # Token volume & cost attribution mart
│   ├── deploy_views.sh                      # Automated view deployer
│   └── README.md
│
└── dashboards/                              # Track 3: Reporting & Visualizations
    └── local-web/                           # Standalone executive dashboard
        ├── server.mjs                       # Zero-dependency Node.js HTTP server
        ├── fetch_data.sh                    # Live BigQuery data extractor
        ├── start.sh / stop.sh               # Service lifecycle scripts
        ├── public/index.html                # Responsive Chart.js dashboard
        └── README.md
```

---

## 9. Verification & Test Plan

1. **Pre-Flight Validation:** Verify `gcloud` identity, check IAM permissions (`roles/logging.configWriter`, `roles/bigquery.admin`).
2. **Sink Pipeline Smoke Test:** Generate synthetic inference in Antigravity Hub / CLI $\rightarrow$ verify arrival in BigQuery raw tables within 30 seconds.
3. **Privacy Filter Verification:** Confirm `jsonPayload.contents` is omitted in BigQuery when `exclude_prompt_contents = true`.
4. **View Compilation Test:** Execute `bq query --dry_run` against all 3 SQL views to confirm syntax, partition pruning, and schema alignment.
