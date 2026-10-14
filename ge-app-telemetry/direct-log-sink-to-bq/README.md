# Google Antigravity in Gemini Enterprise: Direct Log Sink to BigQuery
`ge-app-telemetry/direct-log-sink-to-bq`

This module routes Google Antigravity developer telemetry from Cloud Logging into BigQuery, in two datasets:

> **All logs land in a locked raw dataset that only project owners can read. Dashboards use a separate views dataset that never returns prompt text.**


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
                                    │ Log Router sink (no exclusions)
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│  RAW: `ge_app_agy_raw`  – ALL fields incl. prompts & responses          │
│  3 tables pre-created · daily partitions · retention -r (default 90d)  │
│  Access: project owners only (+ sink writer, + authorized views)       │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ authorized views (read RAW, return no prompt text)
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│  VIEWS: `ge_app_agy_telemetry`  – no tables, no prompt text             │
│  v_ge_app_agy_user_summary (7d/90d, per user + all users)              │
│  v_ge_app_agy_adoption · v_ge_app_agy_trust_quality ·                  │
│  v_ge_app_agy_token_economics                                          │
│  Access: project owners only (+ manual grants, e.g. Looker Studio)     │
└────────────────────────────────────────────────────────────────────────┘
```

### Log Record Fields

Antigravity in Gemini Enterprise emits the following top-level labels on each log record:
* `labels.user_id`: Authenticated developer email (`user:developer@company.com`).
* `labels.trajectory_id`: Root UUID identifying the multi-turn session.
* `labels.request_id`: Turn-level execution step ID.
* `labels.client_name`: Client surface (`antigravity_hub`, `antigravity_cli`, `vscode`).
* `labels.model`: Model called (`gemini-3.7-flash`).
* `client_telemetry`: Interaction outcomes (`PERMISSION_GRANT` → `ACCEPTED`, `REJECTED`).

---

## Privacy & Access Model

| | `ge_app_agy_raw` | `ge_app_agy_telemetry` |
| :--- | :--- | :--- |
| Contains | All log fields, **including prompts** (`input.messages[].content`) and **model output** (`output.candidates[].messages[].content`) | Views only: usage, sessions, tokens, permission outcomes. **Never prompt or output text** |
| Dataset access | Project owners, the sink writer, and the authorized views | Project owners, plus anyone you grant manually |
| Retention | `--retention-days` (default 90; `0` = never) | n/a (views) |

* **Lock-down:** `deploy.sh` removes BigQuery's default `projectReaders` / `projectWriters` dataset entries from both datasets, so the basic Viewer role no longer grants read access.
* **IAM caveat:** project-level **Editor** and **BigQuery Admin / Data Owner / Data Viewer** IAM roles still inherit read access to both datasets; dataset settings cannot remove that. For strict isolation, a separate locked project is planned.
* **Prompts are stored** for the RAW retention period. There's no "don't store prompts" option in this version.
* **Why not a log exclusion filter?** Cloud Logging exclusions can only drop whole entries, not individual fields. Response entries mix token counts with model output, so excluding them would lose the telemetry too.

---

## Prerequisites

Before deploying, ensure you have:

1. **GCP Permissions:** Your user or deployment service account needs:
   * `roles/logging.configWriter` (to create the Cloud Logging sink)
   * `roles/bigquery.admin` (to create datasets, tables and views, and to set dataset access)
   * `roles/serviceusage.serviceUsageAdmin` (if APIs are not yet enabled)
2. **Local CLI Tools:**
   * `gcloud` CLI (authenticated via `gcloud auth login`)
   * `bq` CLI
   * `jq` and `python3` (used by `deploy.sh`, `cleanup.sh` and `backfill.sh`)
3. **Required APIs:**
   * `logging.googleapis.com`
   * `bigquery.googleapis.com`
   *(Checked and enabled automatically by `deploy.sh`)*

---

## Deployment (`deploy.sh`)

One command sets up everything:
- the RAW dataset and its 3 tables (pre-created from `../schemas/raw`);
- the views dataset;
- the lock-down of both datasets;
- the sink → RAW;
- the 4 authorized views (via `../views/deploy_views.sh`).

#### 1. Quick Interactive Mode (Recommended)
```bash
cd ge-app-telemetry/direct-log-sink-to-bq
./deploy.sh
```
Prompts: source project, destination project, raw dataset, views dataset, location, sink name, and raw data retention days. A summary and a short notice about where prompts are stored are shown before you confirm.

#### 2. Configuration File Mode
```bash
cp config.example.yaml config.yaml
# Edit project_id, dataset_location, partition_expiration_days, etc.
./deploy.sh --config=config.yaml -y
```

#### 3. Headless Single-Command Mode (CI/CD)
```bash
./deploy.sh --project-id "my-ge-project" --location "asia-northeast1" --retention-days 365 -y
```

#### CLI Flag Reference

| Flag | Short | Default | Description |
| :--- | :--- | :--- | :--- |
| `--project-id ID` | `-p` | Active `gcloud` project | Source GCP Project ID where Antigravity / Gemini Enterprise is active. |
| `--dest-project-id ID` | `-d` | Same as `project-id` | Destination GCP Project ID hosting BigQuery. |
| `--raw-dataset-id ID` | | `ge_app_agy_raw` | RAW dataset (all fields incl. prompts; owners only). |
| `--dataset-id ID` | | `ge_app_agy_telemetry` | Views dataset (no prompt text; owners only). |
| `--location REGION` | `-l` | `us-central1` | Regional or multi-regional residency for both datasets. |
| `--sink-name NAME` | `-s` | `ge-app-agy-telemetry-sink` | Cloud Logging Log Router sink name. |
| `--retention-days DAYS` | `-r` | `90` | RAW daily partition lifespan in days (`0` = never expire). Values under 90 shorten the 90-day window in `v_ge_app_agy_user_summary` (a warning is shown). |
| `--impersonate-sa EMAIL` | | *(None)* | Service Account to impersonate during deployment (gcloud calls). |
| `--config FILE` | `-c` | *(None)* | Path to YAML/JSON configuration file. |
| `--headless` / `--yes` | `-y` | `false` | Run non-interactively. |
| `--help` | `-h` | | Display help message and exit. |
| `--exclude-prompts`, `--enable-prompt-audit`, `--audit-*` | | | **Deprecated, ignored** (warning shown). |

**Re-running `deploy.sh` is safe:**
- existing datasets and tables are kept, and missing schema fields are added;
- the lock and the view authorizations are re-applied;
- views are replaced;
- a legacy exclusion on the sink and a legacy `ge-app-agy-prompts-audit-sink` are removed.

**Upgrading from the previous layout:** if `ge_app_agy_telemetry` still contains **tables** from an earlier version, `deploy.sh` stops and prints migration steps. Those tables may contain prompts.

### Sharing dashboards
Both datasets are owner-only by default. To share:
* **Looker Studio:** create the BigQuery data source as a project owner with **Owner's credentials**. Viewers then see the charts without BigQuery access.
* **Analysts / groups:** grant **BigQuery Data Viewer** on `ge_app_agy_telemetry` only (BigQuery console → dataset → *Sharing* → *Permissions*). RAW stays locked.
* **Local web dashboard** (`../dashboards/local-web`): run `fetch_data.sh` as a project owner.

### Terraform (`terraform/`)

> [!WARNING]
> The Terraform module has **not yet** been updated to this layout. It still deploys a single dataset that stores prompts. Use `deploy.sh` until a follow-up PR lands.

---

## Verification and Testing

### Step 1: Verify Sink Status
```bash
gcloud logging sinks describe ge-app-agy-telemetry-sink \
  --format="yaml(name,destination,writerIdentity,exclusions)"
