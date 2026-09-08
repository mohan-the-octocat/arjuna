#!/usr/bin/env bash
# ==============================================================================
# Google Antigravity (Gemini Enterprise) - Teardown / Cleanup Script
# ==============================================================================
# Safely tears down and deletes resources provisioned by deploy.sh:
# 1. Cloud Logging Router Sink (e.g., ge-app-agy-telemetry-sink)
# 2. BigQuery Dataset (e.g., ge_app_agy_telemetry) and all partitioned tables
# ==============================================================================

set -euo pipefail

# Color formatting
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ------------------------------------------------------------------------------
# Default Values
# ------------------------------------------------------------------------------
DEFAULT_CONFIG_FILE="config.yaml"
DEFAULT_DATASET_ID="ge_app_agy_telemetry"
DEFAULT_SINK_NAME="ge-app-agy-telemetry-sink"

PROJECT_ID=""
DEST_PROJECT_ID=""
DATASET_ID=""
SINK_NAME=""
CONFIG_FILE=""
HEADLESS=false
FORCE=false

# ------------------------------------------------------------------------------
# Helper Functions
# ------------------------------------------------------------------------------
log_info() {
  echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
  echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $1" >&2
}

print_header() {
  echo -e "${RED}${BOLD}"
  echo "=============================================================================="
  echo " Google Antigravity (Gemini Enterprise) - Teardown / Cleanup Utility"
  echo " Module: ge-app-telemetry / direct-log-sink-to-bq"
  echo "=============================================================================="
  echo -e "${NC}"
}

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  -c, --config FILE             Path to YAML or JSON config file (default: config.yaml if present)
  -p, --project-id ID           Source GCP Project ID where sink is deployed
  -d, --dest-project-id ID      Destination GCP Project ID hosting BigQuery (default: same as project-id)
  --dataset-id ID               Dedicated BigQuery dataset ID to remove (default: ${DEFAULT_DATASET_ID})
  -s, --sink-name NAME          Cloud Logging sink identifier to remove (default: ${DEFAULT_SINK_NAME})
  -f, --force                   Force remove dataset without prompting for tables
  -y, --yes, --headless         Non-interactive mode (skips confirmation prompts)
  -h, --help                    Display this help message and exit

Examples:
  # 1. Interactive cleanup:
  ./cleanup.sh

  # 2. Cleanup using a config file:
  ./cleanup.sh --config=config.yaml -y

  # 3. Headless single-command teardown:
  ./cleanup.sh -p my-ge-project --dataset-id ge_app_agy_telemetry -y -f
EOF
  exit 0
}

# Parse YAML config file
load_config_file() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    return
  fi
  log_info "Loading configuration from: ${file}"

  python3 -c "
import sys

def parse_val(v):
    v = v.strip()
    if v.startswith('\"') and v.endswith('\"'): return v[1:-1]
    if v.startswith(\"'\") and v.endswith(\"'\"): return v[1:-1]
    return v

with open('${file}', 'r') as f:
    for line in f:
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        if ':' in line:
            parts = line.split(':', 1)
            k = parts[0].strip()
            v = parse_val(parts[1])
            if v and not v.startswith('[') and not v.startswith('{'):
                print(f'{k}={v}')
" > /tmp/agy_cleanup_config.env

  while IFS='=' read -r key val; do
    case "$key" in
      project_id) [[ -z "$PROJECT_ID" ]] && PROJECT_ID="$val" ;;
      destination_project_id) [[ -z "$DEST_PROJECT_ID" ]] && DEST_PROJECT_ID="$val" ;;
      dataset_id) [[ -z "$DATASET_ID" ]] && DATASET_ID="$val" ;;
      sink_name) [[ -z "$SINK_NAME" ]] && SINK_NAME="$val" ;;
    esac
  done < /tmp/agy_cleanup_config.env
  rm -f /tmp/agy_cleanup_config.env
}

# ------------------------------------------------------------------------------
# Argument Parsing
# ------------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--config) CONFIG_FILE="$2"; shift 2 ;;
    -p|--project-id) PROJECT_ID="$2"; shift 2 ;;
    -d|--dest-project-id) DEST_PROJECT_ID="$2"; shift 2 ;;
    --dataset-id) DATASET_ID="$2"; shift 2 ;;
    -s|--sink-name) SINK_NAME="$2"; shift 2 ;;
    -f|--force) FORCE=true; shift ;;
    -y|--yes|--headless) HEADLESS=true; shift ;;
    -h|--help) usage ;;
    *) log_error "Unknown argument: $1"; usage ;;
  esac
