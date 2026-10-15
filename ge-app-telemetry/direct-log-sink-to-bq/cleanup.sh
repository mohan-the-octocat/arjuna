#!/usr/bin/env bash
# ==============================================================================
# Google Antigravity (Gemini Enterprise) - Teardown / Cleanup Script
# ==============================================================================
# Safely tears down and deletes resources provisioned by deploy.sh:
# 1. Cloud Logging Router Sink (e.g., ge-app-agy-telemetry-sink)
# 2. RAW dataset (e.g., ge_app_agy_raw) and all tables (incl. prompts)
# 3. Views dataset (e.g., ge_app_agy_telemetry) and all views
# Also removes leftovers of earlier designs if present: legacy prompt audit
# sink, curation scheduled query (ge-app-agy-curation), _Default exclusion
# (agy-prompt-logs); optionally the prompts audit dataset (--clean-audit) and
# the curation service account (--clean-sa).
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
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ------------------------------------------------------------------------------
# Default Values
# ------------------------------------------------------------------------------
DEFAULT_CONFIG_FILE="config.yaml"
DEFAULT_DATASET_ID="ge_app_agy_telemetry"
DEFAULT_SINK_NAME="ge-app-agy-telemetry-sink"
DEFAULT_AUDIT_DATASET_ID="ge_app_agy_prompts_audit"
DEFAULT_AUDIT_SINK_NAME="ge-app-agy-prompts-audit-sink"
DEFAULT_LOCATION="us-central1"

DEFAULT_RAW_DATASET_ID="ge_app_agy_raw"

# Leftovers of the earlier curation design (feature/curation-strict-mode)
CURATION_SA_NAME="agy-curation"
CURATION_DISPLAY_NAME="ge-app-agy-curation"
DEFAULT_BUCKET_EXCLUSION_NAME="agy-prompt-logs"

PROJECT_ID=""
DEST_PROJECT_ID=""
DATASET_ID=""
RAW_DATASET_ID=""
DATASET_LOCATION=""
SINK_NAME=""
AUDIT_DATASET_ID=""
AUDIT_SINK_NAME=""
CLEAN_AUDIT=false
CLEAN_SA=false
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
  --dataset-id ID               Views dataset ID to remove (default: ${DEFAULT_DATASET_ID})
  --raw-dataset-id ID           RAW dataset ID to remove (default: ${DEFAULT_RAW_DATASET_ID})
  -l, --location REGION         Dataset location, used to find the scheduled query (default: ${DEFAULT_LOCATION})
  -s, --sink-name NAME          Cloud Logging sink identifier to remove (default: ${DEFAULT_SINK_NAME})
  --clean-audit                 Also delete the legacy prompts audit dataset if present
  --audit-dataset-id ID         Prompts audit dataset ID (default: ${DEFAULT_AUDIT_DATASET_ID})
  --audit-sink-name NAME        Legacy prompt audit sink identifier (default: ${DEFAULT_AUDIT_SINK_NAME})
  --clean-sa                    Also delete the legacy curation service account (${CURATION_SA_NAME}) and its project binding
  -f, --force                   Force remove datasets without prompting for tables
  -y, --yes, --headless         Non-interactive mode (skips confirmation prompts)
  -h, --help                    Display this help message and exit

Always removed: sink, RAW dataset, views dataset, and (if present) legacy audit sink,
legacy scheduled query ${CURATION_DISPLAY_NAME}, legacy _Default exclusion ${DEFAULT_BUCKET_EXCLUSION_NAME}.

Examples:
  # 1. Interactive cleanup:
  ./cleanup.sh

  # 2. Cleanup using a config file:
  ./cleanup.sh --config=config.yaml -y

  # 3. Headless full teardown (incl. prompts audit dataset and curation SA):
  ./cleanup.sh -p my-ge-project --clean-audit --clean-sa -y -f
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
      dataset_location) [[ -z "$DATASET_LOCATION" ]] && DATASET_LOCATION="$val" ;;
      sink_name) [[ -z "$SINK_NAME" ]] && SINK_NAME="$val" ;;
      audit_dataset_id) [[ -z "$AUDIT_DATASET_ID" ]] && AUDIT_DATASET_ID="$val" ;;
    esac
  done <<< "$parsed"
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

