#!/usr/bin/env bash
# ==============================================================================
# Google Antigravity (Gemini Enterprise) - Teardown / Cleanup Script
# ==============================================================================
# Safely tears down and deletes resources provisioned by deploy.sh:
# 1. Cloud Logging Router Sink (e.g., ge-app-agy-telemetry-sink)
# 2. Views dataset (e.g., ge_app_agy_telemetry) and all views
# 3. RAW dataset (e.g., ge_app_agy_raw) and all tables (incl. prompts)
# It also deletes the old prompt audit sink (ge-app-agy-prompts-audit-sink)
# from earlier versions if it still exists.
#
# Lookups that fail for reasons other than "not found" (expired credentials,
# missing permissions, API errors) abort the script instead of being reported
# as "already deleted".
# ==============================================================================

set -euo pipefail

# Color formatting
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ------------------------------------------------------------------------------
# Default Values
# ------------------------------------------------------------------------------
DEFAULT_CONFIG_FILE="config.yaml"
DEFAULT_DATASET_ID="ge_app_agy_telemetry"
DEFAULT_RAW_DATASET_ID="ge_app_agy_raw"
DEFAULT_SINK_NAME="ge-app-agy-telemetry-sink"
OLD_AUDIT_SINK_NAME="ge-app-agy-prompts-audit-sink"

PROJECT_ID=""
DEST_PROJECT_ID=""
DATASET_ID=""
RAW_DATASET_ID=""
SINK_NAME=""
CONFIG_FILE=""
HEADLESS=false
DEPLOYER_SERVICE_ACCOUNT=""

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
  echo " Module: ge-app-telemetry (Cloud Logging -> BigQuery)"
  echo "=============================================================================="
  echo -e "${NC}"
}

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  -c, --config FILE             Path to YAML or JSON config file (default: config.yaml if present)
  -p, --project-id ID           Source GCP Project ID where the sink is deployed
  -d, --dest-project-id ID      Destination GCP Project ID hosting BigQuery (default: same as project-id)
  --raw-dataset-id ID           RAW dataset to delete (default: ${DEFAULT_RAW_DATASET_ID})
  --dataset-id ID               Views dataset to delete (default: ${DEFAULT_DATASET_ID})
  -s, --sink-name NAME          Cloud Logging sink to delete (default: ${DEFAULT_SINK_NAME})
  -f, --force                   Same as --yes (kept for compatibility)
  --impersonate-sa SA_EMAIL     Service account to impersonate (all gcloud and bq calls)
  -y, --yes, --headless         Non-interactive mode (skips confirmation prompts)
  -h, --help                    Display this help message and exit

Examples:
  # 1. Interactive cleanup (asks for confirmation):
  ./cleanup.sh

  # 2. Cleanup using a config file:
  ./cleanup.sh --config=config.yaml -y

  # 3. Headless teardown:
  ./cleanup.sh -p my-ge-project -y -f
EOF
  exit 0
}

# Parse YAML config file (scalar keys only)
load_config_file() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    return 0
  fi
  log_info "Loading configuration from: ${file}"

  local parsed
  parsed=$(python3 - "$file" <<'PY'
import sys

def parse_val(v):
    v = v.strip()
    if v.startswith('"') and v.endswith('"'): return v[1:-1]
    if v.startswith("'") and v.endswith("'"): return v[1:-1]
    return v

with open(sys.argv[1], 'r') as f:
    for line in f:
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        if ':' in line:
            k, v = line.split(':', 1)
            v = parse_val(v.split(' #', 1)[0])
            if v and not v.startswith('[') and not v.startswith('{'):
                print(f'{k.strip()}={v}')
PY
)

  while IFS='=' read -r key val; do
    case "$key" in
      project_id) [[ -z "$PROJECT_ID" ]] && PROJECT_ID="$val" ;;
      destination_project_id) [[ -z "$DEST_PROJECT_ID" ]] && DEST_PROJECT_ID="$val" ;;
      dataset_id) [[ -z "$DATASET_ID" ]] && DATASET_ID="$val" ;;
      raw_dataset_id) [[ -z "$RAW_DATASET_ID" ]] && RAW_DATASET_ID="$val" ;;
      sink_name) [[ -z "$SINK_NAME" ]] && SINK_NAME="$val" ;;
      deployer_service_account) [[ -z "$DEPLOYER_SERVICE_ACCOUNT" ]] && DEPLOYER_SERVICE_ACCOUNT="$val" ;;
    esac
  done <<< "$parsed"
  return 0
}

# sink_exists NAME -> prints name if it exists; aborts on lookup errors.
sink_exists() {
  local name="$1" out
  if ! out=$(gcloud logging sinks list --project="${PROJECT_ID}" --filter="name=${name}" --format="value(name)" 2>&1); then
    log_error "Could not list Cloud Logging sinks in ${PROJECT_ID}: ${out}"
    exit 1
  fi
  echo "$out"
}

# dataset_exists DATASET -> 0 if exists, 1 if not found; aborts on other errors.
dataset_exists() {
  local ds="$1" out
  if out=$(bq show --project_id="${DEST_PROJECT_ID}" "${ds}" 2>&1); then
    return 0
  fi
  if grep -q "Not found" <<< "$out"; then
    return 1
  fi
  log_error "Could not check dataset ${DEST_PROJECT_ID}:${ds}: ${out}"
  exit 1
}

delete_sink() {
  local name="$1"
  log_info "Checking Cloud Logging sink ${name} in project ${PROJECT_ID}..."
  if [[ -n "$(sink_exists "${name}")" ]]; then
    gcloud logging sinks delete "${name}" --project="${PROJECT_ID}" --quiet
    log_success "Deleted Cloud Logging sink ${name}."
  else
    log_info "Sink ${name} does not exist."
  fi
}

