#!/usr/bin/env bash
# ==============================================================================
# Google Antigravity (Gemini Enterprise) - Analytical Views Deployer
# ==============================================================================
# Deploys standard BigQuery SQL Data Marts (Views) into ge_app_agy_telemetry:
# 1. v_ge_app_agy_adoption
# 2. v_ge_app_agy_trust_quality
# 3. v_ge_app_agy_token_economics
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

PROJECT_ID=""
DATASET_ID=""
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
  -d, --dataset-id ID           Target BigQuery dataset ID (default: ${DEFAULT_DATASET_ID})
  --impersonate-sa SA_EMAIL     Service account to impersonate
  -y, --yes, --headless         Run in non-interactive/headless mode
  -h, --help                    Display this help message and exit

Examples:
  # Deploy to active gcloud project:
  ./deploy_views.sh

  # Deploy to specific project headlessly:
  ./deploy_views.sh -p my-ge-project -d ge_app_agy_telemetry -y
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

  [[ -z "$PROJECT_ID" && -n "$parsed_project" ]] && PROJECT_ID="$parsed_project"
  [[ -z "$DATASET_ID" && -n "$parsed_dataset" ]] && DATASET_ID="$parsed_dataset"
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
log_info "Target Dataset : ${DATASET_ID}"

# Verify dataset exists
if ! bq show ${IMPERSONATE_FLAG} "${PROJECT_ID}:${DATASET_ID}" &>/dev/null; then
  log_error "BigQuery dataset ${PROJECT_ID}:${DATASET_ID} does not exist."
  log_error "Please deploy the dataset first using deploy.sh in direct-log-sink-to-bq/."
  exit 1
fi
log_success "BigQuery dataset verified: ${PROJECT_ID}:${DATASET_ID}"

VIEW_FILES=(
  "01_v_ge_app_agy_adoption.sql"
  "02_v_ge_app_agy_trust_quality.sql"
  "03_v_ge_app_agy_token_economics.sql"
)

echo "------------------------------------------------------------------------------"
echo -e "${BOLD}Deploying Views to ${PROJECT_ID}:${DATASET_ID}:${NC}"
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
    "$SQL_PATH")

  echo "$RENDERED_SQL" | bq query \
    --use_legacy_sql=false \
    ${IMPERSONATE_FLAG} >/dev/null

  log_success "Successfully deployed ${vf}!"
done

echo ""
echo -e "${GREEN}${BOLD}==============================================================================${NC}"
echo -e "${GREEN}${BOLD} All Antigravity Analytical Views Deployed Successfully! 🚀${NC}"
echo -e "${GREEN}${BOLD}==============================================================================${NC}"
echo "  1. ${PROJECT_ID}.${DATASET_ID}.v_ge_app_agy_adoption"
echo "  2. ${PROJECT_ID}.${DATASET_ID}.v_ge_app_agy_trust_quality"
echo "  3. ${PROJECT_ID}.${DATASET_ID}.v_ge_app_agy_token_economics"
echo "=============================================================================="
echo ""
