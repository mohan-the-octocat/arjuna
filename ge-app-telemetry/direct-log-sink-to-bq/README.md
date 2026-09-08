# Google Antigravity in Gemini Enterprise: Direct Log Sink to BigQuery
`ge-app-telemetry/direct-log-sink-to-bq`

This module routes Google Antigravity developer telemetry from Cloud Logging into a BigQuery dataset (`ge_app_agy_telemetry`).

---

## Architecture Overview

```
┌────────────────────────────────────────────────────────────────────────┐
│               Developer Workstations & Client Surfaces                 │
│      Antigravity 2.0 Hub  │  Antigravity CLI (agy)  │  IDE Extensions  │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ (Authenticated via Gemini Enterprise)
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│                    Google Cloud Logging                                │
│       Resource: businessaicode.googleapis.com/BAICInstance            │
│       Streams: inference_response, client_telemetry, inference_request│
└───────────────────────────────────┬────────────────────────────────────┘
                                    │
                                    ▼ (Push Log Router Sink)
┌────────────────────────────────────────────────────────────────────────┐
│           Dedicated BigQuery Dataset: `ge_app_agy_telemetry`           │
│   ├── Partitioned Raw Tables (Daily partition on timestamp)           │
│   │   ├── businessaicode_googleapis_com_inference_response            │
│   │   ├── businessaicode_googleapis_com_client_telemetry              │
│   │   └── businessaicode_googleapis_com_inference_request             │
│   │                                                                    │
│   └── Lifecycle & Retention Engine                                     │
│       ├── 90-Day Auto Long-Term Storage Price Drop ($0.01/GB/mo)        │
│       └── Auto-Expiring Daily Partitions (default: 90 days)            │
└────────────────────────────────────────────────────────────────────────┘
```

### Log Record Fields

Antigravity in Gemini Enterprise emits the following top-level labels on each log record:
* `labels.user_id`: Authenticated developer email (`user:developer@company.com`).
* `labels.trajectory_id`: Root UUID identifying the multi-turn session.
* `labels.request_id`: Turn-level execution step ID.
* `labels.client_name`: Client surface (`antigravity_hub`, `antigravity_cli`, `vscode`).
* `labels.model`: Model called (`gemini-3.7-flash`).
* `client_telemetry`: Interaction outcomes (`PROPOSAL_ACCEPTANCE`, `PERMISSION_GRANT` $\rightarrow$ `ACCEPTED`, `REJECTED`, `MODIFIED`).

---

## Prerequisites

Before deploying, ensure you have:

1. **GCP Permissions:** Your user or deployment service account needs:
   * `roles/logging.configWriter` (to create the Cloud Logging sink)
   * `roles/bigquery.admin` (to create the dataset and configure sink writer permissions)
   * `roles/serviceusage.serviceUsageAdmin` (if APIs are not yet enabled)
2. **Local CLI Tools:**
   * `gcloud` CLI (authenticated via `gcloud auth login`)
   * `bq` CLI
   * `jq` (required for `backfill.sh`)
   * `terraform` (v1.5+, only if deploying via Method B)
3. **Required APIs:**
   * `logging.googleapis.com`
   * `bigquery.googleapis.com`
   *(Checked and enabled automatically by `deploy.sh`)*

---

## Deployment Options

You can deploy this pipeline using either the Bash script (`deploy.sh`) or the Terraform module (`terraform/`). Both share the same configuration parameters.

---

### Method A: Automated CLI Deployer (`deploy.sh`)

The script performs pre-flight checks, verifies APIs, creates the dataset with regional residency, deploys the Log Router sink, and configures IAM permissions.

#### 1. Quick Interactive Mode (Recommended for Pilots / CEs)
Run the script without arguments. It detects your active `gcloud` context and prompts with smart defaults:
```bash
cd ge-app-telemetry/direct-log-sink-to-bq
./deploy.sh
```

#### 2. Configuration File Mode
Create a `config.yaml` from the template and run headlessly:
```bash
cp config.example.yaml config.yaml
# Edit your project_id, location, etc.
./deploy.sh --config=config.yaml -y
```

#### 3. Headless Single-Command Mode (CI/CD)
```bash
./deploy.sh \
  --project-id="my-ge-project" \
  --location="asia-northeast1" \
  --dataset-id="ge_app_agy_telemetry" \
  --retention-days=90 \
  --exclude-prompts=true \
  -y
```

---

### Method B: Production Terraform Module (`terraform/`)

For enterprise platform teams managing infrastructure via GitOps:

1. Navigate to the terraform directory:
   ```bash
   cd ge-app-telemetry/direct-log-sink-to-bq/terraform
   ```
2. Copy the example variables:
   ```bash
   cp terraform.tfvars.example terraform.tfvars
   ```
3. Update `terraform.tfvars` with your project parameters:
   ```hcl
   project_id                = "my-ge-project"
   dataset_id                = "ge_app_agy_telemetry"
   dataset_location          = "asia-northeast1"
   partition_expiration_days = 90
   exclude_prompt_contents   = true
   ```
4. Deploy:
   ```bash
   terraform init
   terraform plan
   terraform apply
   ```

---

## Privacy and Zero Data Retention (ZDR)

By default, `exclude_prompt_contents = true` is enabled.

