#!/usr/bin/env bash
# ==============================================================================
# Google Antigravity (Gemini Enterprise) - Direct Log Sink Deployer
# ==============================================================================
# Automates the creation of:
# 1. RAW BigQuery dataset (ge_app_agy_raw) with regional residency and daily
#    partition expiration. Holds ALL log fields incl. prompts and responses.
#    Tables are pre-created from ../schemas/raw/*.json.
# 2. Views BigQuery dataset (ge_app_agy_telemetry) holding authorized views over
#    RAW that never return prompt text (deployed via ../views/deploy_views.sh).
# 3. Lock-down: the default projectReaders/projectWriters access entries are
#    removed from BOTH datasets, so only project owners have dataset access.
# 4. Cloud Logging Router Sink (ge-app-agy-telemetry-sink) targeting
#    businessaicode.googleapis.com/BAICInstance -> RAW (no exclusions).
# 5. IAM Permissions Handshake granting the sink writer identity dataEditor
#    access exclusively on the RAW dataset.
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEMA_DIR="${SCRIPT_DIR}/../schemas/raw"
VIEWS_DIR="${SCRIPT_DIR}/../views"

# ------------------------------------------------------------------------------
# Default Values (Following Antigravity Enterprise Conventions)
# ------------------------------------------------------------------------------
DEFAULT_CONFIG_FILE="config.yaml"
DEFAULT_DATASET_ID="ge_app_agy_telemetry"
DEFAULT_RAW_DATASET_ID="ge_app_agy_raw"
DEFAULT_LOCATION="us-central1"
DEFAULT_SINK_NAME="ge-app-agy-telemetry-sink"
DEFAULT_RETENTION_DAYS="90"
LEGACY_EXCLUSION_NAME="exclude-prompt-contents"
LEGACY_AUDIT_SINK_NAME="ge-app-agy-prompts-audit-sink"

TABLE_PREFIX="businessaicode_googleapis_com_"
RAW_TABLES=(inference_request inference_response client_telemetry)

PROJECT_ID=""
DEST_PROJECT_ID=""
DATASET_ID=""
RAW_DATASET_ID=""
DATASET_LOCATION=""
SINK_NAME=""
PARTITION_EXPIRATION_DAYS=""
DEPLOYER_SERVICE_ACCOUNT=""
CONFIG_FILE=""
HEADLESS=false
DEPRECATED_FLAGS_USED=()

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
  --raw-dataset-id ID           RAW dataset (all fields incl. prompts; owners only) (default: ${DEFAULT_RAW_DATASET_ID})
  --dataset-id ID               Views dataset (no prompt text; owners only) (default: ${DEFAULT_DATASET_ID})
  -l, --location REGION         Dataset residency location (default: ${DEFAULT_LOCATION})
  -s, --sink-name NAME          Cloud Logging sink identifier (default: ${DEFAULT_SINK_NAME})
  -r, --retention-days DAYS     RAW daily partition expiration in days (default: ${DEFAULT_RETENTION_DAYS}, 0 = never)
  --impersonate-sa SA_EMAIL     Deployer Service Account to impersonate (gcloud calls)
  -y, --yes, --headless         Run in non-interactive/headless mode without prompts
  -h, --help                    Display this help message and exit

Deprecated (accepted with a warning, no effect):
  --exclude-prompts, --enable-prompt-audit, --audit-dataset-id, --audit-sink-name, --audit-retention-days

Examples:
  # 1. Interactive setup with smart defaults:
  ./deploy.sh

  # 2. Deploy using a configuration file:
  ./deploy.sh --config=config.example.yaml

  # 3. Headless single-command deployment:
  ./deploy.sh -p my-ge-project -l asia-northeast1 -r 365 -y
EOF
  exit 0
}

# Parse YAML/JSON config (scalar keys only)
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
            # Only print scalar keys
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
      partition_expiration_days) [[ -z "$PARTITION_EXPIRATION_DAYS" ]] && PARTITION_EXPIRATION_DAYS="$val" ;;
      deployer_service_account) [[ -z "$DEPLOYER_SERVICE_ACCOUNT" ]] && DEPLOYER_SERVICE_ACCOUNT="$val" ;;
      exclude_prompt_contents|enable_prompt_audit|audit_dataset_id|audit_sink_name|audit_retention_days|flash_discount_applied)
        DEPRECATED_FLAGS_USED+=("${key} (config)") ;;
    esac
  done <<< "$parsed"
  return 0
}

