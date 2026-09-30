#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ID="${1:?Usage: $0 <project> <dataset>}"
DATASET_ID="${2:?Usage: $0 <project> <dataset>}"

bash "${SCRIPT_DIR}/load_rate_card.sh" "${PROJECT_ID}" "${DATASET_ID}"

for sql_file in $(ls "${SCRIPT_DIR}"/[0-9][0-9]_*.sql | sort); do
  echo "Deploying $(basename "${sql_file}")..."
  sed -e "s/{{PROJECT_ID}}/${PROJECT_ID}/g" -e "s/{{DATASET_ID}}/${DATASET_ID}/g" "${sql_file}" \
    | bq query --project_id="${PROJECT_ID}" --use_legacy_sql=false
done
