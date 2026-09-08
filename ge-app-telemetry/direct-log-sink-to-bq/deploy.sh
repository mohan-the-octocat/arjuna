#!/usr/bin/env bash
# ==============================================================================
# Google Antigravity (Gemini Enterprise) - Direct Log Sink Deployer
# ==============================================================================
# Automates the creation of:
# 1. Dedicated BigQuery Dataset (ge_app_agy_telemetry) with regional residency
#    and automated daily partition expiration.
# 2. Cloud Logging Router Sink (ge-app-agy-telemetry-sink) targeting
#    businessaicode.googleapis.com/BAICInstance with optional prompt exclusion.
# 3. IAM Permissions Handshake granting the sink writer identity dataEditor
#    access exclusively on the target dataset.
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
# Default Values (Following Antigravity Enterprise Conventions)
# ------------------------------------------------------------------------------
DEFAULT_CONFIG_FILE="config.yaml"
DEFAULT_DATASET_ID="ge_app_agy_telemetry"
DEFAULT_LOCATION="us-central1"
DEFAULT_SINK_NAME="ge-app-agy-telemetry-sink"
DEFAULT_RETENTION_DAYS="90"
DEFAULT_EXCLUDE_PROMPTS="true"
DEFAULT_FLASH_DISCOUNT="true"

PROJECT_ID=""
DEST_PROJECT_ID=""
DATASET_ID=""
DATASET_LOCATION=""
SINK_NAME=""
PARTITION_EXPIRATION_DAYS=""
EXCLUDE_PROMPT_CONTENTS=""
FLASH_DISCOUNT_APPLIED=""
DEPLOYER_SERVICE_ACCOUNT=""
CONFIG_FILE=""
HEADLESS=false

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
  echo " Google Antigravity (Gemini Enterprise) - Direct Log Sink Deployer"
  echo " Module: ge-app-telemetry / direct-log-sink-to-bq"
  echo "=============================================================================="
  echo -e "${NC}"
}

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  -c, --config FILE             Path to YAML or JSON config file (default: config.yaml if present)
  -p, --project-id ID           Source GCP Project ID where Antigravity is active
  -d, --dest-project-id ID      Destination GCP Project ID hosting BigQuery (default: same as project-id)
  --dataset-id ID               Dedicated BigQuery dataset ID (default: ${DEFAULT_DATASET_ID})
  -l, --location REGION         Dataset residency location (default: ${DEFAULT_LOCATION})
  -s, --sink-name NAME          Cloud Logging sink identifier (default: ${DEFAULT_SINK_NAME})
  -r, --retention-days DAYS     Daily partition expiration in days (default: ${DEFAULT_RETENTION_DAYS}, 0 = never)
  --exclude-prompts BOOL        Exclude raw code/prompts for privacy/ZDR (true/false, default: ${DEFAULT_EXCLUDE_PROMPTS})
  --impersonate-sa SA_EMAIL     Deployer Service Account to impersonate
  -y, --yes, --headless         Run in non-interactive/headless mode without prompts
  -h, --help                    Display this help message and exit

Examples:
  # 1. Interactive setup with smart defaults:
  ./deploy.sh

  # 2. Deploy using a configuration file:
  ./deploy.sh --config=config.example.yaml

  # 3. Headless single-command deployment:
  ./deploy.sh -p my-ge-project -l asia-northeast1 --dataset-id ge_app_agy_telemetry -y
EOF
  exit 0
}

# Parse YAML/JSON config using python3 json/yaml or fallback line-parser
load_config_file() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    return
  fi
  log_info "Loading configuration from: ${file}"

  python3 -c "
import sys, re

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
            # Only print scalar keys
            if v and not v.startswith('[') and not v.startswith('{'):
                print(f'{k}={v}')
