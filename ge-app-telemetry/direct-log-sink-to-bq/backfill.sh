#!/usr/bin/env bash
# ==============================================================================
# Google Antigravity (Gemini Enterprise) - Historical Log Backfill Utility
# ==============================================================================
# Copies Antigravity log entries that are still in Cloud Logging (for example,
# logs written before the sink existed, or in the first minutes after it was
# created) into the RAW dataset (default: ge_app_agy_raw).
#
# - Loads into the same RAW tables the sink writes to, with the same fields, so
#   the views in ge_app_agy_telemetry pick the rows up immediately.
# - Each entry is mapped onto the live RAW table schema (sink naming rules:
#   field names matched case-insensitively, '@type' -> '_type'). Fields the
#   table does not have are dropped and reported.
# - Skips entries whose insertId is already in RAW (on by default).
# - --dry-run shows the counts without writing anything.
#
# Requires: gcloud, bq, jq, python3. Run deploy.sh first (it creates RAW and
# its tables). RAW is owners-only, so run this as a project owner.
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
DEFAULT_RAW_DATASET_ID="ge_app_agy_raw"
DEFAULT_LOOKBACK_DAYS="7"
DEFAULT_SKIP_EXISTING="true"
DEFAULT_STREAMS="all"
ALL_STREAMS=(inference_response client_telemetry inference_request)
TABLE_PREFIX="businessaicode_googleapis_com_"

PROJECT_ID=""
DEST_PROJECT_ID=""
RAW_DATASET_ID=""
LOOKBACK_DAYS=""
START_TIME=""
END_TIME=""
STREAMS=""
SKIP_EXISTING=""
DRY_RUN=false
HEADLESS=false
CONFIG_FILE=""
DEPLOYER_SERVICE_ACCOUNT=""

# Scratch workspace with automatic cleanup
SCRATCH_DIR=$(mktemp -d -t agy_backfill_XXXXXX 2>/dev/null || mktemp -d)
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

Copies Antigravity log entries from Cloud Logging into the RAW dataset.

Options:
  -c, --config FILE             YAML config file (default: config.yaml if present)
  -p, --project-id ID           Source project (Cloud Logging, where Antigravity is active)
  -d, --dest-project-id ID      Project hosting BigQuery (default: same as project-id)
  --raw-dataset-id ID           RAW dataset to load into (default: ${DEFAULT_RAW_DATASET_ID})
  -n, --days DAYS               Look back DAYS from now (default: ${DEFAULT_LOOKBACK_DAYS})
  --start-time RFC3339          Window start, e.g. 2026-08-26T00:00:00Z (overrides --days)
  --end-time RFC3339            Window end (default: now, UTC)
  -s, --streams LIST            'all' or a comma list of: inference_response, client_telemetry, inference_request
  --skip-existing BOOL          Skip entries whose insertId is already in RAW (true/false, default: ${DEFAULT_SKIP_EXISTING})
  --dry-run                     Show counts only; write nothing
  --impersonate-sa SA_EMAIL     Service account to impersonate (gcloud and bq calls)
  -y, --yes, --headless         Do not ask for confirmation
  -h, --help                    Show this help and exit

Notes:
  - Cloud Logging keeps entries in the _Default bucket for 30 days unless you changed it,
    so older entries cannot be backfilled.
  - Rows older than the RAW retention (partition expiration) are dropped by BigQuery.

Examples:
  # Preview the last 7 days:
  ./backfill.sh -p my-ge-project --dry-run

  # Backfill the last 7 days:
  ./backfill.sh -p my-ge-project -n 7 -y

  # Backfill a fixed window for inference_response only:
  ./backfill.sh -p my-ge-project --start-time=2026-08-28T00:00:00Z --end-time=2026-08-30T00:00:00Z -s inference_response -y
HELP_EOF
  exit 0
}