done

print_header

# Load config if present
if [[ -n "$CONFIG_FILE" ]]; then
  load_config_file "$CONFIG_FILE"
elif [[ -f "$DEFAULT_CONFIG_FILE" ]]; then
  load_config_file "$DEFAULT_CONFIG_FILE"
fi

ACTIVE_GCLOUD_PROJECT=$(gcloud config get-value project 2>/dev/null || echo "")
PROJECT_ID="${PROJECT_ID:-$ACTIVE_GCLOUD_PROJECT}"
DEST_PROJECT_ID="${DEST_PROJECT_ID:-$PROJECT_ID}"
DATASET_ID="${DATASET_ID:-$DEFAULT_DATASET_ID}"
SINK_NAME="${SINK_NAME:-$DEFAULT_SINK_NAME}"

# Interactive prompt if not headless
if [[ "$HEADLESS" != "true" ]]; then
  echo -e "${YELLOW}${BOLD}WARNING: This operation will delete the following resources:${NC}"
  echo -e "  Cloud Logging Sink : ${BOLD}${SINK_NAME}${NC} (Project: ${PROJECT_ID})"
  echo -e "  BigQuery Dataset   : ${BOLD}${DEST_PROJECT_ID}:${DATASET_ID}${NC} (and all streaming tables inside)"
  echo ""

  read -r -p "Target GCP Project ID [${PROJECT_ID}]: " input_proj
  PROJECT_ID="${input_proj:-$PROJECT_ID}"

  read -r -p "Destination GCP Project ID [${DEST_PROJECT_ID}]: " input_dest_proj
  DEST_PROJECT_ID="${input_dest_proj:-$DEST_PROJECT_ID}"

  read -r -p "Cloud Logging Sink Name [${SINK_NAME}]: " input_sink
  SINK_NAME="${input_sink:-$SINK_NAME}"

  read -r -p "BigQuery Dataset ID [${DATASET_ID}]: " input_ds
  DATASET_ID="${input_ds:-$DATASET_ID}"

  echo ""
  read -r -p "Are you ABSOLUTELY sure you want to delete these resources? (yes/N): " confirm
  if [[ "$confirm" != "yes" && "$confirm" != "YES" ]]; then
    log_warn "Teardown cancelled by user."
    exit 0
  fi
fi

if [[ -z "$PROJECT_ID" ]]; then
  log_error "Project ID is required. Specify with --project-id."
  exit 1
fi

DEST_PROJECT_ID="${DEST_PROJECT_ID:-$PROJECT_ID}"

# ------------------------------------------------------------------------------
# Step 1: Delete Cloud Logging Sink
# ------------------------------------------------------------------------------
log_info "Checking Cloud Logging sink ${SINK_NAME} in project ${PROJECT_ID}..."
SINK_EXISTS=$(gcloud logging sinks list --project="${PROJECT_ID}" --filter="name=${SINK_NAME}" --format="value(name)" 2>/dev/null || echo "")

if [[ -n "$SINK_EXISTS" ]]; then
  log_info "Deleting Cloud Logging sink: ${SINK_NAME}..."
  gcloud logging sinks delete "${SINK_NAME}" --project="${PROJECT_ID}" --quiet
  log_success "Deleted Cloud Logging sink ${SINK_NAME}."
else
  log_info "Sink ${SINK_NAME} does not exist or was already deleted."
fi

# ------------------------------------------------------------------------------
# Step 2: Delete BigQuery Dataset
# ------------------------------------------------------------------------------
log_info "Checking BigQuery dataset ${DEST_PROJECT_ID}:${DATASET_ID}..."

if bq show --project_id="${DEST_PROJECT_ID}" "${DATASET_ID}" &> /dev/null; then
  log_info "Deleting BigQuery dataset and all containing tables: ${DEST_PROJECT_ID}:${DATASET_ID}..."
  bq rm -r -f --project_id="${DEST_PROJECT_ID}" "${DATASET_ID}"
  log_success "Deleted BigQuery dataset ${DEST_PROJECT_ID}:${DATASET_ID}."
else
  log_info "Dataset ${DATASET_ID} does not exist or was already deleted."
fi

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------
echo ""
echo -e "${GREEN}${BOLD}=============================================================================="
echo " Antigravity Direct Log Sink Teardown Complete! 🧹"
echo "==============================================================================${NC}"
echo -e "All sink and dataset assets have been removed from ${PROJECT_ID}."
echo ""
