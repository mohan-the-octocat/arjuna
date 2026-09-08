#!/usr/bin/env bash
# ==============================================================================
# Google Antigravity (Gemini Enterprise) - Historical Log Backfill Utility
# ==============================================================================
# Backfills historical Antigravity developer telemetry from Cloud Logging into
# the dedicated BigQuery dataset (ge_app_agy_telemetry).
#
# Key Features:
# 1. Fully Parameterized: CLI flags, environment variables, or config.yaml.
# 2. Strict Deduplication: Inspects target BigQuery tables for existing insertIds
#    to prevent duplicate entries.
# 3. Privacy & ZDR: Strips prompt text and code diffs by default.
# 4. Dry Run Mode: Previews matching record counts without modifying BigQuery.
# 5. Schema Mapping: Formats JSON payloads to match native BigQuery sink schemas.
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
DEFAULT_LOOKBACK_DAYS="7"
DEFAULT_SKIP_EXISTING="true"
DEFAULT_EXCLUDE_PROMPTS="true"
DEFAULT_STREAMS="all"

PROJECT_ID=""
DATASET_ID=""
LOOKBACK_DAYS=""
START_TIME=""
END_TIME=""
STREAMS=""
SKIP_EXISTING=""
EXCLUDE_PROMPTS=""
DRY_RUN=false
HEADLESS=false
CONFIG_FILE=""
DEPLOYER_SERVICE_ACCOUNT=""

# Create secure scratch workspace with automated cleanup
SCRATCH_DIR=$(mktemp -d -t agy_backfill_XXXXXX 2>/dev/null || mktemp -d 2>/dev/null || echo "/tmp/agy_backfill_$$")
mkdir -p "$SCRATCH_DIR"
trap 'rm -rf "$SCRATCH_DIR"' EXIT INT TERM

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
  echo " Google Antigravity (Gemini Enterprise) - Historical Log Backfill Utility"
  echo " Module: ge-app-telemetry / direct-log-sink-to-bq"
  echo "=============================================================================="
  echo -e "${NC}"
}

usage() {
  cat <<HELP_EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  -c, --config FILE             Path to YAML or JSON config file (default: config.yaml if present)
  -p, --project-id ID           GCP Project ID hosting Cloud Logging and BigQuery
  -d, --dataset-id ID           Dedicated BigQuery dataset ID (default: ${DEFAULT_DATASET_ID})
  -n, --days DAYS               Number of lookback days (default: ${DEFAULT_LOOKBACK_DAYS}, max: 30)
  --start-time RFC3339          Custom start timestamp override (e.g., 2026-08-26T00:00:00Z)
  --end-time RFC3339            Custom end timestamp override (default: current UTC time)
  -s, --streams STREAM          Target streams: 'all', 'inference_response', 'client_telemetry', 'inference_request'
  --skip-existing BOOL          Query BigQuery first to drop duplicate insertIds (true/false, default: ${DEFAULT_SKIP_EXISTING})
  --exclude-prompts BOOL        Redact/exclude prompt contents for ZDR privacy (true/false, default: ${DEFAULT_EXCLUDE_PROMPTS})
  --dry-run                     Scan logs and preview record counts without writing to BigQuery
  --impersonate-sa SA_EMAIL     Deployer Service Account to impersonate
  -y, --yes, --headless         Run in non-interactive/headless mode without prompts
  -h, --help                    Display this help message and exit

Examples:
  # 1. Preview backfill for past 7 days (dry run):
  ./backfill.sh --dry-run

  # 2. Backfill past 7 days with duplicate skipping:
  ./backfill.sh -p my-ge-project -n 7 -y

  # 3. Backfill specific 2-day window for inference_response only:
  ./backfill.sh --start-time="2026-08-28T00:00:00Z" --end-time="2026-08-30T00:00:00Z" -s inference_response -y
HELP_EOF
  exit 0
}

# Parse YAML config using python3
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

try:
    with open('${file}', 'r') as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            m = re.match(r'^([a-zA-Z0-9_-]+)\s*:\s*(.*)$', line)
            if m:
                key = m.group(1)
                val = parse_val(m.group(2).split('#')[0])
                if val:
                    print(f'{key}={val}')
