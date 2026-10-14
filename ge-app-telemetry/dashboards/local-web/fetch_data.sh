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

# 4. Per-user rollup (v_ge_app_agy_user_summary: rolling 90-day window, one row per user)
echo "  Querying v_ge_app_agy_user_summary (90d, per user)..."
bq query \
  --project_id="${PROJECT_ID}" \
  --use_legacy_sql=false \
  --format=json \
  --max_rows=100000 \
  "SELECT * FROM \`${PROJECT_ID}.${DATASET_ID}.v_ge_app_agy_user_summary\` WHERE window_days = 90 AND scope = 'user' ORDER BY total_tokens DESC" \
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
