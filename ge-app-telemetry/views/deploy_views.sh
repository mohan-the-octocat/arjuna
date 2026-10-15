#!/usr/bin/env bash
# ==============================================================================
# Google Antigravity (Gemini Enterprise) - Analytical Views Deployer
# ==============================================================================
# Deploys BigQuery views into the views dataset (default: ge_app_agy_telemetry)
# as AUTHORIZED VIEWS over the locked RAW dataset (default: ge_app_agy_raw):
# 0. v_ge_app_agy_user_summary
# 1. v_ge_app_agy_adoption
# 2. v_ge_app_agy_trust_quality
# 3. v_ge_app_agy_token_economics
# 4. v_ge_app_agy_model_summary
# 5. v_ge_app_agy_daily_sessions
# Each view is added to the RAW dataset's access list (type: view) so owners of
# the views dataset can query it without direct access to RAW.
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
DEFAULT_CONFIG_FILE="../direct-log-sink-to-bq/config.yaml"
DEFAULT_DATASET_ID="ge_app_agy_telemetry"
DEFAULT_RAW_DATASET_ID="ge_app_agy_raw"

PROJECT_ID=""
DATASET_ID=""
RAW_DATASET_ID=""
CONFIG_FILE=""
DEPLOYER_SERVICE_ACCOUNT=""
HEADLESS=false

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
  echo -e "${CYAN}${BOLD}"
  echo "=============================================================================="
  echo " Google Antigravity (Gemini Enterprise) - Analytical Views Deployer"
  echo " Module: ge-app-telemetry / views"
  echo "=============================================================================="
  echo -e "${NC}"
}

usage() {
  cat <<HELP_EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  -c, --config FILE             Path to YAML config file
  -p, --project-id ID           Target GCP Project ID hosting BigQuery
  -d, --dataset-id ID           Views dataset ID (default: ${DEFAULT_DATASET_ID})
  --raw-dataset-id ID           RAW dataset the views read from (default: ${DEFAULT_RAW_DATASET_ID})
  --impersonate-sa SA_EMAIL     Service account to impersonate
  -y, --yes, --headless         Run in non-interactive/headless mode
  -h, --help                    Display this help message and exit

Examples:
  # Deploy to active gcloud project:
  ./deploy_views.sh

  # Deploy to specific project headlessly:
  ./deploy_views.sh -p my-ge-project -d ge_app_agy_telemetry --raw-dataset-id ge_app_agy_raw -y
HELP_EOF
  exit 0
}

# Parse YAML config
load_config_file() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    return
  fi
  log_info "Loading configuration from: ${file}"

  local parsed_project
  local parsed_dataset
  local parsed_raw
  parsed_project=$(python3 -c "
import sys, re
try:
    with open('${file}', 'r') as f:
        for line in f:
            m = re.match(r'^(project_id|destination_project_id)\s*:\s*[\"'\']?([^\"'\'#\s]+)', line.strip())
            if m:
                print(m.group(2))
                break
except Exception:
    pass
" 2>/dev/null || true)

  parsed_dataset=$(python3 -c "
import sys, re
try:
    with open('${file}', 'r') as f:
        for line in f:
            m = re.match(r'^dataset_id\s*:\s*[\"'\']?([^\"'\'#\s]+)', line.strip())
            if m:
                print(m.group(1))
                break
except Exception:
    pass
" 2>/dev/null || true)

  parsed_raw=$(python3 -c "
import sys, re
try:
    with open('${file}', 'r') as f:
        for line in f:
            m = re.match(r'^raw_dataset_id\s*:\s*[\"'\']?([^\"'\'#\s]+)', line.strip())
            if m:
                print(m.group(1))
                break
except Exception:
    pass
" 2>/dev/null || true)

  [[ -z "$PROJECT_ID" && -n "$parsed_project" ]] && PROJECT_ID="$parsed_project"
  [[ -z "$DATASET_ID" && -n "$parsed_dataset" ]] && DATASET_ID="$parsed_dataset"
  [[ -z "$RAW_DATASET_ID" && -n "$parsed_raw" ]] && RAW_DATASET_ID="$parsed_raw"
  return 0
}

# ------------------------------------------------------------------------------
# CLI Argument Parsing
# ------------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--config)
      CONFIG_FILE="$2"
      shift 2
      ;;
    --config=*)
      CONFIG_FILE="${1#*=}"
      shift
      ;;
    -p|--project-id|--project)
      PROJECT_ID="$2"
      shift 2
      ;;
    --project-id=*|--project=*)
      PROJECT_ID="${1#*=}"
      shift
      ;;
    -d|--dataset-id|--dataset)
      DATASET_ID="$2"
      shift 2
      ;;
    --dataset-id=*|--dataset=*)
      DATASET_ID="${1#*=}"
      shift
      ;;
    --raw-dataset-id)
      RAW_DATASET_ID="$2"
      shift 2
      ;;
    --raw-dataset-id=*)
      RAW_DATASET_ID="${1#*=}"
      shift
      ;;
    --impersonate-sa)
      DEPLOYER_SERVICE_ACCOUNT="$2"
      shift 2
      ;;
    --impersonate-sa=*)
      DEPLOYER_SERVICE_ACCOUNT="${1#*=}"
      shift
      ;;
    -y|--yes|--headless)
      HEADLESS=true
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      log_error "Unknown option: $1"
      usage
      ;;
  esac