except Exception as e:
    sys.exit(1)
" > "${SCRATCH_DIR}/config.env" || true

  if [[ -f "${SCRATCH_DIR}/config.env" ]]; then
    while IFS='=' read -r key val; do
      case "$key" in
        project_id) [[ -z "$PROJECT_ID" ]] && PROJECT_ID="$val" ;;
        destination_project_id) [[ -z "$PROJECT_ID" ]] && PROJECT_ID="$val" ;;
        dataset_id) [[ -z "$DATASET_ID" ]] && DATASET_ID="$val" ;;
        lookback_days) [[ -z "$LOOKBACK_DAYS" ]] && LOOKBACK_DAYS="$val" ;;
        skip_existing) [[ -z "$SKIP_EXISTING" ]] && SKIP_EXISTING="$val" ;;
        exclude_prompt_contents) [[ -z "$EXCLUDE_PROMPTS" ]] && EXCLUDE_PROMPTS="$val" ;;
        deployer_service_account) [[ -z "$DEPLOYER_SERVICE_ACCOUNT" ]] && DEPLOYER_SERVICE_ACCOUNT="$val" ;;
      esac
    done < "${SCRATCH_DIR}/config.env"
  fi
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
    -n|--days|--lookback-days)
      LOOKBACK_DAYS="$2"
      shift 2
      ;;
    --days=*|--lookback-days=*)
      LOOKBACK_DAYS="${1#*=}"
      shift
      ;;
    --start-time)
      START_TIME="$2"
      shift 2
      ;;
    --start-time=*)
      START_TIME="${1#*=}"
      shift
      ;;
    --end-time)
      END_TIME="$2"
      shift 2
      ;;
    --end-time=*)
      END_TIME="${1#*=}"
      shift
      ;;
    -s|--streams|--stream)
      STREAMS="$2"
      shift 2
      ;;
    --streams=*|--stream=*)
      STREAMS="${1#*=}"
      shift
      ;;
    --skip-existing)
      SKIP_EXISTING="$2"
      shift 2
      ;;
    --skip-existing=*)
      SKIP_EXISTING="${1#*=}"
      shift
      ;;
    --exclude-prompts)
      EXCLUDE_PROMPTS="$2"
      shift 2
      ;;
    --exclude-prompts=*)
      EXCLUDE_PROMPTS="${1#*=}"
      shift
      ;;
    --dry-run)
      DRY_RUN=true
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

# ------------------------------------------------------------------------------
# Load Configuration File if present
# ------------------------------------------------------------------------------
if [[ -n "$CONFIG_FILE" ]]; then
  load_config_file "$CONFIG_FILE"
elif [[ -f "$DEFAULT_CONFIG_FILE" ]]; then
  load_config_file "$DEFAULT_CONFIG_FILE"
elif [[ -f "config.example.yaml" ]]; then
  load_config_file "config.example.yaml"
fi

# Apply fallbacks
DATASET_ID="${DATASET_ID:-$DEFAULT_DATASET_ID}"
LOOKBACK_DAYS="${LOOKBACK_DAYS:-$DEFAULT_LOOKBACK_DAYS}"
SKIP_EXISTING="${SKIP_EXISTING:-$DEFAULT_SKIP_EXISTING}"
EXCLUDE_PROMPTS="${EXCLUDE_PROMPTS:-$DEFAULT_EXCLUDE_PROMPTS}"
STREAMS="${STREAMS:-$DEFAULT_STREAMS}"

# Configure SA impersonation flags if specified
IMPERSONATE_FLAG=""
if [[ -n "$DEPLOYER_SERVICE_ACCOUNT" ]]; then
  IMPERSONATE_FLAG="--impersonate-service-account=${DEPLOYER_SERVICE_ACCOUNT}"
  log_info "Configured Service Account impersonation: ${DEPLOYER_SERVICE_ACCOUNT}"
fi

# ------------------------------------------------------------------------------
# Pre-Flight Dependency & Context Checks
# ------------------------------------------------------------------------------
print_header

log_info "Executing pre-flight checks..."

