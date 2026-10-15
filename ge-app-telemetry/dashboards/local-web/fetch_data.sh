#!/usr/bin/env bash
#
# fetch_data.sh - Extract BigQuery view data to local JSON for dashboard rendering.
#
# Reads ONLY the views dataset (authorized views over the locked RAW dataset);
# no prompt text is ever fetched. Must be run by a principal that can read the
# views dataset (by default: project owners).
#
# Usage:
#   ./fetch_data.sh [PROJECT_ID] [DATASET_ID]
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${SCRIPT_DIR}/data"
mkdir -p "${DATA_DIR}"

PROJECT_ID="${1:-${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null || true)}}"
DATASET_ID="${2:-${DATASET_ID:-ge_app_agy_telemetry}}"

if [[ -z "${PROJECT_ID}" || "${PROJECT_ID}" == "(unset)" ]]; then
  echo "ERROR: no project. Usage: ./fetch_data.sh <PROJECT_ID> [DATASET_ID]" >&2
  exit 1
fi

echo "Fetching telemetry views from BigQuery: ${PROJECT_ID}:${DATASET_ID}..."

# query_view NAME SQL -> writes ${DATA_DIR}/NAME.json (fails the script on error)
query_view() {
  local name="$1" sql="$2"
  echo "  Querying ${name}..."
  bq query \
    --project_id="${PROJECT_ID}" \
    --use_legacy_sql=false \
    --format=json \
    --max_rows=1000000 \
    --quiet \
    "${sql}" > "${DATA_DIR}/${name}.json"
}

V="\`${PROJECT_ID}.${DATASET_ID}"

# Daily views (one row per day x dimensions; all retained days)
query_view adoption        "SELECT * FROM ${V}.v_ge_app_agy_adoption\` ORDER BY event_date"
query_view trust_quality   "SELECT * FROM ${V}.v_ge_app_agy_trust_quality\` ORDER BY event_date"
query_view token_economics "SELECT * FROM ${V}.v_ge_app_agy_token_economics\` ORDER BY event_date"
query_view daily_sessions  "SELECT * FROM ${V}.v_ge_app_agy_daily_sessions\` ORDER BY event_date"

# Window summaries (7d / 90d, exact distinct counts, incl. all_users / all_models rows)
query_view user_summary    "SELECT * FROM ${V}.v_ge_app_agy_user_summary\` ORDER BY window_days, scope DESC, total_tokens DESC"
query_view model_summary   "SELECT * FROM ${V}.v_ge_app_agy_model_summary\` ORDER BY window_days, scope DESC, inferences DESC"

# Combine into single bundle with metadata
TIMESTAMP_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
TMP_BUNDLE="$(mktemp)"
cat <<EOF > "${TMP_BUNDLE}"
{
  "metadata": {
    "project_id": "${PROJECT_ID}",
    "dataset_id": "${DATASET_ID}",
    "fetched_at": "${TIMESTAMP_UTC}"
  },
  "adoption": $(cat "${DATA_DIR}/adoption.json"),
  "trust_quality": $(cat "${DATA_DIR}/trust_quality.json"),
  "token_economics": $(cat "${DATA_DIR}/token_economics.json"),
  "daily_sessions": $(cat "${DATA_DIR}/daily_sessions.json"),
  "user_summary": $(cat "${DATA_DIR}/user_summary.json"),
  "model_summary": $(cat "${DATA_DIR}/model_summary.json")
}
EOF
mv "${TMP_BUNDLE}" "${DATA_DIR}/telemetry.json"

echo "Telemetry data refreshed successfully at ${DATA_DIR}/telemetry.json"