delete_dataset() {
  local ds="$1" label="$2"
  log_info "Checking ${label} dataset ${DEST_PROJECT_ID}:${ds}..."
  if dataset_exists "${ds}"; then
    log_info "Deleting ${label} dataset and all containing tables: ${DEST_PROJECT_ID}:${ds}..."
    if [[ "$FORCE" == "true" || "$HEADLESS" == "true" ]]; then
      bq rm -r -f --project_id="${DEST_PROJECT_ID}" "${ds}"
    else
      bq rm -r --project_id="${DEST_PROJECT_ID}" "${ds}"
    fi
    log_success "Deleted ${label} dataset ${DEST_PROJECT_ID}:${ds}."
  else
    log_info "${label} dataset ${ds} does not exist."
  fi
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
    --raw-dataset-id) RAW_DATASET_ID="$2"; shift 2 ;;
    -l|--location) DATASET_LOCATION="$2"; shift 2 ;;
    -s|--sink-name) SINK_NAME="$2"; shift 2 ;;
    --clean-audit) CLEAN_AUDIT=true; shift ;;
    --audit-dataset-id) AUDIT_DATASET_ID="$2"; shift 2 ;;
    --audit-sink-name) AUDIT_SINK_NAME="$2"; shift 2 ;;
    --clean-sa) CLEAN_SA=true; shift ;;
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
RAW_DATASET_ID="${RAW_DATASET_ID:-$DEFAULT_RAW_DATASET_ID}"
DATASET_LOCATION="${DATASET_LOCATION:-$DEFAULT_LOCATION}"
SINK_NAME="${SINK_NAME:-$DEFAULT_SINK_NAME}"
AUDIT_DATASET_ID="${AUDIT_DATASET_ID:-$DEFAULT_AUDIT_DATASET_ID}"
AUDIT_SINK_NAME="${AUDIT_SINK_NAME:-$DEFAULT_AUDIT_SINK_NAME}"

# Interactive prompt if not headless
if [[ "$HEADLESS" != "true" ]]; then
  echo -e "${YELLOW}${BOLD}WARNING: This operation will delete the following resources:${NC}"
  echo -e "  Cloud Logging Sink : ${BOLD}${SINK_NAME}${NC} (Project: ${PROJECT_ID})"
  echo -e "  BigQuery Datasets  : ${BOLD}${DEST_PROJECT_ID}:${RAW_DATASET_ID}${NC}, ${BOLD}${DEST_PROJECT_ID}:${DATASET_ID}${NC} (and all tables inside)"
  [[ "$CLEAN_AUDIT" == "true" ]] && echo -e "  Prompts Audit      : ${BOLD}${DEST_PROJECT_ID}:${AUDIT_DATASET_ID}${NC}"
  [[ "$CLEAN_SA" == "true" ]] && echo -e "  Service Account    : ${BOLD}${CURATION_SA_NAME}@${DEST_PROJECT_ID}.iam.gserviceaccount.com${NC}"
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
CURATION_SA_EMAIL="${CURATION_SA_NAME}@${DEST_PROJECT_ID}.iam.gserviceaccount.com"
TRANSFER_LOCATION="$(echo "${DATASET_LOCATION}" | tr '[:upper:]' '[:lower:]')"

# Fail fast on expired/missing credentials instead of misreporting "not found".
if ! auth_out=$(gcloud auth print-access-token 2>&1 > /dev/null); then
  log_error "gcloud credentials are not usable: ${auth_out}"
  log_error "Run 'gcloud auth login' and retry."
  exit 1
fi

# ------------------------------------------------------------------------------
# Step 1: Delete Cloud Logging Sink(s)
# ------------------------------------------------------------------------------
for name in "${SINK_NAME}" "${AUDIT_SINK_NAME}"; do
  log_info "Checking Cloud Logging sink ${name} in project ${PROJECT_ID}..."
  if [[ -n "$(sink_exists "${name}")" ]]; then
    log_info "Deleting Cloud Logging sink: ${name}..."
    gcloud logging sinks delete "${name}" --project="${PROJECT_ID}" --quiet
    log_success "Deleted Cloud Logging sink ${name}."
  else
    log_info "Sink ${name} does not exist."
  fi