done

# Check configs
if [[ -n "$CONFIG_FILE" ]]; then
  load_config_file "$CONFIG_FILE"
elif [[ -f "config.yaml" ]]; then
  load_config_file "config.yaml"
elif [[ -f "$DEFAULT_CONFIG_FILE" ]]; then
  load_config_file "$DEFAULT_CONFIG_FILE"
elif [[ -f "../direct-log-sink-to-bq/config.example.yaml" ]]; then
  load_config_file "../direct-log-sink-to-bq/config.example.yaml"
fi

DATASET_ID="${DATASET_ID:-$DEFAULT_DATASET_ID}"
RAW_DATASET_ID="${RAW_DATASET_ID:-$DEFAULT_RAW_DATASET_ID}"

IMPERSONATE_FLAG=""
if [[ -n "$DEPLOYER_SERVICE_ACCOUNT" ]]; then
  IMPERSONATE_FLAG="--impersonate-service-account=${DEPLOYER_SERVICE_ACCOUNT}"
  log_info "Configured Service Account impersonation: ${DEPLOYER_SERVICE_ACCOUNT}"
fi

print_header

log_info "Executing pre-flight checks..."

for bin in gcloud bq; do
  if ! command -v "$bin" &>/dev/null; then
    log_error "Missing required CLI tool: ${bin}."
    exit 1
  fi
done

if [[ -z "$PROJECT_ID" ]]; then
  PROJECT_ID=$(gcloud config get-value project 2>/dev/null || true)
  if [[ -z "$PROJECT_ID" || "$PROJECT_ID" == "(unset)" ]]; then
    if [[ "$HEADLESS" == true ]]; then
      log_error "No project specified."
      exit 1
    fi
    echo -ne "${BOLD}Enter GCP Project ID: ${NC}"
    read -r PROJECT_ID
  fi
fi

if [[ -z "$PROJECT_ID" ]]; then
  log_error "Project ID is required."
  exit 1
fi

log_info "Target Project : ${PROJECT_ID}"
log_info "Views Dataset  : ${DATASET_ID}"
log_info "RAW Dataset    : ${RAW_DATASET_ID}"

# Verify datasets exist (distinguish "not found" from auth/API errors)
for ds in "${DATASET_ID}" "${RAW_DATASET_ID}"; do
  if ! ds_out=$(bq show ${IMPERSONATE_FLAG} "${PROJECT_ID}:${ds}" 2>&1); then
    if grep -q "Not found" <<< "${ds_out}"; then
      log_error "BigQuery dataset ${PROJECT_ID}:${ds} does not exist."
      log_error "Please deploy the datasets first using deploy.sh in direct-log-sink-to-bq/."
    else
      log_error "Could not check dataset ${PROJECT_ID}:${ds}: ${ds_out}"
      log_error "Check your gcloud credentials ('gcloud auth login') and permissions."
    fi
    exit 1
  fi
done
log_success "BigQuery datasets verified: ${DATASET_ID}, ${RAW_DATASET_ID}"

