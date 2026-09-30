#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ID="${1:?Usage: $0 <project> <dataset>}"
DATASET_ID="${2:?Usage: $0 <project> <dataset>}"

bq load \
  --project_id="${PROJECT_ID}" \
  --replace \
  --source_format=CSV \
  --skip_leading_rows=1 \
  "${PROJECT_ID}:${DATASET_ID}.ge_app_agy_rate_card" \
  "${SCRIPT_DIR}/rate_card.csv" \
  "model:STRING,usd_per_1m_tokens:FLOAT64,source:STRING"
