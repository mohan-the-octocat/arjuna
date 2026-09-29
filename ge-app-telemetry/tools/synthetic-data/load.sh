#!/usr/bin/env bash
# Loads generated synthetic telemetry into BigQuery and deploys the views.
#
#   ./load.sh --project nandi-test-project-2 [--dataset ge_app_agy_telemetry]
#             [--location us-central1] [--out ./out] [--expiration-days 180]
#
# Creates the dataset and the three sink-shaped tables (schemas copied from a
# live ge-app-telemetry deployment, DAY-partitioned on `timestamp`), loads
# with WRITE_TRUNCATE (re-runs replace the data), loads the ground-truth side
# table, and deploys the repo's views. Batch loads are free; no DML is used.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VIEWS_DIR="${HERE}/../../views"
PROJECT="" DATASET="ge_app_agy_telemetry" LOCATION="us-central1"
OUT="${HERE}/out" EXPIRATION_DAYS=180

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --dataset) DATASET="$2"; shift 2 ;;
    --location) LOCATION="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --expiration-days) EXPIRATION_DAYS="$2"; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown flag $1" >&2; exit 2 ;;
  esac
done
[[ -n "$PROJECT" ]] || { echo "--project is required" >&2; exit 2; }
for f in inference_request inference_response client_telemetry ground_truth; do
  [[ -f "${OUT}/${f}.jsonl.gz" ]] || { echo "missing ${OUT}/${f}.jsonl.gz; run generate.py first" >&2; exit 1; }
done

EXPIRATION_SECS=$((EXPIRATION_DAYS * 86400))
DS="${PROJECT}:${DATASET}"

if ! bq --project_id="$PROJECT" show --dataset "$DS" >/dev/null 2>&1; then
  echo "Creating dataset ${DS} (${LOCATION})"
  bq --project_id="$PROJECT" --location="$LOCATION" mk --dataset \
    --description "Synthetic Antigravity telemetry (Cymbal demo org). Not real usage." "$DS"
fi

for t in inference_request inference_response client_telemetry; do
  table="businessaicode_googleapis_com_${t}"
  echo "Loading ${table}"
  bq --project_id="$PROJECT" --location="$LOCATION" load \
    --replace \
    --source_format=NEWLINE_DELIMITED_JSON \
    --time_partitioning_type=DAY \
    --time_partitioning_field=timestamp \
    --time_partitioning_expiration="$EXPIRATION_SECS" \
    "${DS}.${table}" "${OUT}/${t}.jsonl.gz" "${HERE}/schemas/${t}.json"
done

echo "Loading _synth_ground_truth"
bq --project_id="$PROJECT" --location="$LOCATION" load \
  --replace \
  --source_format=NEWLINE_DELIMITED_JSON \
  "${DS}._synth_ground_truth" "${OUT}/ground_truth.jsonl.gz" "${HERE}/schemas/ground_truth.json"

echo "Deploying views"
for sql in "${VIEWS_DIR}"/0*.sql; do
  echo "  $(basename "$sql")"
  sed -e "s/{{PROJECT_ID}}/${PROJECT}/g" -e "s/{{DATASET_ID}}/${DATASET}/g" "$sql" \
    | bq --project_id="$PROJECT" --location="$LOCATION" query --use_legacy_sql=false --quiet >/dev/null
done

echo "Done. Row counts:"
bq --project_id="$PROJECT" --location="$LOCATION" query --use_legacy_sql=false --format=pretty \
  "SELECT table_id, row_count, ROUND(size_bytes/1e6,1) AS mb FROM \`${PROJECT}.${DATASET}.__TABLES__\` ORDER BY table_id"