VIEW_FILES=(
  "00_v_ge_app_agy_user_summary.sql"
  "01_v_ge_app_agy_adoption.sql"
  "02_v_ge_app_agy_trust_quality.sql"
  "03_v_ge_app_agy_token_economics.sql"
  "04_v_ge_app_agy_model_summary.sql"
  "05_v_ge_app_agy_daily_sessions.sql"
)
VIEW_NAMES=()

echo "------------------------------------------------------------------------------"
echo -e "${BOLD}Deploying Views to ${PROJECT_ID}:${DATASET_ID} (reading ${RAW_DATASET_ID}):${NC}"
for vf in "${VIEW_FILES[@]}"; do
  echo "  - ${vf}"
done
echo "------------------------------------------------------------------------------"

if [[ "$HEADLESS" != true ]]; then
  echo -ne "${YELLOW}${BOLD}Proceed with deploying views? [y/N]: ${NC}"
  read -r CONFIRM
  if [[ ! "$CONFIRM" =~ ^[yY]([eE][sS])?$ ]]; then
    log_warn "Deployment cancelled by user."
    exit 0
  fi
fi

# Deploy each view
for vf in "${VIEW_FILES[@]}"; do
  SQL_PATH="${SCRIPT_DIR}/${vf}"
  if [[ ! -f "$SQL_PATH" ]]; then
    log_error "Missing SQL file: ${SQL_PATH}"
    exit 1
  fi

  log_info "Deploying: ${vf}..."
  
  # Substitute placeholders
  RENDERED_SQL=$(sed \
    -e "s/{{PROJECT_ID}}/${PROJECT_ID}/g" \
    -e "s/{{DATASET_ID}}/${DATASET_ID}/g" \
    -e "s/{{RAW_DATASET_ID}}/${RAW_DATASET_ID}/g" \
    "$SQL_PATH")

  echo "$RENDERED_SQL" | bq query \
    --project_id="${PROJECT_ID}" \
    --use_legacy_sql=false \
    ${IMPERSONATE_FLAG} >/dev/null

  view_name="$(basename "${vf}" .sql)"
  VIEW_NAMES+=("${view_name#[0-9][0-9]_}")
  log_success "Successfully deployed ${vf}!"
done

# ------------------------------------------------------------------------------
# Authorize the views on the RAW dataset (dataset access entries of type "view")
# ------------------------------------------------------------------------------
log_info "Authorizing views on ${RAW_DATASET_ID}..."
TMP_RAW_ACL=$(mktemp)
bq show ${IMPERSONATE_FLAG} --format=prettyjson "${PROJECT_ID}:${RAW_DATASET_ID}" > "${TMP_RAW_ACL}"
AUTH_STATUS=$(python3 - "${TMP_RAW_ACL}" "${PROJECT_ID}" "${DATASET_ID}" "${VIEW_NAMES[@]}" <<'PY'
import json, sys
path, project, dataset, *views = sys.argv[1:]
data = json.load(open(path))
access = data.setdefault('access', [])
existing = {(a['view']['projectId'], a['view']['datasetId'], a['view']['tableId'])
            for a in access if 'view' in a}
added = 0
for v in views:
    key = (project, dataset, v)
    if key not in existing:
        access.append({'view': {'projectId': project, 'datasetId': dataset, 'tableId': v}})
        added += 1
if added:
    json.dump(data, open(path, 'w'), indent=2)
print(added)
PY
)
if [[ "${AUTH_STATUS}" != "0" ]]; then
  bq update ${IMPERSONATE_FLAG} --source "${TMP_RAW_ACL}" "${PROJECT_ID}:${RAW_DATASET_ID}" > /dev/null
  log_success "Authorized ${AUTH_STATUS} view(s) on ${RAW_DATASET_ID}."
else
  log_info "All views already authorized on ${RAW_DATASET_ID}."
fi
rm -f "${TMP_RAW_ACL}"

echo ""
echo -e "${GREEN}${BOLD}==============================================================================${NC}"
echo -e "${GREEN}${BOLD} All Antigravity Analytical Views Deployed Successfully! 🚀${NC}"
echo -e "${GREEN}${BOLD}==============================================================================${NC}"
for v in "${VIEW_NAMES[@]}"; do
  echo "  - ${PROJECT_ID}.${DATASET_ID}.${v}"
done
echo "  (authorized views over ${PROJECT_ID}.${RAW_DATASET_ID}; no prompt text)"
echo "=============================================================================="
echo ""