done

# ------------------------------------------------------------------------------
# Step 2: Delete legacy curation scheduled query (if present)
# ------------------------------------------------------------------------------
log_info "Checking scheduled query ${CURATION_DISPLAY_NAME} in ${TRANSFER_LOCATION}..."
if ! transfers=$(bq ls --transfer_config --transfer_location="${TRANSFER_LOCATION}" --project_id="${DEST_PROJECT_ID}" --format=json 2>&1); then
  log_error "Could not list scheduled queries: ${transfers}"
  exit 1
fi
TRANSFER_NAMES=$(jq -r --arg n "${CURATION_DISPLAY_NAME}" '.[]? | select(.displayName == $n) | .name' <<< "${transfers:-[]}")
if [[ -n "$TRANSFER_NAMES" ]]; then
  while read -r tname; do
    [[ -z "$tname" ]] && continue
    bq rm -f --transfer_config "${tname}"
    log_success "Deleted scheduled query ${tname}."
  done <<< "$TRANSFER_NAMES"
else
  log_info "Scheduled query ${CURATION_DISPLAY_NAME} does not exist."
fi

# ------------------------------------------------------------------------------
# Step 3: Delete BigQuery Datasets
# ------------------------------------------------------------------------------
delete_dataset "${DATASET_ID}" "Views"
delete_dataset "${RAW_DATASET_ID}" "RAW"
if [[ "$CLEAN_AUDIT" == "true" ]]; then
  delete_dataset "${AUDIT_DATASET_ID}" "Prompts audit"
elif dataset_exists "${AUDIT_DATASET_ID}"; then
  log_warn "Prompts audit dataset ${AUDIT_DATASET_ID} was kept (use --clean-audit to delete it)."
fi

# ------------------------------------------------------------------------------
# Step 4: Remove legacy _Default bucket exclusion (if present)
# ------------------------------------------------------------------------------
log_info "Checking _Default sink exclusion ${DEFAULT_BUCKET_EXCLUSION_NAME}..."
if ! excl=$(gcloud logging sinks describe _Default --project="${PROJECT_ID}" --format="value(exclusions[].name)" 2>&1); then
  log_error "Could not describe the _Default sink: ${excl}"
  exit 1
fi
if tr ';' '\n' <<< "$excl" | grep -qx "${DEFAULT_BUCKET_EXCLUSION_NAME}"; then
  gcloud logging sinks update _Default --project="${PROJECT_ID}" --remove-exclusions="${DEFAULT_BUCKET_EXCLUSION_NAME}" --quiet > /dev/null
  log_success "Removed _Default exclusion ${DEFAULT_BUCKET_EXCLUSION_NAME}."
else
  log_info "_Default exclusion ${DEFAULT_BUCKET_EXCLUSION_NAME} not present."
fi

# ------------------------------------------------------------------------------
# Step 5: (Optional) Delete legacy curation service account
# ------------------------------------------------------------------------------
if [[ "$CLEAN_SA" == "true" ]]; then
  log_info "Checking curation service account ${CURATION_SA_EMAIL}..."
  if gcloud iam service-accounts describe "${CURATION_SA_EMAIL}" --project="${DEST_PROJECT_ID}" &> /dev/null; then
    gcloud projects remove-iam-policy-binding "${DEST_PROJECT_ID}" \
      --member="serviceAccount:${CURATION_SA_EMAIL}" --role="roles/bigquery.jobUser" \
      --condition=None --quiet > /dev/null 2>&1 || true
    gcloud iam service-accounts delete "${CURATION_SA_EMAIL}" --project="${DEST_PROJECT_ID}" --quiet
    log_success "Deleted service account ${CURATION_SA_EMAIL}."
  else
    log_info "Service account ${CURATION_SA_EMAIL} does not exist."
  fi
fi

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------
echo ""
echo -e "${GREEN}${BOLD}=============================================================================="
echo " Antigravity Direct Log Sink Teardown Complete! 🧹"
echo "==============================================================================${NC}"
echo -e "All requested sink and dataset assets have been removed from ${PROJECT_ID}."
echo ""