# Parse scalar keys from a YAML config file.
load_config_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  log_info "Loading configuration from: ${file}"

  local parsed
  parsed=$(python3 - "$file" <<'PY'
import re, sys

def parse_val(v):
    v = v.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
        return v[1:-1]
    return v

with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        m = re.match(r'^([A-Za-z0-9_-]+)\s*:\s*(.*)$', line)
        if m:
            val = parse_val(m.group(2).split(' #', 1)[0])
            if val and not val.startswith(('[', '{')):
                print(f'{m.group(1)}={val}')
PY
)

  while IFS='=' read -r key val; do
    case "$key" in
      project_id) [[ -z "$PROJECT_ID" ]] && PROJECT_ID="$val" ;;
      destination_project_id) [[ -z "$DEST_PROJECT_ID" ]] && DEST_PROJECT_ID="$val" ;;
      raw_dataset_id) [[ -z "$RAW_DATASET_ID" ]] && RAW_DATASET_ID="$val" ;;
      lookback_days) [[ -z "$LOOKBACK_DAYS" ]] && LOOKBACK_DAYS="$val" ;;
      skip_existing) [[ -z "$SKIP_EXISTING" ]] && SKIP_EXISTING="$val" ;;
      deployer_service_account) [[ -z "$DEPLOYER_SERVICE_ACCOUNT" ]] && DEPLOYER_SERVICE_ACCOUNT="$val" ;;
    esac
  done <<< "$parsed"
  return 0
}

# ------------------------------------------------------------------------------
# CLI Argument Parsing
# ------------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--config) CONFIG_FILE="$2"; shift 2 ;;
    --config=*) CONFIG_FILE="${1#*=}"; shift ;;
    -p|--project-id) PROJECT_ID="$2"; shift 2 ;;
    --project-id=*) PROJECT_ID="${1#*=}"; shift ;;
    -d|--dest-project-id) DEST_PROJECT_ID="$2"; shift 2 ;;
    --dest-project-id=*) DEST_PROJECT_ID="${1#*=}"; shift ;;
    --raw-dataset-id) RAW_DATASET_ID="$2"; shift 2 ;;
    --raw-dataset-id=*) RAW_DATASET_ID="${1#*=}"; shift ;;
    -n|--days) LOOKBACK_DAYS="$2"; shift 2 ;;
    --days=*) LOOKBACK_DAYS="${1#*=}"; shift ;;
    --start-time) START_TIME="$2"; shift 2 ;;
    --start-time=*) START_TIME="${1#*=}"; shift ;;
    --end-time) END_TIME="$2"; shift 2 ;;
    --end-time=*) END_TIME="${1#*=}"; shift ;;
    -s|--streams) STREAMS="$2"; shift 2 ;;
    --streams=*) STREAMS="${1#*=}"; shift ;;
    --skip-existing) SKIP_EXISTING="$2"; shift 2 ;;
    --skip-existing=*) SKIP_EXISTING="${1#*=}"; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --impersonate-sa) DEPLOYER_SERVICE_ACCOUNT="$2"; shift 2 ;;
    --impersonate-sa=*) DEPLOYER_SERVICE_ACCOUNT="${1#*=}"; shift ;;
    -y|--yes|--headless) HEADLESS=true; shift ;;
    -h|--help) usage ;;
    *) log_error "Unknown argument: $1"; usage ;;
  esac
done

if [[ -n "$CONFIG_FILE" ]]; then
  load_config_file "$CONFIG_FILE"
elif [[ -f "$DEFAULT_CONFIG_FILE" ]]; then
  load_config_file "$DEFAULT_CONFIG_FILE"
fi

RAW_DATASET_ID="${RAW_DATASET_ID:-$DEFAULT_RAW_DATASET_ID}"
LOOKBACK_DAYS="${LOOKBACK_DAYS:-$DEFAULT_LOOKBACK_DAYS}"
SKIP_EXISTING="${SKIP_EXISTING:-$DEFAULT_SKIP_EXISTING}"
STREAMS="${STREAMS:-$DEFAULT_STREAMS}"

IMPERSONATE_FLAGS=()
if [[ -n "$DEPLOYER_SERVICE_ACCOUNT" ]]; then
  IMPERSONATE_FLAGS=(--impersonate-service-account="${DEPLOYER_SERVICE_ACCOUNT}")
  log_info "Impersonating service account: ${DEPLOYER_SERVICE_ACCOUNT}"
fi

# ------------------------------------------------------------------------------
# Pre-Flight Checks
# ------------------------------------------------------------------------------
print_header
log_info "Executing pre-flight checks..."

for bin in gcloud bq jq python3; do
  if ! command -v "$bin" &>/dev/null; then
    log_error "'${bin}' is required but not installed or not in PATH."
    exit 1
  fi
done

if [[ -z "$PROJECT_ID" ]]; then
  PROJECT_ID=$(gcloud config get-value project 2>/dev/null || true)
  [[ "$PROJECT_ID" == "(unset)" ]] && PROJECT_ID=""
  if [[ -z "$PROJECT_ID" && "$HEADLESS" != true ]]; then
    echo -ne "${BOLD}Enter source GCP Project ID: ${NC}"
    read -r PROJECT_ID
  fi