When enabled, the sink applies an exclusion rule:
```sql
logName =~ "businessaicode.googleapis.com%2Finference_response"
AND jsonPayload.contents:*
```
* **What is persisted:** Token counts (`metadata.totalTokenCount`), model IDs, developer email, trajectory IDs, timestamps, and interaction outcomes.
* **What is excluded:** User prompt strings, conversational history, and generated code diffs.

---

## Verification and Testing

### Step 1: Verify Sink Status
Check that the Log Router sink exists and inspect its generated writer identity:
```bash
gcloud logging sinks describe ge-app-agy-telemetry-sink \
  --format="yaml(name,destination,writerIdentity,exclusions)"
```

### Step 2: Trigger an Event in Antigravity
Open **Antigravity 2.0 Hub** or run a command in **Antigravity CLI**:
```bash
agy "Summarize the files in this directory"
```

### Step 3: Verify Streaming Tables in BigQuery
Within 15–30 seconds of running an Antigravity prompt or CLI command, BigQuery will auto-provision the partitioned tables:
```bash
bq ls <PROJECT_ID>:ge_app_agy_telemetry
```
You should see:
* `businessaicode_googleapis_com_inference_response`
* `businessaicode_googleapis_com_client_telemetry`
* `businessaicode_googleapis_com_inference_request`

### Step 4: Run a Verification Query
```bash
bq query --use_legacy_sql=false '
SELECT 
  timestamp,
  labels.user_id,
  labels.client_name,
  labels.model,
  labels.trajectory_id,
  jsonpayload_v1_inferenceresponselog.metadata.totaltokencount AS total_tokens
FROM 
  `<PROJECT_ID>.ge_app_agy_telemetry.businessaicode_googleapis_com_inference_response`
ORDER BY timestamp DESC
LIMIT 5;
'
```

---

## Historical Log Backfill (`backfill.sh`)

Cloud Logging Log Router Sinks stream events that arrive after sink deployment; they do not export older logs retroactively.

Because Cloud Logging retains logs in the `_Default` bucket for 30 days by default, the included `backfill.sh` utility can backfill previous developer logs into `ge_app_agy_telemetry`.

### Resiliency and Deduplication
* **Ingestion-Level Deduplication:** `backfill.sh` queries the target BigQuery table for existing `insertId` values within the time window. Any record already present in BigQuery is skipped before loading (`--skip-existing=true`), preventing duplicate insertions if re-run.
* **View-Level Deduplication:** Analytical views in Track 2 use `QUALIFY ROW_NUMBER() OVER(PARTITION BY insertId ORDER BY timestamp DESC) = 1` as a secondary safeguard against streaming retries.
* **Privacy and ZDR:** Strips prompt bodies and code diffs unless explicitly overridden.

### Backfill Usage Examples

```bash
# 1. Preview backfill for the past 7 days without writing (Dry Run):
./backfill.sh --dry-run

# 2. Backfill the past 7 days with duplicate skipping:
./backfill.sh -p my-ge-project -n 7 -y

# 3. Backfill specific date/time range:
./backfill.sh \
  -p my-ge-project \
  --start-time="2026-08-26T00:00:00Z" \
  --end-time="2026-09-02T12:00:00Z" \
  -y

# 4. Backfill a specific stream (e.g., client telemetry only):
./backfill.sh -s client_telemetry -n 14 -y
```

### Backfill Flag Reference

| Flag | Default | Description |
| :--- | :--- | :--- |
| `-c`, `--config FILE` | `config.yaml` | Path to YAML configuration file |
| `-p`, `--project-id ID` | Active `gcloud` project | Source GCP project hosting Cloud Logging & BigQuery |
| `-d`, `--dataset-id ID` | `ge_app_agy_telemetry` | Target BigQuery dataset |
| `-n`, `--days DAYS` | `7` | Number of lookback days (up to 30) |
| `--start-time RFC3339` | Calculated from `--days` | Custom ISO/RFC3339 start timestamp |
| `--end-time RFC3339` | Current UTC time | Custom ISO/RFC3339 end timestamp |
| `-s`, `--streams STREAM` | `all` | Target stream (`all`, `inference_response`, `client_telemetry`, `inference_request`) |
| `--skip-existing BOOL` | `true` | Drops records matching existing `insertId` in BigQuery |
| `--exclude-prompts BOOL` | `true` | Excludes raw prompt bodies/diffs for Zero Data Retention |
| `--dry-run` | `false` | Scans and prints record counts without loading to BigQuery |
| `-y`, `--yes` | `false` | Headless execution mode |

---

## Teardown and Cleanup

To remove the dataset, partitioned tables, and logging sink:

### Via Cleanup Script
```bash
# Interactive confirmation:
./cleanup.sh

# Non-interactive force teardown:
./cleanup.sh -p my-ge-project --dataset-id ge_app_agy_telemetry -y -f
```

### Via Terraform
```bash
cd terraform
terraform destroy
```

---

## Next Steps: Analytical Views and Dashboards

Once raw telemetry is streaming into `ge_app_agy_telemetry`:
* **Track 2:** Analytical SQL data marts (`v_antigravity_adoption`, `v_antigravity_trust_quality`, `v_antigravity_token_economics`).
* **Track 3:** Dashboards (Looker Studio executive template & Cloud Monitoring PromQL operational dashboard).