" > /tmp/agy_parsed_config.env

  while IFS='=' read -r key val; do
    case "$key" in
      project_id) [[ -z "$PROJECT_ID" ]] && PROJECT_ID="$val" ;;
      destination_project_id) [[ -z "$DEST_PROJECT_ID" ]] && DEST_PROJECT_ID="$val" ;;
      dataset_id) [[ -z "$DATASET_ID" ]] && DATASET_ID="$val" ;;
      dataset_location) [[ -z "$DATASET_LOCATION" ]] && DATASET_LOCATION="$val" ;;
      sink_name) [[ -z "$SINK_NAME" ]] && SINK_NAME="$val" ;;
      partition_expiration_days) [[ -z "$PARTITION_EXPIRATION_DAYS" ]] && PARTITION_EXPIRATION_DAYS="$val" ;;
      exclude_prompt_contents) [[ -z "$EXCLUDE_PROMPT_CONTENTS" ]] && EXCLUDE_PROMPT_CONTENTS="$val" ;;
      flash_discount_applied) [[ -z "$FLASH_DISCOUNT_APPLIED" ]] && FLASH_DISCOUNT_APPLIED="$val" ;;
      deployer_service_account) [[ -z "$DEPLOYER_SERVICE_ACCOUNT" ]] && DEPLOYER_SERVICE_ACCOUNT="$val" ;;
    esac
  done < /tmp/agy_parsed_config.env
  rm -f /tmp/agy_parsed_config.env
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
    -l|--location) DATASET_LOCATION="$2"; shift 2 ;;
    -s|--sink-name) SINK_NAME="$2"; shift 2 ;;
    -r|--retention-days) PARTITION_EXPIRATION_DAYS="$2"; shift 2 ;;
    --exclude-prompts) EXCLUDE_PROMPT_CONTENTS="$2"; shift 2 ;;
    --impersonate-sa) DEPLOYER_SERVICE_ACCOUNT="$2"; shift 2 ;;
    -y|--yes|--headless) HEADLESS=true; shift ;;
    -h|--help) usage ;;
    *) log_error "Unknown argument: $1"; usage ;;
  esac
done

print_header

# ------------------------------------------------------------------------------
# Pre-Flight Checks
# ------------------------------------------------------------------------------
log_info "Executing pre-flight checks..."

if ! command -v gcloud &> /dev/null; then
  log_error "'gcloud' CLI is required but not installed or not in PATH."
  exit 1
fi

if ! command -v bq &> /dev/null; then
  log_error "'bq' CLI is required but not installed or not in PATH."
  exit 1
fi

# Load config file if specified or default present
if [[ -n "$CONFIG_FILE" ]]; then
  load_config_file "$CONFIG_FILE"
elif [[ -f "$DEFAULT_CONFIG_FILE" ]]; then
  load_config_file "$DEFAULT_CONFIG_FILE"
fi

# Resolve defaults and active gcloud context
ACTIVE_GCLOUD_PROJECT=$(gcloud config get-value project 2>/dev/null || echo "")
ACTIVE_GCLOUD_ACCOUNT=$(gcloud config get-value account 2>/dev/null || echo "")

PROJECT_ID="${PROJECT_ID:-$ACTIVE_GCLOUD_PROJECT}"
DEST_PROJECT_ID="${DEST_PROJECT_ID:-$PROJECT_ID}"
DATASET_ID="${DATASET_ID:-$DEFAULT_DATASET_ID}"
DATASET_LOCATION="${DATASET_LOCATION:-$DEFAULT_LOCATION}"
SINK_NAME="${SINK_NAME:-$DEFAULT_SINK_NAME}"
PARTITION_EXPIRATION_DAYS="${PARTITION_EXPIRATION_DAYS:-$DEFAULT_RETENTION_DAYS}"
EXCLUDE_PROMPT_CONTENTS="${EXCLUDE_PROMPT_CONTENTS:-$DEFAULT_EXCLUDE_PROMPTS}"

log_info "Active Account : ${ACTIVE_GCLOUD_ACCOUNT:-None}"