# ensure_dataset DATASET DESCRIPTION PARTITION_DAYS
ensure_dataset() {
  local ds="$1" desc="$2" days="$3"
  if bq show --project_id="${DEST_PROJECT_ID}" "${ds}" &> /dev/null; then
    log_info "Dataset ${DEST_PROJECT_ID}:${ds} already exists."
    if [[ "$days" -gt 0 ]]; then
      bq update --default_partition_expiration=$(( days * 86400 )) "${DEST_PROJECT_ID}:${ds}" > /dev/null
    fi
    return 0
  fi
  local flags=(--project_id="${DEST_PROJECT_ID}" --location="${DATASET_LOCATION}" --dataset --description="${desc}")
  if [[ "$days" -gt 0 ]]; then
    flags+=(--default_partition_expiration=$(( days * 86400 )))
  fi
  bq mk "${flags[@]}" "${ds}" > /dev/null
  log_success "Created dataset ${DEST_PROJECT_ID}:${ds} (${DATASET_LOCATION})"
}

# ensure_table DATASET TABLE SCHEMA_FILE PARTITION_DAYS
# Creates a DAY-partitioned (timestamp) table, or additively merges missing
# fields into an existing table's schema (never removes or retypes fields) and
# aligns its partition expiration with PARTITION_DAYS.
ensure_table() {
  local ds="$1" tbl="$2" schema="$3" days="$4"
  local ref="${DEST_PROJECT_ID}:${ds}.${tbl}"
  if ! bq show "${ref}" &> /dev/null; then
    local flags=(--table --schema="${schema}" --time_partitioning_field=timestamp --time_partitioning_type=DAY)
    if [[ "$days" -gt 0 ]]; then
      flags+=(--time_partitioning_expiration=$(( days * 86400 )))
    fi
    bq mk "${flags[@]}" "${ref}" > /dev/null
    log_success "Created table ${ref}"
    return 0
  fi
  local cur merged status
  cur=$(mktemp); merged=$(mktemp)
  bq show --schema --format=json "${ref}" > "${cur}"
  status=$(python3 - "${cur}" "${schema}" "${merged}" <<'PY'
import json, sys
cur = json.load(open(sys.argv[1]))
want = json.load(open(sys.argv[2]))
def merge(c, w):
    changed = False
    idx = {f['name'].lower(): f for f in c}
    for f in w:
        e = idx.get(f['name'].lower())
        if e is None:
            c.append(f); changed = True
        elif f.get('type') == 'RECORD' and e.get('type') in ('RECORD', 'STRUCT'):
            if merge(e.setdefault('fields', []), f.get('fields', [])):
                changed = True
    return changed
changed = merge(cur, want)
json.dump(cur, open(sys.argv[3], 'w'))
print('CHANGED' if changed else 'SAME')
PY
)
  if [[ "$status" == "CHANGED" ]]; then
    bq update "${ref}" "${merged}" > /dev/null
    log_success "Added missing schema fields to ${ref}"
  else
    log_info "Table ${ref} already has the required schema."
  fi
  if [[ "$days" -gt 0 ]]; then
    bq update --time_partitioning_expiration=$(( days * 86400 )) "${ref}" > /dev/null
  fi
  rm -f "${cur}" "${merged}"
}

# lock_dataset DATASET [WRITER_EMAIL]
# Removes BigQuery's default projectReaders/projectWriters entries so only
# project owners (and explicit grants) have dataset-level access. Optionally
# ensures WRITER for the sink writer identity.
lock_dataset() {
  local ds="$1" writer="${2:-}"
  local tmp status
  tmp=$(mktemp)
  bq show --format=prettyjson "${DEST_PROJECT_ID}:${ds}" > "${tmp}"
  status=$(python3 - "${tmp}" "${writer}" <<'PY'
import json, sys
path, writer = sys.argv[1], sys.argv[2]
data = json.load(open(path))
access = data.get('access', [])
before = len(access)
access = [a for a in access if a.get('specialGroup') not in ('projectReaders', 'projectWriters')]
removed = before - len(access)
added = 0
if writer and not any(a.get('userByEmail') == writer and a.get('role') in ('WRITER', 'roles/bigquery.dataEditor') for a in access):
    access.append({'role': 'WRITER', 'userByEmail': writer})
    added = 1
if not any(a.get('specialGroup') == 'projectOwners' for a in access):
    access.append({'role': 'OWNER', 'specialGroup': 'projectOwners'})
    added += 1
data['access'] = access
json.dump(data, open(path, 'w'), indent=2)
print(f'{removed} {added}')
PY
)
  local removed="${status%% *}" added="${status##* }"
  if [[ "$removed" != "0" || "$added" != "0" ]]; then
    bq update --source "${tmp}" "${DEST_PROJECT_ID}:${ds}" > /dev/null
    log_success "Locked ${ds}: removed ${removed} default reader/writer entr(y/ies); added ${added} required entr(y/ies)."
  else
    log_info "${ds} is already locked (owners only)."
  fi
  rm -f "${tmp}"
}