```
`destination` should end with `/datasets/ge_app_agy_raw`, with no exclusions.

### Step 2: Trigger an Event in Antigravity
```bash
agy "Summarize the files in this directory"
```

### Step 3: Verify Tables, Views and Access
```bash
bq ls <PROJECT_ID>:ge_app_agy_raw          # 3 businessaicode_googleapis_com_* tables
bq ls <PROJECT_ID>:ge_app_agy_telemetry    # 4 v_ge_app_agy_* views, no tables
bq show --format=prettyjson <PROJECT_ID>:ge_app_agy_raw | jq '.access'
# expect: OWNER projectOwners, WRITER sink writer, 4 authorized view entries; no projectReaders/projectWriters
```
Log entries usually reach RAW within about a minute and appear in the views immediately (there's no batch job).

> [!NOTE]
> A **newly created** sink takes a few minutes to start routing. In testing, logs written in the first ~3 minutes after the sink was created were never exported, while everything after that arrived completely. Wait ~5 minutes after the first deployment before generating test traffic.

### Step 4: Run a Verification Query (Views)
```bash
bq query --use_legacy_sql=false '
SELECT window_days, active_users, inferences, trajectories, total_tokens, permission_grant_rate
FROM `<PROJECT_ID>.ge_app_agy_telemetry.v_ge_app_agy_user_summary`
WHERE scope = "all_users"
ORDER BY window_days;
'
```

### Step 4b: Inspect Prompts (Owners Only, RAW)
```bash
bq query --use_legacy_sql=false '
SELECT timestamp, labels.user_id, labels.model, m.author, m.content AS prompt_text
FROM `<PROJECT_ID>.ge_app_agy_raw.businessaicode_googleapis_com_inference_request`,
  UNNEST(jsonpayload_v1_inferencerequestlog.input.messages) m