# ------------------------------------------------------------------------------
# Interactive Prompting (if not headless)
# ------------------------------------------------------------------------------
if [[ "$HEADLESS" != "true" ]]; then
  echo ""
  echo -e "${BOLD}Configure Deployment Parameters (Press ENTER to accept defaults):${NC}"

  read -r -p "Source GCP Project ID [${PROJECT_ID}]: " input_proj
  PROJECT_ID="${input_proj:-$PROJECT_ID}"

  read -r -p "Destination GCP Project ID [${DEST_PROJECT_ID}]: " input_dest_proj
  DEST_PROJECT_ID="${input_dest_proj:-$DEST_PROJECT_ID}"

  read -r -p "BigQuery Dataset ID [${DATASET_ID}]: " input_ds
  DATASET_ID="${input_ds:-$DATASET_ID}"

  read -r -p "Dataset Residency Location [${DATASET_LOCATION}]: " input_loc
  DATASET_LOCATION="${input_loc:-$DATASET_LOCATION}"

  read -r -p "Cloud Logging Sink Name [${SINK_NAME}]: " input_sink
  SINK_NAME="${input_sink:-$SINK_NAME}"

  read -r -p "Partition Expiration Days (0=never) [${PARTITION_EXPIRATION_DAYS}]: " input_ret
  PARTITION_EXPIRATION_DAYS="${input_ret:-$PARTITION_EXPIRATION_DAYS}"

  read -r -p "Exclude Prompts/Code (Privacy Mode) [${EXCLUDE_PROMPT_CONTENTS}]: " input_priv
  EXCLUDE_PROMPT_CONTENTS="${input_priv:-$EXCLUDE_PROMPT_CONTENTS}"

  echo ""
fi

if [[ -z "$PROJECT_ID" ]]; then
  log_error "Project ID is required. Specify with --project-id or set 'gcloud config set project <id>'."
  exit 1
fi

DEST_PROJECT_ID="${DEST_PROJECT_ID:-$PROJECT_ID}"

# Apply SA Impersonation flag if specified
GCLOUD_EXTRA_FLAGS=()
if [[ -n "$DEPLOYER_SERVICE_ACCOUNT" ]]; then
  log_info "Impersonating deployer service account: ${DEPLOYER_SERVICE_ACCOUNT}"
  GCLOUD_EXTRA_FLAGS+=(--impersonate-service-account="${DEPLOYER_SERVICE_ACCOUNT}")
fi

echo -e "${CYAN}------------------------------------------------------------------------------${NC}"
echo -e "${BOLD}Deployment Summary:${NC}"
echo -e "  Source Project     : ${BOLD}${PROJECT_ID}${NC}"
echo -e "  Destination Project: ${BOLD}${DEST_PROJECT_ID}${NC}"
echo -e "  BigQuery Dataset   : ${BOLD}${DATASET_ID}${NC} (Region: ${DATASET_LOCATION})"
echo -e "  Sink Name          : ${BOLD}${SINK_NAME}${NC}"
echo -e "  Partition Lifespan : ${BOLD}${PARTITION_EXPIRATION_DAYS} days${NC}"
echo -e "  Privacy Exclusion  : ${BOLD}${EXCLUDE_PROMPT_CONTENTS}${NC} (Exclude prompt bodies)"
echo -e "${CYAN}------------------------------------------------------------------------------${NC}"

if [[ "$HEADLESS" != "true" ]]; then
  read -r -p "Proceed with deployment? (y/N): " confirm
  if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    log_warn "Deployment cancelled by user."
    exit 0
  fi
fi

# ------------------------------------------------------------------------------
# Step 1: Ensure Required APIs are Enabled
# ------------------------------------------------------------------------------
log_info "Verifying required GCP APIs on project ${PROJECT_ID}..."
gcloud services enable logging.googleapis.com bigquery.googleapis.com \
  --project="${PROJECT_ID}" "${GCLOUD_EXTRA_FLAGS[@]}" --quiet

if [[ "$PROJECT_ID" != "$DEST_PROJECT_ID" ]]; then
  log_info "Enabling BigQuery API on destination project ${DEST_PROJECT_ID}..."
  gcloud services enable bigquery.googleapis.com \
    --project="${DEST_PROJECT_ID}" "${GCLOUD_EXTRA_FLAGS[@]}" --quiet
