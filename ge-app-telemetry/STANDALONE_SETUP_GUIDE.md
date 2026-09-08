# Google Antigravity in Gemini Enterprise: Standalone Telemetry Setup Guide

This guide provides a self-contained, step-by-step manual to deploy the **Google Antigravity Telemetry and Observability Pipeline** in any Google Cloud project from scratch, without requiring access to external repositories or codebases.

---

## 1. Overview & Architecture

When developers use **Google Antigravity** (Antigravity Hub, CLI, or IDE extensions) authenticated via **Gemini Enterprise (GE)**, the backend service logs operational events to Google Cloud Logging. For background on enterprise availability, see the Google Cloud announcement: [Expanding Google Antigravity for enterprise customers](https://cloud.google.com/blog/products/ai-machine-learning/expanding-google-antigravity-for-enterprise-customers?e=48754805).

```text
┌─────────────────────────────────────────────────────────────────────────┐
│               Developer Workstations & Client Surfaces                   │
│      Antigravity Hub    │   Antigravity CLI (agy)   │   IDE Extensions   │
└────────────────────────────────────┬────────────────────────────────────┘
                                     │ (Authenticated via Gemini Enterprise)
                                     ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                     Google Cloud Logging                                │
│       Monitored Resource: businessaicode.googleapis.com/BAICInstance    │
│       Log Streams: inference_response, client_telemetry, inference_req  │
└────────────────────────────────────┬────────────────────────────────────┘
                                     │
                                     ▼ (Cloud Logging Router Sink with ZDR)
┌─────────────────────────────────────────────────────────────────────────┐
│           Dedicated BigQuery Dataset: `ge_app_agy_telemetry`           │
│   ├── Raw Partitioned Tables (Daily partitions, 90-day retention)       │
│   │   ├── businessaicode_googleapis_com_inference_response              │
│   │   ├── businessaicode_googleapis_com_client_telemetry                │
│   │   └── businessaicode_googleapis_com_inference_request               │
│   │                                                                     │
│   └── Analytical SQL Views (Data Marts with embedded deduplication)     │
│       ├── v_ge_app_agy_adoption        (DAU, sessions, inferences)      │
│       ├── v_ge_app_agy_trust_quality   (Resolutions, grants, proposals) │
│       └── v_ge_app_agy_token_economics (Tokens, list vs discounted cost)│
└────────────────────────────────────┬────────────────────────────────────┘
                                     │
                                     ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                      Visualizations & Dashboards                        │
│             Looker Studio (1-Click)  │  Custom Reporting BI             │
└─────────────────────────────────────────────────────────────────────────┘
```

### Three Observability Pillars Captured
1. **Developer Adoption:** Distinct Daily Active Users (DAU), multi-turn agent coding sessions (trajectories), total inference requests, and surface distribution (`antigravity_hub`, `antigravity_cli`, IDEs).
2. **Agent Trust & Quality:** Task resolution rates (`InferenceResolved`), developer tool permissions (accepted vs. rejected commands and filesystem actions), and code suggestion acceptance/modification rates.
3. **FinOps & Token Economics:** Input and output token volumes, average context window sizes, estimated blended list costs, 50% Flash promotional discounts, and flat-rate seat classifications (`SEAT_INCLUDED`).

---

## 2. Prerequisites & Permissions

### Required Roles
Ensure your user account or service account has the following Identity and Access Management (IAM) roles in the target Google Cloud project:
* `roles/logging.configWriter` (to create and manage Log Router sinks)
* `roles/bigquery.admin` (to create datasets, views, and grant sink permissions)
* `roles/serviceusage.serviceUsageAdmin` (if APIs are not yet enabled)

### Required CLI Tools
Install and authenticate the Google Cloud SDK:
* `gcloud` CLI
* `bq` CLI

Run initial authentication:
```bash
gcloud auth login
gcloud auth application-default login
```

Set environment variables to reuse throughout the setup:
```bash
export PROJECT_ID="YOUR_GCP_PROJECT_ID"
export REGION="us-central1"               # e.g., us-central1, europe-west1, asia-northeast1
export DATASET_ID="ge_app_agy_telemetry"
export SINK_NAME="ge-app-agy-telemetry-sink"

gcloud config set project "${PROJECT_ID}"
```

Enable required APIs:
```bash
gcloud services enable \
  logging.googleapis.com \
  bigquery.googleapis.com \
  --project="${PROJECT_ID}"
```

---

## 3. Step 1: Create the BigQuery Dataset

Create a dedicated BigQuery dataset configured with regional residency and a 90-day partition expiration lifecycle:

```bash
bq --location="${REGION}" mk \
  --dataset \
  --description="Google Antigravity developer telemetry and adoption metrics for Gemini Enterprise" \
  --default_partition_expiration=7776000 \
  "${PROJECT_ID}:${DATASET_ID}"
```

*Note: `7776000` seconds equals 90 days. BigQuery automatically drops raw partitions older than 90 days, avoiding runaway storage costs.*

---

## 4. Step 2: Create the Log Router Sink with Zero Data Retention

Google Antigravity logs are emitted under `resource.type="businessaicode.googleapis.com/BAICInstance"`.

To comply with enterprise security and Zero Data Retention (ZDR) mandates, we configure an exclusion filter that drops prompt contents and code text (`jsonPayload.contents`) while preserving all telemetry labels, user identity, token counts, and interaction outcomes.

Create the sink using `gcloud`:

```bash
gcloud logging sinks create "${SINK_NAME}" \
  "bigquery.googleapis.com/projects/${PROJECT_ID}/datasets/${DATASET_ID}" \
  --project="${PROJECT_ID}" \
  --log-filter='resource.type="businessaicode.googleapis.com/BAICInstance"' \
  --exclusion="name=exclude-prompt-contents,description='Drop raw prompt and code contents for Zero Data Retention',filter='logName=~\"/inference_response$\" AND jsonPayload.contents:*'" \
  --use-partitioned-tables \
  --description="Routes Antigravity developer logs to BigQuery with prompt payload exclusions"
```

---

## 5. Step 3: Configure IAM Permissions for the Sink

The sink generates a Google-managed writer service account. Retrieve this identity and grant it `roles/bigquery.dataEditor` on your dataset:

```bash
# 1. Retrieve the sink service account identity
WRITER_IDENTITY="$(gcloud logging sinks describe "${SINK_NAME}" \
  --project="${PROJECT_ID}" \
  --format='value(writerIdentity)')"

echo "Sink Writer Identity: ${WRITER_IDENTITY}"

# 2. Grant BigQuery Data Editor permissions on the telemetry dataset
bq add-iam-policy-binding \
  --project_id="${PROJECT_ID}" \
  --member="${WRITER_IDENTITY}" \
  --role="roles/bigquery.dataEditor" \
  "${DATASET_ID}"
```

*From this moment, all live Antigravity events will automatically stream into BigQuery within seconds.*

---

## 6. Step 4: Backfill Historical Logs (Optional)

Cloud Logging sinks only capture logs generated *after* their creation. If you already have active Antigravity users and wish to backfill historical logs (e.g., the last 7 or 30 days):

Save the following standalone script as `backfill.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="${1:-${PROJECT_ID}}"
DATASET_ID="${2:-${DATASET_ID:-ge_app_agy_telemetry}}"
DAYS="${3:-7}"

START_TIME="$(date -u -d "${DAYS} days ago" +"%Y-%m-%dT%H:%M:%SZ")"
echo "Backfilling Antigravity logs for project [${PROJECT_ID}] since ${START_TIME}..."

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

LOG_TYPES=("inference_response" "client_telemetry" "inference_request")

for LOG_TYPE in "${LOG_TYPES[@]}"; do
  TABLE_NAME="businessaicode_googleapis_com_${LOG_TYPE}"
  echo "Processing ${LOG_TYPE} -> ${TABLE_NAME}..."

  FILTER="resource.type=\"businessaicode.googleapis.com/BAICInstance\" AND logName=\"projects/${PROJECT_ID}/logs/businessaicode.googleapis.com%2F${LOG_TYPE}\" AND timestamp >= \"${START_TIME}\""

  # Read existing insertIds to prevent duplicates
  EXISTING_IDS_FILE="${TMP_DIR}/existing_${LOG_TYPE}.txt"
  bq query \
    --project_id="${PROJECT_ID}" \
    --use_legacy_sql=false \
    --format=csv \
    --max_rows=1000000 \
    "SELECT insertId FROM \`${PROJECT_ID}.${DATASET_ID}.${TABLE_NAME}\` WHERE timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL ${DAYS} DAY)" 2>/dev/null \
    | tail -n +2 > "${EXISTING_IDS_FILE}" || touch "${EXISTING_IDS_FILE}"

  RAW_JSON="${TMP_DIR}/${LOG_TYPE}_raw.json"
  gcloud logging read "${FILTER}" \
    --project="${PROJECT_ID}" \
    --format=json \
    --freshness="${DAYS}d" > "${RAW_JSON}"

  RECORDS_COUNT="$(jq 'length' "${RAW_JSON}")"
  echo "  Fetched ${RECORDS_COUNT} log entries from Cloud Logging."

  if [[ "${RECORDS_COUNT}" -eq 0 ]]; then
    continue
  fi

  TRANSFORMED_NDJSON="${TMP_DIR}/${LOG_TYPE}_insert.ndjson"
  > "${TRANSFORMED_NDJSON}"

  # Strip prompt contents (ZDR) and format for BigQuery
  jq -c --slurpfile existing "${EXISTING_IDS_FILE}" '
    ($existing[0] | split("\n") | map(select(length > 0)) | INDEX(.)) as $idx |
    .[] |
    select(.insertId as $id | ($idx | has($id)) | not) |
    if .jsonPayload.contents then del(.jsonPayload.contents) else . end
  ' "${RAW_JSON}" >> "${TRANSFORMED_NDJSON}"

  NEW_ROWS="$(wc -l < "${TRANSFORMED_NDJSON}")"
  echo "  New deduplicated rows to insert: ${NEW_ROWS}"

  if [[ "${NEW_ROWS}" -gt 0 ]]; then
    bq insert \
      --project_id="${PROJECT_ID}" \
      "${DATASET_ID}.${TABLE_NAME}" \
      "${TRANSFORMED_NDJSON}"
    echo "  Inserted ${NEW_ROWS} records into ${TABLE_NAME}."
  fi
done

echo "Backfill completed successfully."
```

Make executable and execute:
```bash
chmod +x backfill.sh
./backfill.sh "${PROJECT_ID}" "${DATASET_ID}" 7
```

---

## 7. Step 5: Deploy the Analytical SQL Data Marts (Views)

BigQuery stores raw logs with complex JSON structs. To make this data easily queryable by business users and BI tools, create the following three views.

Each view includes an automated deduplication clause:
```sql
QUALIFY ROW_NUMBER() OVER(PARTITION BY insertId ORDER BY timestamp DESC) = 1
```
This guarantees that retries, network glitches, or backfill runs never cause double-counting.

Open the **BigQuery Console** (or execute via `bq query --use_legacy_sql=false`) and run the following DDL statements:

### View 1: Developer Adoption & Usage (`v_ge_app_agy_adoption`)

```sql
CREATE OR REPLACE VIEW `YOUR_GCP_PROJECT_ID.ge_app_agy_telemetry.v_ge_app_agy_adoption` AS
WITH deduplicated_responses AS (
  SELECT
    timestamp,
    insertId,
    labels.user_id AS user_id_raw,
    labels.trajectory_id AS trajectory_id,
    labels.request_id AS request_id,
    labels.client_name AS client_name,
    labels.client_version AS client_version,
    labels.model AS model
  FROM
    `YOUR_GCP_PROJECT_ID.ge_app_agy_telemetry.businessaicode_googleapis_com_inference_response`
  WHERE
    timestamp IS NOT NULL
  QUALIFY ROW_NUMBER() OVER(PARTITION BY insertId ORDER BY timestamp DESC) = 1
),
normalized_users AS (
  SELECT
    DATE(timestamp) AS event_date,
    REGEXP_REPLACE(user_id_raw, r'^user:', '') AS user_email,
    COALESCE(client_name, 'antigravity_hub') AS client_name,
    COALESCE(client_version, 'unknown') AS client_version,
    COALESCE(model, 'unspecified') AS model,
    trajectory_id,
    request_id,
    timestamp
  FROM
    deduplicated_responses
)
SELECT
  event_date,
  user_email,
  client_name,
  client_version,
  model,
  COUNT(DISTINCT trajectory_id) AS active_trajectories,
  COUNT(request_id) AS total_inferences,
  ROUND(SAFE_DIVIDE(COUNT(request_id), COUNT(DISTINCT trajectory_id)), 2) AS inferences_per_trajectory,
  COUNT(DISTINCT EXTRACT(HOUR FROM timestamp)) AS active_hours_count,
  MIN(FORMAT_TIMESTAMP('%Y-%m-%d %H:%M:%S', timestamp)) AS first_activity_utc,
  MAX(FORMAT_TIMESTAMP('%Y-%m-%d %H:%M:%S', timestamp)) AS last_activity_utc
FROM
  normalized_users
GROUP BY
  event_date,
  user_email,
  client_name,
  client_version,
  model;
```

---

### View 2: Agent Trust, Safety & Quality (`v_ge_app_agy_trust_quality`)

```sql
CREATE OR REPLACE VIEW `YOUR_GCP_PROJECT_ID.ge_app_agy_telemetry.v_ge_app_agy_trust_quality` AS
WITH deduplicated_telemetry AS (
  SELECT
    timestamp,
    insertId,
    labels.user_id AS user_id_raw,
    labels.trajectory_id AS trajectory_id,
    labels.client_name AS client_name,
    labels.model AS model,
    jsonpayload_v1_clienttelemetrylog.telemetryType AS telemetry_type,
    jsonpayload_v1_clienttelemetrylog.interactionOutcome AS interaction_outcome,
    jsonpayload_v1_clienttelemetrylog.userFeedback AS user_feedback,
    jsonpayload_v1_clienttelemetrylog.status AS status
  FROM
    `YOUR_GCP_PROJECT_ID.ge_app_agy_telemetry.businessaicode_googleapis_com_client_telemetry`
  WHERE
    timestamp IS NOT NULL
  QUALIFY ROW_NUMBER() OVER(PARTITION BY insertId ORDER BY timestamp DESC) = 1
),
events AS (
  SELECT
    DATE(timestamp) AS event_date,
    REGEXP_REPLACE(user_id_raw, r'^user:', '') AS user_email,
    COALESCE(client_name, 'antigravity_hub') AS client_name,
    COALESCE(model, 'unspecified') AS model,
    trajectory_id,
    telemetry_type,
    interaction_outcome,
    user_feedback,
    status
  FROM
    deduplicated_telemetry
)
SELECT
  event_date,
  user_email,
  client_name,
  model,
  COUNT(DISTINCT trajectory_id) AS total_trajectories,
  COUNT(DISTINCT CASE WHEN status = 'InferenceResolved' OR interaction_outcome = 'RESOLVED' THEN trajectory_id END) AS resolved_trajectories,
  ROUND(SAFE_DIVIDE(
    COUNT(DISTINCT CASE WHEN status = 'InferenceResolved' OR interaction_outcome = 'RESOLVED' THEN trajectory_id END),
    COUNT(DISTINCT trajectory_id)
  ), 2) AS trajectory_resolution_rate,
  COUNT(CASE WHEN telemetry_type = 'PERMISSION_GRANT' THEN 1 END) AS permission_requests_total,
  COUNT(CASE WHEN telemetry_type = 'PERMISSION_GRANT' AND interaction_outcome = 'ACCEPTED' THEN 1 END) AS permission_grants_accepted,
  COUNT(CASE WHEN telemetry_type = 'PERMISSION_GRANT' AND interaction_outcome = 'REJECTED' THEN 1 END) AS permission_grants_rejected,
  ROUND(SAFE_DIVIDE(
    COUNT(CASE WHEN telemetry_type = 'PERMISSION_GRANT' AND interaction_outcome = 'ACCEPTED' THEN 1 END),
    COUNT(CASE WHEN telemetry_type = 'PERMISSION_GRANT' THEN 1 END)
  ), 2) AS permission_grant_rate,
  COUNT(CASE WHEN telemetry_type = 'PROPOSAL_ACCEPTANCE' THEN 1 END) AS proposals_total,
  COUNT(CASE WHEN telemetry_type = 'PROPOSAL_ACCEPTANCE' AND interaction_outcome = 'ACCEPTED' THEN 1 END) AS proposals_accepted,
  COUNT(CASE WHEN telemetry_type = 'PROPOSAL_ACCEPTANCE' AND interaction_outcome = 'MODIFIED' THEN 1 END) AS proposals_modified,
  COUNT(CASE WHEN telemetry_type = 'PROPOSAL_ACCEPTANCE' AND interaction_outcome = 'REJECTED' THEN 1 END) AS proposals_rejected,
  ROUND(SAFE_DIVIDE(
    COUNT(CASE WHEN telemetry_type = 'PROPOSAL_ACCEPTANCE' AND interaction_outcome = 'ACCEPTED' THEN 1 END),
    COUNT(CASE WHEN telemetry_type = 'PROPOSAL_ACCEPTANCE' THEN 1 END)
  ), 2) AS proposal_acceptance_rate,
  ROUND(SAFE_DIVIDE(
    COUNT(CASE WHEN telemetry_type = 'PROPOSAL_ACCEPTANCE' AND interaction_outcome = 'MODIFIED' THEN 1 END),
    COUNT(CASE WHEN telemetry_type = 'PROPOSAL_ACCEPTANCE' THEN 1 END)
  ), 2) AS proposal_modification_rate,
  COUNT(1) AS total_events
FROM
  events
GROUP BY
  event_date,
  user_email,
  client_name,
  model;
```

---

### View 3: Token Economics & FinOps Attribution (`v_ge_app_agy_token_economics`)

```sql
CREATE OR REPLACE VIEW `YOUR_GCP_PROJECT_ID.ge_app_agy_telemetry.v_ge_app_agy_token_economics` AS
WITH deduplicated_tokens AS (
  SELECT
    timestamp,
    insertId,
    labels.user_id AS user_id_raw,
    labels.trajectory_id AS trajectory_id,
    labels.client_name AS client_name,
    labels.model AS model,
    SAFE_CAST(jsonpayload_v1_inferenceresponselog.metadata.totalTokenCount AS INT64) AS total_token_count,
    jsonpayload_v1_inferenceresponselog.metadata.experience AS experience
  FROM
    `YOUR_GCP_PROJECT_ID.ge_app_agy_telemetry.businessaicode_googleapis_com_inference_response`
  WHERE
    timestamp IS NOT NULL
  QUALIFY ROW_NUMBER() OVER(PARTITION BY insertId ORDER BY timestamp DESC) = 1
),
normalized_tokens AS (
  SELECT
    DATE(timestamp) AS event_date,
    REGEXP_REPLACE(user_id_raw, r'^user:', '') AS user_email,
    COALESCE(client_name, 'antigravity_hub') AS client_name,
    COALESCE(model, 'unspecified') AS model,
    COALESCE(experience, 'standard') AS experience,
    trajectory_id,
    COALESCE(total_token_count, 0) AS total_token_count
  FROM
    deduplicated_tokens
)
SELECT
  event_date,
  user_email,
  client_name,
  model,
  experience,
  'SEAT_INCLUDED' AS subscription_tier_type,
  COUNT(1) AS total_inferences,
  COUNT(DISTINCT trajectory_id) AS active_trajectories,
  SUM(total_token_count) AS total_tokens,
  ROUND(SAFE_DIVIDE(SUM(total_token_count), COUNT(1)), 2) AS avg_tokens_per_inference,
  ROUND(SAFE_DIVIDE(SUM(total_token_count), NULLIF(COUNT(DISTINCT trajectory_id), 0)), 2) AS avg_tokens_per_trajectory,
  MIN(total_token_count) AS min_tokens_in_turn,
  MAX(total_token_count) AS max_tokens_in_turn,
  ROUND(SUM(total_token_count) * (0.15 / 1000000), 4) AS estimated_cost_usd_list,
  ROUND(SUM(total_token_count) * (0.075 / 1000000), 4) AS estimated_cost_usd_discounted
FROM
  normalized_tokens
GROUP BY
  event_date,
  user_email,
  client_name,
  model,
  experience;
```

---

## 8. Step 6: Visualizing the Data

### Method A: Looker Studio (1-Click Setup in Cloud Console)

1. Open the [Google Cloud BigQuery Console](https://console.cloud.google.com/bigquery).
2. In the Explorer pane, expand your project > `ge_app_agy_telemetry`.
3. Click on the view: **`v_ge_app_agy_adoption`**.
4. In the top toolbar, click **Explore data** > **Explore with Looker Studio**.
5. Looker Studio opens in a new tab with your data pre-connected.

#### Recommended Charts to Add in Looker Studio:
* **Scorecard:** Total Inferences (`SUM(total_inferences)`).
* **Scorecard:** Distinct Active Developers (`COUNT_DISTINCT(user_email)`).
* **Time Series Line Chart:**
  * Dimension: `event_date`
  * Metric: `SUM(total_inferences)`
  * Breakdown Dimension: `model`
* **Stacked Bar Chart:**
  * Dimension: `event_date`
  * Metric: `SUM(active_trajectories)`
* **Detailed Breakdown Table:**
  * Dimensions: `event_date`, `user_email`, `model`, `client_name`.
  * Metrics: `total_inferences`, `active_trajectories`, `inferences_per_trajectory`.

---

### Method B: Standalone Web / BI Reporting

If you prefer building a self-contained web dashboard (HTML/JavaScript) or exporting to tools like Grafana or Tableau:

Execute BigQuery queries using JSON output format:
```bash
bq query \
  --project_id="${PROJECT_ID}" \
  --use_legacy_sql=false \
  --format=json \
  "SELECT * FROM \`${PROJECT_ID}.${DATASET_ID}.v_ge_app_agy_adoption\` ORDER BY event_date DESC LIMIT 100"
```

---

## 9. Verification & Maintenance

### 1. Verify Pipeline Health
Run this query in BigQuery to confirm that raw events are arriving from Cloud Logging:

```sql
SELECT 
  _TABLE_SUFFIX AS table_name, 
  COUNT(1) AS record_count,
  MIN(timestamp) AS oldest_record,
  MAX(timestamp) AS newest_record
FROM 
  `YOUR_GCP_PROJECT_ID.ge_app_agy_telemetry.businessaicode_googleapis_com_*`
GROUP BY 
  table_name;
```

### 2. Verify View Output
```sql
SELECT * 
FROM `YOUR_GCP_PROJECT_ID.ge_app_agy_telemetry.v_ge_app_agy_adoption` 
ORDER BY event_date DESC 
LIMIT 10;
```

### 3. Teardown / Cleanup
If you ever need to decommission the pipeline:
```bash
# Delete the sink
gcloud logging sinks delete "${SINK_NAME}" --project="${PROJECT_ID}" --quiet

# Delete the BigQuery dataset and all tables/views
bq rm -r -f -d "${PROJECT_ID}:${DATASET_ID}"
```
