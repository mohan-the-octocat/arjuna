#!/usr/bin/env bash
# ==============================================================================
# run.sh - End-to-end view validation on SYNTHETIC data.
# ==============================================================================
# 1. Generates synthetic Antigravity logs + independent ground truth (generate.py)
# 2. Loads them into isolated datasets <RAW>_synth / <VIEWS>_synth
# 3. Deploys all views on top (views/deploy_views.sh)
# 4. Compares every view against the ground truth (validate.py)
# 5. Deletes the synthetic datasets unless --keep is given
#
# Usage: ./run.sh -p <PROJECT_ID> [-l us-central1] [--keep]
# Requires: gcloud/bq authenticated, python3 (stdlib only), jq.
# Real datasets are never touched.
# ==============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${HERE}/../.."
PROJECT=""; LOCATION="us-central1"; KEEP=false
RAW="ge_app_agy_raw_synth"; VIEWS="ge_app_agy_telemetry_synth"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--project-id) PROJECT="$2"; shift 2 ;;
    -l|--location) LOCATION="$2"; shift 2 ;;
    --keep) KEEP=true; shift ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done
[[ -z "$PROJECT" ]] && { echo "ERROR: -p <PROJECT_ID> is required" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

echo "== 1. Generating synthetic data"
python3 "${HERE}/generate.py" "${WORK}"

echo "== 2. Loading into ${PROJECT}:${RAW}"
for ds in "$RAW" "$VIEWS"; do
  if bq show --project_id="$PROJECT" "$ds" >/dev/null 2>&1; then bq rm -r -f --project_id="$PROJECT" "$ds"; fi
  bq mk --project_id="$PROJECT" --location="$LOCATION" --dataset \
    --description="SYNTHETIC view-validation data (safe to delete)" "$ds" >/dev/null
done
for t in inference_request inference_response client_telemetry; do
  bq mk --table --schema="${REPO}/schemas/raw/${t}.json" --time_partitioning_field=timestamp --time_partitioning_type=DAY \
    "${PROJECT}:${RAW}.businessaicode_googleapis_com_${t}" >/dev/null
  bq load --quiet --project_id="$PROJECT" --source_format=NEWLINE_DELIMITED_JSON \
    "${PROJECT}:${RAW}.businessaicode_googleapis_com_${t}" "${WORK}/${t}.ndjson" >/dev/null
done

echo "== 3. Deploying views into ${PROJECT}:${VIEWS}"
( cd "${REPO}/views" && bash ./deploy_views.sh -p "$PROJECT" -d "$VIEWS" --raw-dataset-id "$RAW" -y >/dev/null )

echo "== 4. Validating views against ground truth"
rc=0
python3 "${HERE}/validate.py" "${WORK}/ground_truth.json" "$PROJECT" "$VIEWS" || rc=$?

if [[ "$KEEP" == "true" ]]; then
  echo "== 5. Keeping ${RAW} / ${VIEWS} (--keep). Delete later with: bq rm -r -f ${PROJECT}:${RAW}; bq rm -r -f ${PROJECT}:${VIEWS}"
else
  echo "== 5. Deleting synthetic datasets"
  bq rm -r -f --project_id="$PROJECT" "$VIEWS"
  bq rm -r -f --project_id="$PROJECT" "$RAW"
fi
exit $rc