fi

# ------------------------------------------------------------------------------
# Step 2: Create Dedicated BigQuery Dataset
# ------------------------------------------------------------------------------
log_info "Checking if BigQuery dataset ${DEST_PROJECT_ID}:${DATASET_ID} exists..."

if bq show --project_id="${DEST_PROJECT_ID}" "${DATASET_ID}" &> /dev/null; then
  log_info "Dataset ${DATASET_ID} already exists."
else
  log_info "Creating dedicated BigQuery dataset ${DATASET_ID} in ${DATASET_LOCATION}..."
  
  EXPIRATION_SECS=$((PARTITION_EXPIRATION_DAYS * 86400))
  BQ_MK_FLAGS=(--project_id="${DEST_PROJECT_ID}" --location="${DATASET_LOCATION}" --dataset)
  BQ_MK_FLAGS+=(--description="Google Antigravity Enterprise Telemetry (Gemini Enterprise)")
  
  if [[ "$PARTITION_EXPIRATION_DAYS" -gt 0 ]]; then
    BQ_MK_FLAGS+=(--default_partition_expiration="${EXPIRATION_SECS}")
  fi

  bq mk "${BQ_MK_FLAGS[@]}" "${DATASET_ID}"
  log_success "Created dataset ${DEST_PROJECT_ID}:${DATASET_ID}"
fi

# ------------------------------------------------------------------------------
# Step 3: Create or Update Cloud Logging Router Sink
# ------------------------------------------------------------------------------
SINK_DESTINATION="bigquery.googleapis.com/projects/${DEST_PROJECT_ID}/datasets/${DATASET_ID}"
SINK_FILTER='resource.type="businessaicode.googleapis.com/BAICInstance" AND logName=~"businessaicode.googleapis.com"'

log_info "Configuring Cloud Logging Log Router Sink: ${SINK_NAME}..."

SINK_EXISTS=$(gcloud logging sinks list --project="${PROJECT_ID}" --filter="name=${SINK_NAME}" --format="value(name)" "${GCLOUD_EXTRA_FLAGS[@]}")

CREATE_OR_UPDATE_CMD=(gcloud logging sinks)
if [[ -n "$SINK_EXISTS" ]]; then
  log_info "Updating existing sink ${SINK_NAME}..."
  CREATE_OR_UPDATE_CMD+=(update "${SINK_NAME}" "${SINK_DESTINATION}")
else
  log_info "Creating new sink ${SINK_NAME}..."
  CREATE_OR_UPDATE_CMD+=(create "${SINK_NAME}" "${SINK_DESTINATION}")
fi

CREATE_OR_UPDATE_CMD+=(
  --project="${PROJECT_ID}"
  --log-filter="${SINK_FILTER}"
  --use-partitioned-tables
  --description="Routes Google Antigravity GE logs to dedicated BigQuery dataset"
  "${GCLOUD_EXTRA_FLAGS[@]}"
  --quiet
)

# Apply privacy exclusion filter if enabled
if [[ "$EXCLUDE_PROMPT_CONTENTS" == "true" ]]; then
  log_info "Applying Zero Data Retention (ZDR) privacy filter: excluding prompt/code text..."
  CREATE_OR_UPDATE_CMD+=(
    --exclusion="name=exclude-prompt-contents,description=Excludes raw prompt text and code diffs from BigQuery,filter=logName=~\"businessaicode.googleapis.com%2Finference_response\" AND jsonPayload.contents:*"
  )
fi

"${CREATE_OR_UPDATE_CMD[@]}"
log_success "Sink ${SINK_NAME} configured successfully."

# ------------------------------------------------------------------------------
# Step 4: Extract Sink Writer Identity & Grant Dataset Permissions
# ------------------------------------------------------------------------------
log_info "Extracting Sink Writer Service Identity..."
WRITER_IDENTITY=$(gcloud logging sinks describe "${SINK_NAME}" \
  --project="${PROJECT_ID}" \
  --format="value(writerIdentity)" \
  "${GCLOUD_EXTRA_FLAGS[@]}")