ORDER BY timestamp DESC
LIMIT 5;
'
```

---

## Historical Log Backfill (`backfill.sh`)

Cloud Logging Log Router Sinks stream events that arrive after sink deployment; they do not export older logs retroactively.

Because Cloud Logging retains logs in the `_Default` bucket for 30 days by default, the included `backfill.sh` utility can load previous developer logs.

> [!WARNING]
> `backfill.sh` has **not yet** been updated for this layout. In this layout it must target the RAW dataset (`-d ge_app_agy_raw --exclude-prompts false`). It also has known issues: it drops token and metadata fields, and it can create duplicates when it fails partway (see the code review). Use it with care until it's fixed.

### Resiliency and Deduplication
* **Ingestion-Level Deduplication:** `backfill.sh` queries the target BigQuery table for existing `insertId` values within the time window. Any record already present in BigQuery is skipped before loading (`--skip-existing=true`), preventing duplicate insertions if re-run.
* **View-Level Deduplication:** All views use `QUALIFY ROW_NUMBER() OVER (PARTITION BY insertId, timestamp ORDER BY receiveTimestamp DESC) = 1` as a safeguard against streaming retries.

### Backfill Usage Examples

```bash
# 1. Preview backfill for the past 7 days without writing (Dry Run):
./backfill.sh --dry-run

# 2. Backfill the past 7 days into RAW with duplicate skipping:
./backfill.sh -p my-ge-project -d ge_app_agy_raw --exclude-prompts false -n 7 -y

# 3. Backfill specific date/time range:
./backfill.sh \
  -p my-ge-project -d ge_app_agy_raw --exclude-prompts false \
  --start-time="2026-08-26T00:00:00Z" \
  --end-time="2026-09-02T12:00:00Z" \
  -y

# 4. Backfill a specific stream (e.g., client telemetry only):
./backfill.sh -d ge_app_agy_raw -s client_telemetry -n 14 -y
```

### Backfill Flag Reference

| Flag | Default | Description |
| :--- | :--- | :--- |
| `-c`, `--config FILE` | `config.yaml` | Path to YAML configuration file |
| `-p`, `--project-id ID` | Active `gcloud` project | Source GCP project hosting Cloud Logging & BigQuery |
| `-d`, `--dataset-id ID` | `ge_app_agy_telemetry` | Target BigQuery dataset (**use `ge_app_agy_raw`**) |
| `-n`, `--days DAYS` | `7` | Number of lookback days (up to 30) |
| `--start-time RFC3339` | Calculated from `--days` | Custom ISO/RFC3339 start timestamp |
| `--end-time RFC3339` | Current UTC time | Custom ISO/RFC3339 end timestamp |
| `-s`, `--streams STREAM` | `all` | Target stream (`all`, `inference_response`, `client_telemetry`, `inference_request`) |
| `--skip-existing BOOL` | `true` | Drops records matching existing `insertId` in BigQuery |
| `--exclude-prompts BOOL` | `true` | Strips prompt bodies (set `false` for RAW, which keeps all fields) |
| `--dry-run` | `false` | Scans and prints record counts without loading to BigQuery |
| `-y`, `--yes` | `false` | Headless execution mode |

---

## Teardown and Cleanup

```bash
# Interactive confirmation:
./cleanup.sh

# Non-interactive teardown (sink, RAW dataset, views dataset):
./cleanup.sh -p my-ge-project -y -f

# Also remove leftovers of the earlier curation design, if you deployed it:
./cleanup.sh -p my-ge-project --clean-audit --clean-sa -y -f
```
`cleanup.sh` aborts with an error if your credentials have expired or a lookup fails. It never reports such failures as "already deleted".

---

## Next Steps: Dashboards

Once logs are streaming into `ge_app_agy_raw`:
* **Views:** see [`../views/README.md`](../views/README.md) for the catalog and sample queries.
* **Dashboards:** Looker Studio (owner's credentials) and the Local Web Dashboard (`../dashboards/local-web`). Dashboard updates for the new columns are a follow-up.
