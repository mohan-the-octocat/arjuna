#!/usr/bin/env bash
#
# fetch_data.sh - Extract BigQuery view data to local JSON for dashboard rendering.
#
# Usage:
#   ./fetch_data.sh [PROJECT_ID] [DATASET_ID]
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${SCRIPT_DIR}/data"
mkdir -p "${DATA_DIR}"

PROJECT_ID="${1:-${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null || echo "default-project-alpha-1")}}"
DATASET_ID="${2:-${DATASET_ID:-ge_app_agy_telemetry}}"

echo "Fetching telemetry views from BigQuery: ${PROJECT_ID}:${DATASET_ID}..."

# 1. Adoption View
echo "  Querying v_ge_app_agy_adoption..."
bq query \
  --project_id="${PROJECT_ID}" \
  --use_legacy_sql=false \
  --format=json \
  --max_rows=100000 \
  "SELECT * FROM \`${PROJECT_ID}.${DATASET_ID}.v_ge_app_agy_adoption\` ORDER BY event_date ASC" \
  > "${DATA_DIR}/adoption.json"

# 2. Trust & Quality View
echo "  Querying v_ge_app_agy_trust_quality..."
bq query \
  --project_id="${PROJECT_ID}" \
  --use_legacy_sql=false \
  --format=json \
  --max_rows=100000 \
  "SELECT * FROM \`${PROJECT_ID}.${DATASET_ID}.v_ge_app_agy_trust_quality\` ORDER BY event_date ASC" \
  > "${DATA_DIR}/trust_quality.json"

# 3. Token Economics View
echo "  Querying v_ge_app_agy_token_economics..."
bq query \
  --project_id="${PROJECT_ID}" \
  --use_legacy_sql=false \
  --format=json \
  --max_rows=100000 \
  "SELECT * FROM \`${PROJECT_ID}.${DATASET_ID}.v_ge_app_agy_token_economics\` ORDER BY event_date ASC" \
  > "${DATA_DIR}/token_economics.json"

# 4. Per-user rollup (from raw tables: distinct counts are correct per user,
#    unlike summing the per-day/per-model view rows)
echo "  Querying per-user summary..."
bq query \
  --project_id="${PROJECT_ID}" \
  --use_legacy_sql=false \
  --format=json \
  --max_rows=100000 \
  "
WITH ir AS (
  SELECT timestamp,
         REGEXP_REPLACE(labels.user_id, r'^user:', '') AS user_email,
         labels.trajectory_id AS trajectory_id,
         labels.model AS model,
         labels.client_name AS client_name,
         SAFE_CAST(jsonpayload_v1_inferenceresponselog.metadata.totaltokencount AS INT64) AS tokens
  FROM \`${PROJECT_ID}.${DATASET_ID}.businessaicode_googleapis_com_inference_response\`
  WHERE timestamp IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (PARTITION BY insertId ORDER BY timestamp DESC) = 1
),
ct AS (
  SELECT REGEXP_REPLACE(labels.user_id, r'^user:', '') AS user_email,
         labels.trajectory_id AS trajectory_id,
         jsonpayload_v1_clienttelemetrylog.eventtype AS event_type
  FROM \`${PROJECT_ID}.${DATASET_ID}.businessaicode_googleapis_com_client_telemetry\`
  WHERE timestamp IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (PARTITION BY insertId ORDER BY timestamp DESC) = 1
),
irs AS (
  SELECT user_email,
         COUNT(*) AS inferences,
         COUNT(DISTINCT trajectory_id) AS trajectories,
         COUNT(DISTINCT DATE(timestamp)) AS active_days,
         SUM(COALESCE(tokens, 0)) AS total_tokens,
         MAX(tokens) AS max_tokens_in_turn,
         COUNT(DISTINCT model) AS models_used,
         APPROX_TOP_COUNT(model, 1)[OFFSET(0)].value AS top_model,
         STRING_AGG(DISTINCT client_name, ', ') AS clients,
         MIN(timestamp) AS first_seen,
         MAX(timestamp) AS last_seen
  FROM ir
  GROUP BY user_email
),
cts AS (
  SELECT user_email,
         COUNT(DISTINCT IF(event_type = 'InferenceResolved', trajectory_id, NULL)) AS resolved_trajectories,
         COUNT(DISTINCT trajectory_id) AS client_trajectories
  FROM ct
  GROUP BY user_email
)
SELECT irs.*,
       ROUND(SAFE_DIVIDE(irs.total_tokens, irs.inferences)) AS avg_tokens_per_inference,
       ROUND(SAFE_DIVIDE(irs.inferences, irs.trajectories), 1) AS inferences_per_trajectory,
       COALESCE(cts.resolved_trajectories, 0) AS resolved_trajectories,
       COALESCE(cts.client_trajectories, 0) AS client_trajectories,
       ROUND(SAFE_DIVIDE(cts.resolved_trajectories, cts.client_trajectories), 4) AS resolution_rate,
       ROUND(SAFE_DIVIDE(irs.total_tokens, SUM(irs.total_tokens) OVER ()), 4) AS token_share
FROM irs
LEFT JOIN cts USING (user_email)
ORDER BY total_tokens DESC" \
  > "${DATA_DIR}/user_summary.json"

# Combine into single bundle with metadata
TIMESTAMP_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
cat <<EOF > "${DATA_DIR}/telemetry.json"
{
  "metadata": {
    "project_id": "${PROJECT_ID}",
    "dataset_id": "${DATASET_ID}",
    "fetched_at": "${TIMESTAMP_UTC}"
  },
  "adoption": $(cat "${DATA_DIR}/adoption.json"),
  "trust_quality": $(cat "${DATA_DIR}/trust_quality.json"),
  "token_economics": $(cat "${DATA_DIR}/token_economics.json"),
  "user_summary": $(cat "${DATA_DIR}/user_summary.json")
}
EOF

echo "Telemetry data refreshed successfully at ${DATA_DIR}/telemetry.json"