fi
if [[ -z "$PROJECT_ID" ]]; then
  log_error "Project ID is required. Use --project-id or 'gcloud config set project <id>'."
  exit 1
fi
DEST_PROJECT_ID="${DEST_PROJECT_ID:-$PROJECT_ID}"

if [[ "$SKIP_EXISTING" != "true" && "$SKIP_EXISTING" != "false" ]]; then
  log_error "--skip-existing must be true or false (got '${SKIP_EXISTING}')."
  exit 1
fi
if [[ -z "$START_TIME" ]] && ! [[ "$LOOKBACK_DAYS" =~ ^[1-9][0-9]*$ ]]; then
  log_error "--days must be a positive integer (got '${LOOKBACK_DAYS}')."
  exit 1
fi

STREAM_LIST=()
if [[ "$STREAMS" == "all" ]]; then
  STREAM_LIST=("${ALL_STREAMS[@]}")
else
  IFS=',' read -ra REQUESTED <<< "$STREAMS"
  for s in "${REQUESTED[@]}"; do
    s="${s// /}"
    if [[ ! " ${ALL_STREAMS[*]} " =~ " ${s} " ]]; then
      log_error "Unknown stream '${s}'. Use 'all' or: ${ALL_STREAMS[*]}"
      exit 1
    fi
    STREAM_LIST+=("$s")
  done
fi

if [[ -z "$START_TIME" ]]; then
  START_TIME=$(date -u -d "${LOOKBACK_DAYS} days ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
    || date -u -v-"${LOOKBACK_DAYS}"d +"%Y-%m-%dT%H:%M:%SZ")
fi
if [[ -z "$END_TIME" ]]; then
  END_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
fi

ACTIVE_ACCOUNT=$(gcloud config get-value account 2>/dev/null || echo "Unknown")
log_info "Active Account : ${ACTIVE_ACCOUNT}"

# RAW dataset must exist (distinguish "not found" from auth/permission errors)
if ! ds_out=$(bq show "${IMPERSONATE_FLAGS[@]+"${IMPERSONATE_FLAGS[@]}"}" "${DEST_PROJECT_ID}:${RAW_DATASET_ID}" 2>&1); then
  if grep -q "Not found" <<< "${ds_out}"; then
    log_error "RAW dataset ${DEST_PROJECT_ID}:${RAW_DATASET_ID} does not exist. Run deploy.sh first."
  else
    log_error "Could not read ${DEST_PROJECT_ID}:${RAW_DATASET_ID}: ${ds_out}"
    log_error "RAW is owners-only: run as a project owner, and check 'gcloud auth login'."
  fi
  exit 1
fi
log_success "RAW dataset verified: ${DEST_PROJECT_ID}:${RAW_DATASET_ID}"

# ------------------------------------------------------------------------------
# Plan
# ------------------------------------------------------------------------------
echo "------------------------------------------------------------------------------"
echo -e "${BOLD}Backfill Plan:${NC}"
echo "  Source (Cloud Logging) : ${PROJECT_ID}"
echo "  Target (RAW dataset)   : ${DEST_PROJECT_ID}:${RAW_DATASET_ID}"
echo "  Window                 : ${START_TIME} -> ${END_TIME}"
echo "  Streams                : ${STREAM_LIST[*]}"
echo "  Skip existing insertId : ${SKIP_EXISTING}"
echo "  Mode                   : $([[ "$DRY_RUN" == true ]] && echo "DRY RUN (no writes)" || echo "LIVE")"
echo "------------------------------------------------------------------------------"
echo -e "${CYAN}ℹ Entries are loaded with all fields (including prompts and responses), exactly as the sink stores them.${NC}"
echo "------------------------------------------------------------------------------"

if [[ "$HEADLESS" != true && "$DRY_RUN" != true ]]; then
  echo -ne "${YELLOW}${BOLD}Proceed with the backfill? [y/N]: ${NC}"
  read -r CONFIRM
  if [[ ! "$CONFIRM" =~ ^[yY]([eE][sS])?$ ]]; then
    log_warn "Backfill cancelled by user."
    exit 0
  fi
fi

# Python mapper: Cloud Logging JSON array -> NDJSON matching the RAW table schema.
MAPPER="${SCRATCH_DIR}/map_to_schema.py"
cat > "${MAPPER}" <<'PY'
import json, re, sys