# True if the views dataset still holds TABLES (pre-MVP layout).
views_dataset_has_tables() {
  local ds="$1"
  bq show --project_id="${DEST_PROJECT_ID}" "${ds}" &> /dev/null || return 1
  bq ls --format=json --max_results=1000 "${DEST_PROJECT_ID}:${ds}" | jq -e '[.[]? | select(.type == "TABLE")] | length > 0' > /dev/null
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
    -r|--retention-days) PARTITION_EXPIRATION_DAYS="$2"; shift 2 ;;
    --exclude-prompts|--enable-prompt-audit)
      DEPRECATED_FLAGS_USED+=("$1")
      if [[ -n "${2:-}" && "$2" != -* ]]; then shift 2; else shift 1; fi
      ;;
    --audit-dataset-id|--audit-sink-name|--audit-retention-days)
      DEPRECATED_FLAGS_USED+=("$1"); shift 2 ;;
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

for bin in gcloud bq jq python3; do
  if ! command -v "$bin" &> /dev/null; then
    log_error "'${bin}' is required but not installed or not in PATH."
    exit 1
  fi
done

for t in "${RAW_TABLES[@]}"; do
  if [[ ! -f "${SCHEMA_DIR}/${t}.json" ]]; then
    log_error "Missing RAW schema: ${SCHEMA_DIR}/${t}.json"
    exit 1
  fi
done
if [[ ! -f "${VIEWS_DIR}/deploy_views.sh" ]]; then
  log_error "Missing views deployer: ${VIEWS_DIR}/deploy_views.sh"
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
RAW_DATASET_ID="${RAW_DATASET_ID:-$DEFAULT_RAW_DATASET_ID}"
DATASET_LOCATION="${DATASET_LOCATION:-$DEFAULT_LOCATION}"
SINK_NAME="${SINK_NAME:-$DEFAULT_SINK_NAME}"
PARTITION_EXPIRATION_DAYS="${PARTITION_EXPIRATION_DAYS:-$DEFAULT_RETENTION_DAYS}"

log_info "Active Account : ${ACTIVE_GCLOUD_ACCOUNT:-None}"

for dep in "${DEPRECATED_FLAGS_USED[@]+"${DEPRECATED_FLAGS_USED[@]}"}"; do
  log_warn "Deprecated option ignored: ${dep}. All fields land in the locked RAW dataset; views never return prompt text."
done

# ------------------------------------------------------------------------------
# Interactive Prompting (if not headless)
# ------------------------------------------------------------------------------
if [[ "$HEADLESS" != "true" ]]; then
  echo ""
  echo -e "${BOLD}Configure Deployment Parameters (Press ENTER to accept defaults):${NC}"

  read -r -p "Source GCP Project ID [${PROJECT_ID}]: " input_proj
  PROJECT_ID="${input_proj:-$PROJECT_ID}"

  [[ -z "$DEST_PROJECT_ID" ]] && DEST_PROJECT_ID="$PROJECT_ID"
  read -r -p "Destination GCP Project ID [${DEST_PROJECT_ID}]: " input_dest_proj
  DEST_PROJECT_ID="${input_dest_proj:-$DEST_PROJECT_ID}"

  read -r -p "Raw dataset ID (all fields incl. prompts) [${RAW_DATASET_ID}]: " input_raw
  RAW_DATASET_ID="${input_raw:-$RAW_DATASET_ID}"

  read -r -p "Views dataset ID (no prompt text) [${DATASET_ID}]: " input_ds
  DATASET_ID="${input_ds:-$DATASET_ID}"

  read -r -p "Dataset Residency Location [${DATASET_LOCATION}]: " input_loc
  DATASET_LOCATION="${input_loc:-$DATASET_LOCATION}"

  read -r -p "Cloud Logging Sink Name [${SINK_NAME}]: " input_sink
  SINK_NAME="${input_sink:-$SINK_NAME}"

  read -r -p "Raw data retention in days (0=never) [${PARTITION_EXPIRATION_DAYS}]: " input_ret
  PARTITION_EXPIRATION_DAYS="${input_ret:-$PARTITION_EXPIRATION_DAYS}"

  echo ""