delete_dataset() {
  local ds="$1" label="$2"
  log_info "Checking ${label} dataset ${DEST_PROJECT_ID}:${ds}..."
  if dataset_exists "${ds}"; then
    # Deletion was already confirmed (prompt or -y), so don't ask again per dataset.
    bq rm -r -f --project_id="${DEST_PROJECT_ID}" "${ds}"
    log_success "Deleted ${label} dataset ${DEST_PROJECT_ID}:${ds}."
  else
    log_info "${label} dataset ${ds} does not exist."
  fi
}

# ------------------------------------------------------------------------------
# Argument Parsing
# ------------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  # Accept --flag=value as well as --flag value
  if [[ "$1" == --*=* ]]; then
    set -- "${1%%=*}" "${1#*=}" "${@:2}"
  fi
  case "$1" in
    -c|--config) CONFIG_FILE="$2"; shift 2 ;;
    -p|--project-id) PROJECT_ID="$2"; shift 2 ;;
    -d|--dest-project-id) DEST_PROJECT_ID="$2"; shift 2 ;;
    --dataset-id) DATASET_ID="$2"; shift 2 ;;
    --raw-dataset-id) RAW_DATASET_ID="$2"; shift 2 ;;
    -s|--sink-name) SINK_NAME="$2"; shift 2 ;;
    -f|--force) HEADLESS=true; shift ;;
    --impersonate-sa) DEPLOYER_SERVICE_ACCOUNT="$2"; shift 2 ;;
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

if [[ -n "$DEPLOYER_SERVICE_ACCOUNT" ]]; then
  log_info "Impersonating service account: ${DEPLOYER_SERVICE_ACCOUNT}"
  export CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT="${DEPLOYER_SERVICE_ACCOUNT}"
fi

ACTIVE_GCLOUD_PROJECT=$(gcloud config get-value project 2>/dev/null || echo "")
[[ "$ACTIVE_GCLOUD_PROJECT" == "(unset)" ]] && ACTIVE_GCLOUD_PROJECT=""
# Destination follows the source project unless it was set explicitly.
DEST_EXPLICIT=false
[[ -n "$DEST_PROJECT_ID" ]] && DEST_EXPLICIT=true
PROJECT_ID="${PROJECT_ID:-$ACTIVE_GCLOUD_PROJECT}"
DEST_PROJECT_ID="${DEST_PROJECT_ID:-$PROJECT_ID}"
DATASET_ID="${DATASET_ID:-$DEFAULT_DATASET_ID}"
RAW_DATASET_ID="${RAW_DATASET_ID:-$DEFAULT_RAW_DATASET_ID}"
SINK_NAME="${SINK_NAME:-$DEFAULT_SINK_NAME}"

# Interactive prompt if not headless
if [[ "$HEADLESS" != "true" ]]; then
  echo -e "${YELLOW}${BOLD}WARNING: This operation will delete the following resources:${NC}"
  echo -e "  Cloud Logging Sink : ${BOLD}${SINK_NAME}${NC} (Project: ${PROJECT_ID})"
  echo -e "  Views dataset      : ${BOLD}${DEST_PROJECT_ID}:${DATASET_ID}${NC} (all views)"
  echo -e "  RAW dataset        : ${BOLD}${DEST_PROJECT_ID}:${RAW_DATASET_ID}${NC} (all raw logs, incl. prompts)"
  echo ""

  read -r -p "Target GCP Project ID [${PROJECT_ID}]: " input_proj
  PROJECT_ID="${input_proj:-$PROJECT_ID}"
  [[ "$DEST_EXPLICIT" == "false" ]] && DEST_PROJECT_ID="$PROJECT_ID"

  read -r -p "Destination GCP Project ID [${DEST_PROJECT_ID}]: " input_dest_proj
  DEST_PROJECT_ID="${input_dest_proj:-$DEST_PROJECT_ID}"

  read -r -p "Cloud Logging Sink Name [${SINK_NAME}]: " input_sink
  SINK_NAME="${input_sink:-$SINK_NAME}"

  read -r -p "Raw dataset ID [${RAW_DATASET_ID}]: " input_raw
  RAW_DATASET_ID="${input_raw:-$RAW_DATASET_ID}"

  read -r -p "Views dataset ID [${DATASET_ID}]: " input_ds
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

# Fail fast on expired/missing credentials instead of misreporting "not found".
if ! auth_out=$(gcloud auth print-access-token 2>&1 > /dev/null); then
  log_error "gcloud credentials are not usable: ${auth_out}"
  log_error "Run 'gcloud auth login' and retry."
  exit 1
fi

# ------------------------------------------------------------------------------
# Step 1: Delete Cloud Logging sink(s)
# ------------------------------------------------------------------------------
delete_sink "${SINK_NAME}"
if [[ -n "$(sink_exists "${OLD_AUDIT_SINK_NAME}")" ]]; then
  gcloud logging sinks delete "${OLD_AUDIT_SINK_NAME}" --project="${PROJECT_ID}" --quiet
  log_success "Deleted old prompt audit sink ${OLD_AUDIT_SINK_NAME} (from an earlier version)."
fi

# ------------------------------------------------------------------------------
# Step 2: Delete BigQuery datasets (views first, then RAW)
# ------------------------------------------------------------------------------
delete_dataset "${DATASET_ID}" "Views"
delete_dataset "${RAW_DATASET_ID}" "RAW"

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------
echo ""
echo -e "${GREEN}${BOLD}=============================================================================="
echo " Antigravity Direct Log Sink Teardown Complete! 🧹"
echo -e "==============================================================================${NC}"
echo -e "Sink removed from ${PROJECT_ID}; datasets removed from ${DEST_PROJECT_ID}."
echo ""
