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

command -v jq > /dev/null || { echo "ERROR: jq is required." >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${SCRIPT_DIR}/data"
mkdir -p "${DATA_DIR}"

PROJECT_ID="${1:-${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null || true)}}"
DATASET_ID="${2:-${DATASET_ID:-ge_app_agy_telemetry}}"

if [[ -z "${PROJECT_ID}" || "${PROJECT_ID}" == "(unset)" ]]; then
  echo "ERROR: no project. Usage: ./fetch_data.sh <PROJECT_ID> [DATASET_ID]" >&2
  exit 1
fi
if ! [[ "${PROJECT_ID}" =~ ^[A-Za-z0-9_.:-]+$ && "${DATASET_ID}" =~ ^[A-Za-z0-9_]+$ ]]; then
  echo "ERROR: invalid project or dataset ID: '${PROJECT_ID}' / '${DATASET_ID}'" >&2
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
  # bq prints nothing for zero rows
  [[ -s "${DATA_DIR}/${name}.json" ]] || echo '[]' > "${DATA_DIR}/${name}.json"
  local rows
  rows=$(jq 'length' "${DATA_DIR}/${name}.json")
  if [[ "$rows" -ge 1000000 ]]; then
    echo "  WARNING: ${name} hit the 1,000,000-row limit; the dashboard data is truncated." >&2
  fi
  return 0
}

V="\`${PROJECT_ID}.${DATASET_ID}"

# Daily views (one row per day x dimensions; all retained days)
query_view adoption        "SELECT * FROM ${V}.v_ge_app_agy_adoption\` ORDER BY event_date"
query_view trust_quality   "SELECT * FROM ${V}.v_ge_app_agy_trust_quality\` ORDER BY event_date"
query_view token_economics "SELECT * FROM ${V}.v_ge_app_agy_token_economics\` ORDER BY event_date"
query_view daily_sessions  "SELECT * FROM ${V}.v_ge_app_agy_daily_sessions\` ORDER BY event_date"
query_view code_citations  "SELECT * FROM ${V}.v_ge_app_agy_code_citations\` ORDER BY event_timestamp"

# Window summaries (7d / 90d, exact distinct counts, incl. all_users / all_models rows)
query_view user_summary    "SELECT * FROM ${V}.v_ge_app_agy_user_summary\` ORDER BY window_days, scope DESC, total_tokens DESC"
query_view model_summary   "SELECT * FROM ${V}.v_ge_app_agy_model_summary\` ORDER BY window_days, scope DESC, inferences DESC"

# Combine into single bundle with metadata
TIMESTAMP_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
TMP_BUNDLE="$(mktemp)"
jq -n \
  --arg project_id "${PROJECT_ID}" --arg dataset_id "${DATASET_ID}" --arg fetched_at "${TIMESTAMP_UTC}" \
  --slurpfile adoption "${DATA_DIR}/adoption.json" \
  --slurpfile trust_quality "${DATA_DIR}/trust_quality.json" \
  --slurpfile token_economics "${DATA_DIR}/token_economics.json" \
  --slurpfile daily_sessions "${DATA_DIR}/daily_sessions.json" \
  --slurpfile user_summary "${DATA_DIR}/user_summary.json" \
  --slurpfile model_summary "${DATA_DIR}/model_summary.json" \
  --slurpfile code_citations "${DATA_DIR}/code_citations.json" \
  '{metadata: {project_id: $project_id, dataset_id: $dataset_id, fetched_at: $fetched_at},
    adoption: $adoption[0], trust_quality: $trust_quality[0], token_economics: $token_economics[0],
    daily_sessions: $daily_sessions[0], user_summary: $user_summary[0], model_summary: $model_summary[0],
    code_citations: $code_citations[0]}' \
  > "${TMP_BUNDLE}"
mv "${TMP_BUNDLE}" "${DATA_DIR}/telemetry.json"

echo "Telemetry data refreshed successfully at ${DATA_DIR}/telemetry.json"