fi

if [[ -z "$PROJECT_ID" ]]; then
  log_error "Project ID is required. Specify with --project-id or set 'gcloud config set project <id>'."
  exit 1
fi

DEST_PROJECT_ID="${DEST_PROJECT_ID:-$PROJECT_ID}"

# ------------------------------------------------------------------------------
# Input Validation
# ------------------------------------------------------------------------------
if ! [[ "$PARTITION_EXPIRATION_DAYS" =~ ^[0-9]+$ ]]; then
  log_error "Retention days must be a non-negative integer (got '${PARTITION_EXPIRATION_DAYS}')."
  exit 1
fi
if [[ "$RAW_DATASET_ID" == "$DATASET_ID" ]]; then
  log_error "Raw dataset and views dataset must be different (both '${DATASET_ID}')."
  exit 1
fi
if (( PARTITION_EXPIRATION_DAYS > 0 && PARTITION_EXPIRATION_DAYS < 90 )); then
  log_warn "Retention ${PARTITION_EXPIRATION_DAYS}d < 90d: the 90-day window in v_ge_app_agy_user_summary will contain only ${PARTITION_EXPIRATION_DAYS} days of data."
fi

# Apply SA Impersonation flag if specified
GCLOUD_EXTRA_FLAGS=()
if [[ -n "$DEPLOYER_SERVICE_ACCOUNT" ]]; then
  log_info "Impersonating deployer service account: ${DEPLOYER_SERVICE_ACCOUNT}"
  GCLOUD_EXTRA_FLAGS+=(--impersonate-service-account="${DEPLOYER_SERVICE_ACCOUNT}")
fi

RETENTION_LABEL="${PARTITION_EXPIRATION_DAYS} days"
[[ "$PARTITION_EXPIRATION_DAYS" == "0" ]] && RETENTION_LABEL="never expires"

echo -e "${CYAN}------------------------------------------------------------------------------${NC}"
echo -e "${BOLD}Deployment Summary:${NC}"
echo -e "  Source / Destination : ${BOLD}${PROJECT_ID}${NC} / ${BOLD}${DEST_PROJECT_ID}${NC}"
echo -e "  Raw dataset          : ${BOLD}${RAW_DATASET_ID}${NC} (${RETENTION_LABEL}, ${DATASET_LOCATION}) – ALL fields incl. prompts, owners only"
echo -e "  Views dataset        : ${BOLD}${DATASET_ID}${NC} – authorized views, NO prompt text, owners only"
echo -e "  Sink                 : ${BOLD}${SINK_NAME}${NC} → ${RAW_DATASET_ID}"
echo -e "${CYAN}------------------------------------------------------------------------------${NC}"
echo -e "${CYAN}ℹ Raw logs (including prompts and model responses) are stored in ${RAW_DATASET_ID} (${RETENTION_LABEL}).${NC}"
echo "  Only project owners can read it (project Editors / BigQuery Admins inherit access via IAM)."
echo "  Dashboards read ${DATASET_ID} views, which never return prompt text."
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
  --project="${PROJECT_ID}" "${GCLOUD_EXTRA_FLAGS[@]+"${GCLOUD_EXTRA_FLAGS[@]}"}" --quiet

if [[ "$PROJECT_ID" != "$DEST_PROJECT_ID" ]]; then
  log_info "Enabling BigQuery API on destination project ${DEST_PROJECT_ID}..."
  gcloud services enable bigquery.googleapis.com \
    --project="${DEST_PROJECT_ID}" "${GCLOUD_EXTRA_FLAGS[@]+"${GCLOUD_EXTRA_FLAGS[@]}"}" --quiet
fi