for bin in gcloud bq jq; do
  if ! command -v "$bin" &>/dev/null; then
    log_error "Missing required CLI tool: ${bin}. Please install it before running."
    exit 1
  fi
done

# Project Detection
if [[ -z "$PROJECT_ID" ]]; then
  PROJECT_ID=$(gcloud config get-value project 2>/dev/null || true)
  if [[ -z "$PROJECT_ID" || "$PROJECT_ID" == "(unset)" ]]; then
    if [[ "$HEADLESS" == true ]]; then
      log_error "No project specified and no default project configured in gcloud."
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

ACTIVE_ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -n 1 || echo "Unknown")
log_info "Active Account : ${ACTIVE_ACCOUNT}"
log_info "Target Project : ${PROJECT_ID}"

# Calculate timestamps
if [[ -z "$START_TIME" ]]; then
  START_TIME=$(date -u -d "${LOOKBACK_DAYS} days ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -v-${LOOKBACK_DAYS}d +"%Y-%m-%dT%H:%M:%SZ")
fi

if [[ -z "$END_TIME" ]]; then
  END_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
fi

# Verify BigQuery Dataset exists
log_info "Verifying BigQuery dataset ${PROJECT_ID}:${DATASET_ID} exists..."
if ! bq show ${IMPERSONATE_FLAG} "${PROJECT_ID}:${DATASET_ID}" &>/dev/null; then
  log_error "BigQuery dataset ${PROJECT_ID}:${DATASET_ID} does not exist."
  log_error "Please run deploy.sh first to initialize the dataset and sink."
  exit 1
fi
log_success "BigQuery dataset verified: ${PROJECT_ID}:${DATASET_ID}"

# ------------------------------------------------------------------------------
# Backfill Plan Summary
# ------------------------------------------------------------------------------
echo "------------------------------------------------------------------------------"
echo -e "${BOLD}Backfill Execution Plan:${NC}"
echo "  Target Project     : ${PROJECT_ID}"
echo "  BigQuery Dataset   : ${DATASET_ID}"
echo "  Start Timestamp    : ${START_TIME}"
echo "  End Timestamp      : ${END_TIME}"
echo "  Lookback Period    : ~${LOOKBACK_DAYS} days"
echo "  Target Streams     : ${STREAMS}"
echo "  Skip Existing IDs  : ${SKIP_EXISTING} (Deduplication enabled)"
echo "  Privacy Exclusion  : ${EXCLUDE_PROMPTS} (Redact prompt bodies)"
echo "  Execution Mode     : $([[ "$DRY_RUN" == true ]] && echo "DRY RUN (Preview Only)" || echo "LIVE BACKFILL")"
echo "------------------------------------------------------------------------------"

if [[ "$HEADLESS" != true && "$DRY_RUN" != true ]]; then
  echo -ne "${YELLOW}${BOLD}Proceed with backfilling records into BigQuery? [y/N]: ${NC}"
  read -r CONFIRM
  if [[ ! "$CONFIRM" =~ ^[yY]([eE][sS])?$ ]]; then
    log_warn "Backfill cancelled by user."
    exit 0
  fi
fi

# Determine target stream list
STREAM_LIST=()
if [[ "$STREAMS" == "all" ]]; then
  STREAM_LIST=("inference_response" "client_telemetry" "inference_request")
else
  IFS=',' read -ra ADDR <<< "$STREAMS"
  for s in "${ADDR[@]}"; do
    s=$(echo "$s" | tr -d ' ')
    STREAM_LIST+=("$s")
  done
fi

# ------------------------------------------------------------------------------
# Stream Processing Loop
# ------------------------------------------------------------------------------
TOTAL_FETCHED=0
TOTAL_SKIPPED=0
TOTAL_INSERTED=0

for stream in "${STREAM_LIST[@]}"; do
  TABLE_ID="businessaicode_googleapis_com_${stream}"
  log_info "=============================================================================="
  log_info "Processing Stream: ${stream} -> Table: ${TABLE_ID}"

  # Verify table exists in BigQuery
  if ! bq show ${IMPERSONATE_FLAG} "${PROJECT_ID}:${DATASET_ID}.${TABLE_ID}" &>/dev/null; then
    log_warn "Table ${TABLE_ID} does not yet exist in dataset ${DATASET_ID}."
    log_warn "Skipping ${stream}. (Table will auto-create once real-time traffic arrives)."
    continue
  fi

  # 1. Fetch Cloud Logging entries
  LOG_FILTER="resource.type=\"businessaicode.googleapis.com/BAICInstance\" AND logName=\"projects/${PROJECT_ID}/logs/businessaicode.googleapis.com%2F${stream}\" AND timestamp>=\"${START_TIME}\" AND timestamp<=\"${END_TIME}\""
  
  STREAM_RAW_JSON="${SCRATCH_DIR}/${stream}_raw.json"
  log_info "Scanning Cloud Logging for entries between ${START_TIME} and ${END_TIME}..."
  
  gcloud logging read "$LOG_FILTER" \
    --project="${PROJECT_ID}" \
    ${IMPERSONATE_FLAG} \
    --format=json > "$STREAM_RAW_JSON" 2>/dev/null || echo "[]" > "$STREAM_RAW_JSON"

  RECORD_COUNT=$(jq 'length' "$STREAM_RAW_JSON")
  TOTAL_FETCHED=$((TOTAL_FETCHED + RECORD_COUNT))
  log_info "Found ${RECORD_COUNT} entries in Cloud Logging for ${stream}."

  if [[ "$RECORD_COUNT" -eq 0 ]]; then
    log_info "No records to backfill for ${stream}."
    continue
  fi

  # 2. Deduplication Check against BigQuery
  STREAM_FILTERED_JSON="${SCRATCH_DIR}/${stream}_filtered.json"
  SKIPPED_COUNT=0
  NEW_COUNT=0

  if [[ "$SKIP_EXISTING" == "true" ]]; then
    EXISTING_IDS_FILE="${SCRATCH_DIR}/${stream}_existing_ids.txt"
    log_info "Checking target table for existing insertIds to prevent duplicates..."
    
    # Query BigQuery for existing insertIds in the target time window
    bq query \
      --use_legacy_sql=false \
      ${IMPERSONATE_FLAG} \
      --format=csv \
      "SELECT insertId FROM \`${PROJECT_ID}.${DATASET_ID}.${TABLE_ID}\` WHERE timestamp >= '${START_TIME}' AND timestamp <= '${END_TIME}'" \
      2>/dev/null | tail -n +2 | grep -v '^$' > "$EXISTING_IDS_FILE" || touch "$EXISTING_IDS_FILE"

    EXISTING_COUNT=$(wc -l < "$EXISTING_IDS_FILE" | tr -d ' ')
    log_info "Found ${EXISTING_COUNT} existing insertIds in BigQuery."

    if [[ "$EXISTING_COUNT" -gt 0 ]]; then
      # Filter out records whose insertId is already present in BigQuery
      jq --slurpfile existing <(jq -R '.' "$EXISTING_IDS_FILE") '
        ($existing | map({(.): true}) | add // {}) as $lookup |
        map(select($lookup[.insertId] | not))
      ' "$STREAM_RAW_JSON" > "$STREAM_FILTERED_JSON"
      
      NEW_COUNT=$(jq 'length' "$STREAM_FILTERED_JSON")
      SKIPPED_COUNT=$((RECORD_COUNT - NEW_COUNT))
      TOTAL_SKIPPED=$((TOTAL_SKIPPED + SKIPPED_COUNT))
      log_info "Deduplication: ${SKIPPED_COUNT} duplicate records skipped, ${NEW_COUNT} new records to insert."
    else
      cp "$STREAM_RAW_JSON" "$STREAM_FILTERED_JSON"
      NEW_COUNT="$RECORD_COUNT"
    fi
  else
    cp "$STREAM_RAW_JSON" "$STREAM_FILTERED_JSON"
    NEW_COUNT="$RECORD_COUNT"
  fi

  # 3. Dry Run Check
  if [[ "$DRY_RUN" == true ]]; then
    log_info "[DRY RUN] Would insert ${NEW_COUNT} records into ${DATASET_ID}.${TABLE_ID}."
    continue
  fi

  if [[ "$NEW_COUNT" -eq 0 ]]; then
    log_info "All ${RECORD_COUNT} records are already present in BigQuery. Nothing to load."
    continue
  fi

  # 4. Transform to BigQuery Target Schema NDJSON
  STREAM_NDJSON="${SCRATCH_DIR}/${stream}_transformed.ndjson"
  log_info "Transforming ${NEW_COUNT} records to BigQuery schema format..."

  case "$stream" in
    inference_response)
      jq -c --arg exclude "$EXCLUDE_PROMPTS" '.[] | {
        insertId: .insertId,
        logName: .logName,
        severity: .severity,
        timestamp: .timestamp,
        receiveTimestamp: .receiveTimestamp,
        resource: .resource,
        labels: .labels,
        jsonpayload_v1_inferenceresponselog: {
          _type: (.jsonPayload["@type"] // null),
          experience: (.jsonPayload.experience // null),
          metadata: {
            totaltokencount: (.jsonPayload.metadata.totalTokenCount // null)
          },
          output: (if $exclude == "true" then null else (.jsonPayload.output // null) end)
        }
      }' "$STREAM_FILTERED_JSON" > "$STREAM_NDJSON"
      ;;
    client_telemetry)
      jq -c '.[] | {
        insertId: .insertId,
        logName: .logName,
        severity: .severity,
        timestamp: .timestamp,
        receiveTimestamp: .receiveTimestamp,
        resource: .resource,
        labels: .labels,
        jsonpayload_v1_clienttelemetrylog: {
          _type: (.jsonPayload["@type"] // null),
          eventtype: (.jsonPayload.eventType // null)
        }
      }' "$STREAM_FILTERED_JSON" > "$STREAM_NDJSON"
      ;;
    inference_request)
      jq -c --arg exclude "$EXCLUDE_PROMPTS" '.[] | {
        insertId: .insertId,
        logName: .logName,
        severity: .severity,
        timestamp: .timestamp,
        receiveTimestamp: .receiveTimestamp,
        resource: .resource,
        labels: .labels,
        jsonpayload_v1_inferencerequestlog: {
          _type: (.jsonPayload["@type"] // null),
          experience: (.jsonPayload.experience // null),
          input: (if $exclude == "true" then null else (.jsonPayload.input // null) end)
        }
      }' "$STREAM_FILTERED_JSON" > "$STREAM_NDJSON"
      ;;
  esac

  # 5. Load into BigQuery
  log_info "Loading ${NEW_COUNT} records into ${PROJECT_ID}:${DATASET_ID}.${TABLE_ID}..."
  
  bq load \
    ${IMPERSONATE_FLAG} \
    --source_format=NEWLINE_DELIMITED_JSON \
    --schema_update_option=ALLOW_FIELD_ADDITION \
    "${PROJECT_ID}:${DATASET_ID}.${TABLE_ID}" \
    "$STREAM_NDJSON"

  TOTAL_INSERTED=$((TOTAL_INSERTED + NEW_COUNT))
  log_success "Loaded ${NEW_COUNT} records into ${TABLE_ID}."
done

# ------------------------------------------------------------------------------
# Final Completion Report
# ------------------------------------------------------------------------------
echo ""
echo -e "${GREEN}${BOLD}==============================================================================${NC}"
echo -e "${GREEN}${BOLD} Antigravity Historical Log Backfill Completed! 📊${NC}"
echo -e "${GREEN}${BOLD}==============================================================================${NC}"
echo "  Target Dataset     : ${PROJECT_ID}:${DATASET_ID}"
echo "  Time Window        : ${START_TIME} -> ${END_TIME}"
echo "  Total Scanned Logs : ${TOTAL_FETCHED}"
echo "  Duplicates Skipped : ${TOTAL_SKIPPED}"
if [[ "$DRY_RUN" == true ]]; then
  echo "  Mode               : DRY RUN (No records inserted)"
else
  echo "  Total Backfilled   : ${TOTAL_INSERTED}"
fi
echo "=============================================================================="
echo ""