entries_path, schema_path, payload_col, out_path = sys.argv[1:5]
entries = json.load(open(entries_path))
schema = json.load(open(schema_path))
dropped = set()

def norm(k):
    return k.replace('@', '_').lower()

def ts(v):
    # BigQuery accepts at most microseconds; Cloud Logging returns nanoseconds.
    m = re.match(r'^(.*T\d\d:\d\d:\d\d)(\.\d+)?(Z|[+-]\d\d:\d\d)?$', str(v))
    if not m:
        return v
    frac = (m.group(2) or '')[:7]
    return f"{m.group(1)}{frac}{m.group(3) or 'Z'}"

def scalar(v, typ):
    if isinstance(v, (dict, list)):
        return json.dumps(v)
    if typ == 'STRING':
        return v if isinstance(v, str) else json.dumps(v)
    if typ == 'TIMESTAMP':
        return ts(v)
    return v

def conv(v, field, path):
    typ = field.get('type', 'STRING').upper()
    if field.get('mode', '').upper() == 'REPEATED':
        items = v if isinstance(v, list) else [v]
        return [one(i, field, typ, path) for i in items if i is not None]
    return one(v, field, typ, path)

def one(v, field, typ, path):
    if typ in ('RECORD', 'STRUCT'):
        return record(v if isinstance(v, dict) else {}, field.get('fields', []), path)
    return scalar(v, typ)

def record(obj, fields, path):
    by_name = {f['name'].lower(): f for f in fields}
    out = {}
    for k, v in obj.items():
        if v is None:
            continue
        f = by_name.get(norm(k))
        if f is None:
            dropped.add(f"{path}{k}")
            continue
        out[f['name']] = conv(v, f, f"{path}{k}.")
    return out

payload_field = next((f for f in schema if f['name'].lower() == payload_col), None)
top = {f['name'].lower(): f for f in schema if f['name'].lower() != payload_col}

with open(out_path, 'w') as out:
    for e in entries:
        row = {}
        for k, v in e.items():
            if v is None:
                continue
            if k == 'jsonPayload':
                if payload_field is None:
                    dropped.add('jsonPayload')
                else:
                    row[payload_field['name']] = record(v, payload_field.get('fields', []), 'jsonPayload.')
                continue
            f = top.get(norm(k))
            if f is None:
                dropped.add(k)
                continue
            row[f['name']] = conv(v, f, f"{k}.")
        out.write(json.dumps(row) + '\n')

print(' '.join(sorted(dropped)))
PY

# ------------------------------------------------------------------------------
# Stream Processing
# ------------------------------------------------------------------------------
TOTAL_FETCHED=0
TOTAL_SKIPPED=0
TOTAL_INSERTED=0