# ------------------------------------------------------------------------------
# Step 2: Datasets (+ legacy layout guard)
# ------------------------------------------------------------------------------
if views_dataset_has_tables "${DATASET_ID}"; then
  log_error "Dataset ${DEST_PROJECT_ID}:${DATASET_ID} contains TABLES from the previous layout (they may include prompts)."
  log_error "In the new layout ${DATASET_ID} holds views only and raw data lives in ${RAW_DATASET_ID}."
  log_error "Migrate first, e.g. per table:"
  log_error "  bq cp ${DEST_PROJECT_ID}:${DATASET_ID}.<table> ${DEST_PROJECT_ID}:${RAW_DATASET_ID}_legacy.<table>   # keep history"
  log_error "  bq rm -f -t ${DEST_PROJECT_ID}:${DATASET_ID}.<table>"
  log_error "or remove everything with ./cleanup.sh, then re-run deploy.sh."
  exit 1
fi

ensure_dataset "${RAW_DATASET_ID}" "Antigravity RAW logs (all fields incl. prompts and responses). Owners only." \
  "${PARTITION_EXPIRATION_DAYS}"
ensure_dataset "${DATASET_ID}" "Antigravity telemetry views (authorized views over ${RAW_DATASET_ID}; no prompt text). Owners only." 0

# ------------------------------------------------------------------------------
# Step 3: RAW tables (pre-created so views never reference missing fields)
# ------------------------------------------------------------------------------
log_info "Ensuring RAW tables..."
for t in "${RAW_TABLES[@]}"; do
  ensure_table "${RAW_DATASET_ID}" "${TABLE_PREFIX}${t}" "${SCHEMA_DIR}/${t}.json" "${PARTITION_EXPIRATION_DAYS}"
done

# ------------------------------------------------------------------------------
# Step 4: Cloud Logging Router Sink -> RAW (no exclusions)
# ------------------------------------------------------------------------------
SINK_DESTINATION="bigquery.googleapis.com/projects/${DEST_PROJECT_ID}/datasets/${RAW_DATASET_ID}"
SINK_FILTER='resource.type="businessaicode.googleapis.com/BAICInstance" AND logName=~"businessaicode.googleapis.com"'

log_info "Configuring Cloud Logging Log Router Sink: ${SINK_NAME} → ${RAW_DATASET_ID}..."
SINK_EXISTS=$(gcloud logging sinks list --project="${PROJECT_ID}" --filter="name=${SINK_NAME}" --format="value(name)" "${GCLOUD_EXTRA_FLAGS[@]+"${GCLOUD_EXTRA_FLAGS[@]}"}")

CREATE_OR_UPDATE_CMD=(gcloud logging sinks)
if [[ -n "$SINK_EXISTS" ]]; then
  log_info "Updating existing sink ${SINK_NAME}..."
  CREATE_OR_UPDATE_CMD+=(update "${SINK_NAME}" "${SINK_DESTINATION}")
  LEGACY_EXCLUSION=$(gcloud logging sinks describe "${SINK_NAME}" --project="${PROJECT_ID}" --format="value(exclusions[].name)" "${GCLOUD_EXTRA_FLAGS[@]+"${GCLOUD_EXTRA_FLAGS[@]}"}" 2>/dev/null | tr ';' '\n' | grep -x "${LEGACY_EXCLUSION_NAME}" || true)
  if [[ -n "$LEGACY_EXCLUSION" ]]; then
    log_info "Removing legacy exclusion ${LEGACY_EXCLUSION_NAME} (it never removed prompts)."
    CREATE_OR_UPDATE_CMD+=(--remove-exclusions="${LEGACY_EXCLUSION_NAME}")
  fi
else
  log_info "Creating new sink ${SINK_NAME}..."
  CREATE_OR_UPDATE_CMD+=(create "${SINK_NAME}" "${SINK_DESTINATION}" --use-partitioned-tables)
fi

CREATE_OR_UPDATE_CMD+=(
  --project="${PROJECT_ID}"
  --log-filter="${SINK_FILTER}"
  --description="Routes Google Antigravity GE logs to the locked RAW dataset ${RAW_DATASET_ID}"
  "${GCLOUD_EXTRA_FLAGS[@]+"${GCLOUD_EXTRA_FLAGS[@]}"}"
  --quiet
)
"${CREATE_OR_UPDATE_CMD[@]}"
log_success "Sink ${SINK_NAME} configured successfully."

