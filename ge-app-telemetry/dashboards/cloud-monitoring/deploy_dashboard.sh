#!/usr/bin/env bash
#
# deploy_dashboard.sh - Deploy or update the Google Cloud Monitoring dashboard
# for Google Antigravity developer telemetry and adoption metrics.
#
# Usage:
#   ./deploy_dashboard.sh [OPTIONS]
#
# Options:
#   -p, --project PROJECT_ID   Google Cloud Project ID (default: gcloud config project or PROJECT_ID env)
#   -d, --dataset DATASET_ID   BigQuery Dataset ID (default: DATASET_ID env or ge_app_agy_telemetry)
#       --validate-only        Validate configuration against Cloud Monitoring API without deploying
#   -h, --help                 Show this help message and exit
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_FILE="${SCRIPT_DIR}/ge_app_agy_dashboard.json.template"
DISPLAY_NAME="Google Antigravity - Developer Telemetry & Adoption"

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null || true)}"
DATASET_ID="${DATASET_ID:-ge_app_agy_telemetry}"
VALIDATE_ONLY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--project)
      PROJECT_ID="$2"
      shift 2
      ;;
    -d|--dataset)
      DATASET_ID="$2"
      shift 2
      ;;
    --validate-only)
      VALIDATE_ONLY=true
      shift
      ;;
    -h|--help)
      grep '^#' "$0" | cut -c 4-
      exit 0
      ;;
    *)
      echo "Error: Unknown argument '$1'" >&2
      exit 1
      ;;
  esac
done

if [[ -z "${PROJECT_ID}" ]]; then
  echo "Error: PROJECT_ID could not be determined. Please specify with -p <PROJECT_ID> or set PROJECT_ID environment variable." >&2
  exit 1
fi

if [[ ! -f "${TEMPLATE_FILE}" ]]; then
  echo "Error: Dashboard template file not found at ${TEMPLATE_FILE}" >&2
  exit 1
fi

RENDERED_FILE="$(mktemp /tmp/ge_app_agy_dashboard_XXXXXX.json)"
trap 'rm -f "${RENDERED_FILE}"' EXIT

# Render template with project and dataset substitutions
sed \
  -e "s|\${PROJECT_ID}|${PROJECT_ID}|g" \
  -e "s|\${DATASET_ID}|${DATASET_ID}|g" \
  "${TEMPLATE_FILE}" > "${RENDERED_FILE}"

if [[ "${VALIDATE_ONLY}" == "true" ]]; then
  echo "Validating dashboard configuration for project [${PROJECT_ID}]..."
  gcloud monitoring dashboards create \
    --project="${PROJECT_ID}" \
    --config-from-file="${RENDERED_FILE}" \
    --validate-only
  echo "Dashboard configuration is valid."
  exit 0
fi

# Check for existing dashboard with same display name to maintain idempotency
EXISTING_DASHBOARD_ID="$(gcloud monitoring dashboards list \
  --project="${PROJECT_ID}" \
  --filter="displayName='${DISPLAY_NAME}'" \
  --format="value(name)" 2>/dev/null | head -n 1 | awk -F'/' '{print $NF}' || true)"

if [[ -n "${EXISTING_DASHBOARD_ID}" ]]; then
  echo "Updating existing dashboard [${EXISTING_DASHBOARD_ID}]..."
  ETAG="$(gcloud monitoring dashboards describe "${EXISTING_DASHBOARD_ID}" \
    --project="${PROJECT_ID}" \
    --format="value(etag)" 2>/dev/null || true)"
  if [[ -n "${ETAG}" ]]; then
    jq --arg etag "${ETAG}" '. + {etag: $etag}' "${RENDERED_FILE}" > "${RENDERED_FILE}.tmp" && mv "${RENDERED_FILE}.tmp" "${RENDERED_FILE}"
  fi
  gcloud monitoring dashboards update "${EXISTING_DASHBOARD_ID}" \
    --project="${PROJECT_ID}" \
    --config-from-file="${RENDERED_FILE}" >/dev/null
  DASHBOARD_ID="${EXISTING_DASHBOARD_ID}"
  echo "Dashboard updated successfully."
else
  echo "Creating new dashboard..."
  CREATE_OUTPUT="$(gcloud monitoring dashboards create \
    --project="${PROJECT_ID}" \
    --config-from-file="${RENDERED_FILE}" \
    --format="value(name)")"
  DASHBOARD_ID="$(echo "${CREATE_OUTPUT}" | awk -F'/' '{print $NF}')"
  echo "Dashboard created successfully."
fi

CONSOLE_URL="https://console.cloud.google.com/monitoring/dashboards/builder/${DASHBOARD_ID}?project=${PROJECT_ID}"

echo ""
echo "=== Deployment Summary ==="
echo "Dashboard Display Name: ${DISPLAY_NAME}"
echo "Dashboard ID:           ${DASHBOARD_ID}"
echo "Project ID:             ${PROJECT_ID}"
echo "BigQuery Dataset:       ${DATASET_ID}"
echo "Direct Console URL:     ${CONSOLE_URL}"
echo "=========================="