for stream in "${STREAM_LIST[@]}"; do
  TABLE_ID="${TABLE_PREFIX}${stream}"
  TABLE_REF="${DEST_PROJECT_ID}:${RAW_DATASET_ID}.${TABLE_ID}"
  PAYLOAD_COL="jsonpayload_v1_${stream//_/}log"
  log_info "=============================================================================="
  log_info "Stream ${stream} -> ${TABLE_REF}"

  SCHEMA_JSON="${SCRATCH_DIR}/${stream}_schema.json"
  if ! bq show "${IMPERSONATE_FLAGS[@]+"${IMPERSONATE_FLAGS[@]}"}" --schema --format=json "${TABLE_REF}" > "${SCHEMA_JSON}" 2>/dev/null; then
    log_error "Table ${TABLE_REF} not found. Run deploy.sh (it pre-creates the RAW tables)."
    exit 1
  fi

  # 1. Read Cloud Logging
  LOG_FILTER="resource.type=\"businessaicode.googleapis.com/BAICInstance\" AND logName=\"projects/${PROJECT_ID}/logs/businessaicode.googleapis.com%2F${stream}\" AND timestamp>=\"${START_TIME}\" AND timestamp<=\"${END_TIME}\""
  RAW_JSON="${SCRATCH_DIR}/${stream}_raw.json"
  log_info "Reading Cloud Logging entries (${START_TIME} -> ${END_TIME})..."
  if ! gcloud logging read "$LOG_FILTER" --project="${PROJECT_ID}" --format=json \
      "${IMPERSONATE_FLAGS[@]+"${IMPERSONATE_FLAGS[@]}"}" > "$RAW_JSON"; then
    log_error "gcloud logging read failed for ${stream}. Check permissions (roles/logging.viewer) and the filter."
    exit 1
  fi
  [[ -s "$RAW_JSON" ]] || echo "[]" > "$RAW_JSON"

  RECORD_COUNT=$(jq 'length' "$RAW_JSON")
  TOTAL_FETCHED=$((TOTAL_FETCHED + RECORD_COUNT))
  log_info "Found ${RECORD_COUNT} entries."
  [[ "$RECORD_COUNT" -eq 0 ]] && continue

  # 2. Skip entries already in RAW
  NEW_JSON="${SCRATCH_DIR}/${stream}_new.json"
  if [[ "$SKIP_EXISTING" == "true" ]]; then
    EXISTING_IDS="${SCRATCH_DIR}/${stream}_existing_ids.txt"
    if ! bq query "${IMPERSONATE_FLAGS[@]+"${IMPERSONATE_FLAGS[@]}"}" --project_id="${DEST_PROJECT_ID}" \
        --use_legacy_sql=false --format=csv --max_rows=100000000 \
        "SELECT DISTINCT insertId FROM \`${DEST_PROJECT_ID}.${RAW_DATASET_ID}.${TABLE_ID}\` WHERE timestamp BETWEEN TIMESTAMP('${START_TIME}') AND TIMESTAMP('${END_TIME}')" \
        > "${EXISTING_IDS}.csv"; then
      log_error "Could not read existing insertIds from ${TABLE_REF}."
      exit 1
    fi
    tail -n +2 "${EXISTING_IDS}.csv" | grep -v '^$' > "$EXISTING_IDS" || true
    jq --rawfile ids "$EXISTING_IDS" '
      (reduce ($ids | split("\n")[] | select(length > 0)) as $i ({}; .[$i] = true)) as $seen
      | map(select($seen[.insertId] | not))
    ' "$RAW_JSON" > "$NEW_JSON"
  else
    cp "$RAW_JSON" "$NEW_JSON"
  fi
  NEW_COUNT=$(jq 'length' "$NEW_JSON")
  SKIPPED=$((RECORD_COUNT - NEW_COUNT))
  TOTAL_SKIPPED=$((TOTAL_SKIPPED + SKIPPED))
  log_info "${SKIPPED} already in RAW, ${NEW_COUNT} new."

  if [[ "$DRY_RUN" == true ]]; then
    log_info "[DRY RUN] Would load ${NEW_COUNT} entries into ${TABLE_REF}."
    continue
  fi
  [[ "$NEW_COUNT" -eq 0 ]] && continue

  # 3. Map to the RAW table schema
  NDJSON="${SCRATCH_DIR}/${stream}.ndjson"
  DROPPED=$(python3 "${MAPPER}" "$NEW_JSON" "$SCHEMA_JSON" "$PAYLOAD_COL" "$NDJSON")
  if [[ -n "$DROPPED" ]]; then
    log_warn "Fields not in ${TABLE_ID} (dropped): ${DROPPED}"
  fi

  # 4. Load
  log_info "Loading ${NEW_COUNT} entries into ${TABLE_REF}..."
  bq load "${IMPERSONATE_FLAGS[@]+"${IMPERSONATE_FLAGS[@]}"}" \
    --source_format=NEWLINE_DELIMITED_JSON \
    "${TABLE_REF}" "$NDJSON" > /dev/null
  TOTAL_INSERTED=$((TOTAL_INSERTED + NEW_COUNT))
  log_success "Loaded ${NEW_COUNT} entries into ${TABLE_ID}."
done

# ------------------------------------------------------------------------------
# Report
# ------------------------------------------------------------------------------
echo ""
echo -e "${GREEN}${BOLD}==============================================================================${NC}"
echo -e "${GREEN}${BOLD} Antigravity Historical Log Backfill Completed! 📊${NC}"
echo -e "${GREEN}${BOLD}==============================================================================${NC}"
echo "  Target            : ${DEST_PROJECT_ID}:${RAW_DATASET_ID}"
echo "  Window            : ${START_TIME} -> ${END_TIME}"
echo "  Entries scanned   : ${TOTAL_FETCHED}"
echo "  Already in RAW    : ${TOTAL_SKIPPED}"
if [[ "$DRY_RUN" == true ]]; then
  echo "  Mode              : DRY RUN (nothing written)"
else
  echo "  Entries loaded    : ${TOTAL_INSERTED}"
fi
echo "=============================================================================="
echo ""