# ------------------------------------------------------------------------------
# Step 5: Sink writer identity + lock both datasets
# ------------------------------------------------------------------------------
log_info "Extracting Sink Writer Service Identity..."
WRITER_IDENTITY=$(gcloud logging sinks describe "${SINK_NAME}" \
  --project="${PROJECT_ID}" \
  --format="value(writerIdentity)" \
  "${GCLOUD_EXTRA_FLAGS[@]+"${GCLOUD_EXTRA_FLAGS[@]}"}")
log_info "Sink Writer Identity: ${WRITER_IDENTITY}"

lock_dataset "${RAW_DATASET_ID}" "${WRITER_IDENTITY#serviceAccount:}"
lock_dataset "${DATASET_ID}"

# Legacy audit sink (pre-MVP design) is no longer used.
LEGACY_AUDIT_SINK=$(gcloud logging sinks list --project="${PROJECT_ID}" --filter="name=${LEGACY_AUDIT_SINK_NAME}" --format="value(name)" "${GCLOUD_EXTRA_FLAGS[@]+"${GCLOUD_EXTRA_FLAGS[@]}"}")
if [[ -n "$LEGACY_AUDIT_SINK" ]]; then
  log_warn "Deleting legacy audit sink ${LEGACY_AUDIT_SINK_NAME}; all fields now land in ${RAW_DATASET_ID}."
  gcloud logging sinks delete "${LEGACY_AUDIT_SINK_NAME}" --project="${PROJECT_ID}" "${GCLOUD_EXTRA_FLAGS[@]+"${GCLOUD_EXTRA_FLAGS[@]}"}" --quiet
fi

# ------------------------------------------------------------------------------
# Step 6: Deploy and authorize the views
# ------------------------------------------------------------------------------
log_info "Deploying authorized views into ${DATASET_ID}..."
VIEW_ARGS=(-p "${DEST_PROJECT_ID}" -d "${DATASET_ID}" --raw-dataset-id "${RAW_DATASET_ID}" -y)
if [[ -n "$DEPLOYER_SERVICE_ACCOUNT" ]]; then
  VIEW_ARGS+=(--impersonate-sa "${DEPLOYER_SERVICE_ACCOUNT}")
fi
( cd "${VIEWS_DIR}" && bash ./deploy_views.sh "${VIEW_ARGS[@]}" )

# ------------------------------------------------------------------------------
# Step 7: Verification & Completion
# ------------------------------------------------------------------------------
echo ""
echo -e "${GREEN}${BOLD}=============================================================================="
echo " Antigravity Direct Log Sink Deployment Completed Successfully! 🚀"
echo "==============================================================================${NC}"
echo ""
echo -e "  ${BOLD}Sink Name          :${NC} ${SINK_NAME} → ${DEST_PROJECT_ID}:${RAW_DATASET_ID}"
echo -e "  ${BOLD}Writer Identity    :${NC} ${WRITER_IDENTITY}"
echo -e "  ${BOLD}Raw Dataset        :${NC} ${DEST_PROJECT_ID}:${RAW_DATASET_ID} (${RETENTION_LABEL}; all fields; owners only)"
echo -e "  ${BOLD}Views Dataset      :${NC} ${DEST_PROJECT_ID}:${DATASET_ID} (authorized views; no prompt text; owners only)"
echo ""
echo -e "${CYAN}${BOLD}Access & Next Steps:${NC}"
echo "  1. Only project owners can read both datasets. To share dashboards:"
echo "     - Looker Studio: create the data source as an owner with 'Owner's credentials'."
echo "     - Analysts/groups: BigQuery console → ${DATASET_ID} → Sharing → Permissions →"
echo "       add the principal as 'BigQuery Data Viewer' (views only; RAW stays locked)."
echo "  2. As developers use Antigravity Hub, CLI, or IDE, logs stream into ${RAW_DATASET_ID}"
echo "     and appear in the views immediately (no batch job)."
if [[ -z "$SINK_EXISTS" ]]; then
  echo "     Note: a NEW sink takes a few minutes to start routing; logs written in the first"
  echo "     ~5 minutes after creation may not be exported (observed in testing)."
fi
echo "  3. Verify with:"
echo "       bq query --use_legacy_sql=false \\"
echo "         'SELECT * FROM \`${DEST_PROJECT_ID}.${DATASET_ID}.v_ge_app_agy_user_summary\` WHERE scope = \"all_users\"'"
echo ""