log_info "Sink Writer Identity: ${WRITER_IDENTITY}"

# Format for BigQuery: strip 'serviceAccount:' prefix for userByEmail
WRITER_EMAIL="${WRITER_IDENTITY#serviceAccount:}"

log_info "Granting 'roles/bigquery.dataEditor' (WRITER) on dataset ${DEST_PROJECT_ID}:${DATASET_ID} to ${WRITER_EMAIL}..."

# Retrieve current access schema and safely append the writer identity
TMP_DS_FILE=$(mktemp)
bq show --format=prettyjson "${DEST_PROJECT_ID}:${DATASET_ID}" > "$TMP_DS_FILE"

python3 -c "
import json
with open('${TMP_DS_FILE}', 'r') as f:
    data = json.load(f)
writer_sa = '${WRITER_EMAIL}'
access = data.get('access', [])
# Check if writer already has WRITER or roles/bigquery.dataEditor access
exists = any(a.get('userByEmail') == writer_sa and a.get('role') in ('WRITER', 'roles/bigquery.dataEditor') for a in access)
if not exists:
    access.append({'role': 'WRITER', 'userByEmail': writer_sa})
    data['access'] = access
    with open('${TMP_DS_FILE}', 'w') as f:
        json.dump(data, f, indent=2)
    print('UPDATED')
else:
    print('EXISTS')
" > /tmp/agy_iam_status.txt

IAM_STATUS=$(cat /tmp/agy_iam_status.txt)
rm -f /tmp/agy_iam_status.txt

if [[ "$IAM_STATUS" == "UPDATED" ]]; then
  bq update --source "$TMP_DS_FILE" "${DEST_PROJECT_ID}:${DATASET_ID}" > /dev/null
  log_success "Granted dataEditor access to ${WRITER_EMAIL}."
else
  log_info "Writer service identity already has dataEditor access on dataset."
fi
rm -f "$TMP_DS_FILE"

# ------------------------------------------------------------------------------
# Step 5: Verification & Completion
# ------------------------------------------------------------------------------
echo ""
echo -e "${GREEN}${BOLD}=============================================================================="
echo " Antigravity Direct Log Sink Deployment Completed Successfully! 🚀"
echo "==============================================================================${NC}"
echo ""
echo -e "  ${BOLD}Sink Name          :${NC} ${SINK_NAME}"
echo -e "  ${BOLD}BigQuery Dataset   :${NC} ${DEST_PROJECT_ID}:${DATASET_ID} (${DATASET_LOCATION})"
echo -e "  ${BOLD}Writer Identity    :${NC} ${WRITER_IDENTITY}"
echo -e "  ${BOLD}Retention Lifespan :${NC} ${PARTITION_EXPIRATION_DAYS} days (auto-expiring partitions)"
echo -e "  ${BOLD}Privacy Filter     :${NC} ${EXCLUDE_PROMPT_CONTENTS}"
echo ""
echo -e "${CYAN}${BOLD}Verification & Next Steps:${NC}"
echo "  1. As soon as developers execute prompts in Antigravity Hub, CLI, or IDE,"
echo "     Cloud Logging will automatically stream events to BigQuery."
echo "  2. BigQuery will auto-create the following partitioned raw tables:"
echo "       - ${DEST_PROJECT_ID}.${DATASET_ID}.businessaicode_googleapis_com_inference_response"
echo "       - ${DEST_PROJECT_ID}.${DATASET_ID}.businessaicode_googleapis_com_client_telemetry"
echo "       - ${DEST_PROJECT_ID}.${DATASET_ID}.businessaicode_googleapis_com_inference_request"
echo "  3. To verify streaming records in BigQuery, run:"
echo "       bq query --use_legacy_sql=false \\"
echo "         'SELECT timestamp, labels.user_id, labels.model, labels.client_name FROM \`${DEST_PROJECT_ID}.${DATASET_ID}.businessaicode_googleapis_com_inference_response\` LIMIT 5;'"
echo ""
