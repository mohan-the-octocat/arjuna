# Implementation Guide: Observability, Compliance Telemetry, and Custom IAM Governance for Google Antigravity in Gemini Enterprise

This guide provides an end-to-end technical reference for enterprise platform administrators, security engineers, and FinOps practitioners implementing telemetry, compliance logging, analytics, and selective access governance for Google Antigravity within Gemini Enterprise.

All procedures and architectures in this guide use native Google Cloud Platform (GCP) services—including Google Cloud Console, `gcloud` CLI, Cloud Logging, BigQuery, Cloud IAM, Cloud Run Jobs, and Cloud Scheduler—providing a vendor-neutral, 0-to-1 blueprint for enterprise deployment.

---

## 1. Architectural Overview

Managing developer access and telemetry for generative AI tools requires two decoupled, coordinated planes:

1. **The Observability & Compliance Plane:** Collects runtime telemetry across developer interaction turns, streams audit and token events into Cloud Logging (`businessaicode.googleapis.com`), routes them via Log Router sinks into a dedicated BigQuery dataset (`ge_app_agy_telemetry`), and surfaces analytics via three foundational data marts (`v_ge_app_agy_adoption`, `v_ge_app_agy_trust_quality`, `v_ge_app_agy_token_economics`) and Looker Studio dashboards.
2. **The Access Governance & Quota Plane:** Inspects consumption against organization-defined quotas, classifies user entitlements using a deterministic 6-state IAM decision model, enforces 5 deterministic safety gates, and executes atomic IAM policy mutations using Custom Marker Roles without disabling standard Gemini Enterprise search or conversational capabilities.

```
+-----------------------------------------------------------------------------------+
|                                 DEVELOPER CLIENTS                                 |
|                       (IDE Extensions, Antigravity CLI, Web UI)                   |
+-----------------------------------------------------------------------------------+
                                         |
                                         | API Calls (businessaicode.googleapis.com)
                                         v
+-----------------------------------------------------------------------------------+
|                            GEMINI ENTERPRISE BACKEND                              |
|           - Settings: Security Policies, Compliance Logging, Model Toggles        |
|           - Authorization: Cloud IAM (Base vs. Custom Roles)                     |
+-----------------------------------------------------------------------------------+
                                         |
                                         | Telemetry & Audit Logs (Resource: BAICInstance)
                                         v
+-----------------------------------------------------------------------------------+
|                               GOOGLE CLOUD LOGGING                                |
|    Streams: inference_response, client_telemetry, inference_request               |
+-----------------------------------------------------------------------------------+
                   |                                             |
                   | Push Log Sink (ge-app-agy-telemetry-sink)   | Filter Query API
                   v                                             v
+-------------------------------------+       +-------------------------------------+
|           GOOGLE BIGQUERY           |       |            CLOUD RUN JOB            |
|    Dataset: ge_app_agy_telemetry    |       |      (Scheduled Batch Evaluator)    |
| - Daily Partitioned Raw Tables      |       | - Evaluates G1-G5 Safety Gates      |
| - v_ge_app_agy_adoption (DAU/WAU)   |       | - 6-State IAM Decision Machine       |
| - v_ge_app_agy_trust_quality        |       | - Applies Custom Marker Roles       |
| - v_ge_app_agy_token_economics      |       | - Emits admin audit events          |
+-------------------------------------+       +-------------------------------------+
                   |                                             |
                   v                                             v
+-------------------------------------+       +-------------------------------------+
|     LOOKER STUDIO / LOCAL WEB       |       |           CLOUD IAM POLICY          |
|    Executive Adoption & Cost Dash   |       |   (roles/discoveryengine.agentspace |
|    (Scorecards: HAU, DAU, WAU, MAU) |       |    vs. CustomAntigravityCapBlocked) |
+-------------------------------------+       +-------------------------------------+
```

---

## 2. Gemini Enterprise Admin Settings & Telemetry Configuration

Before log capture begins, administrative policies and compliance logging must be configured in the Google Cloud Console.

### 2.1 Navigation
1. Open the **Google Cloud Console** (`https://console.cloud.google.com`).
2. Navigate to **Gemini Enterprise > Settings**.
3. Select the **AI developer tools** tab.

### 2.2 Core Activation
- Toggle **AI developer tools** to **Enabled**.
  - *Effect:* Authorizes licensed Gemini Enterprise users with valid IAM roles to execute coding, testing, and automated terminal actions from Antigravity.

### 2.3 Security Policies
Configure the execution boundaries for developers using the tool:
- **Outside of file access policy:** Set to `Always ask` to require user confirmation before inspecting or modifying files outside the active workspace.
- **Terminal auto-execution mode:** Set to `Require review` to enforce human-in-the-loop validation before commands run in the local terminal.
- **Sandbox mode:** Toggle based on internal developer environment requirements.
- **Browser access:** Set to `Enabled`, with **Browser JavaScript execution policy** set to `Request review`.
- **MCP servers:** Toggle `Enabled` or `Disabled` depending on whether internal Model Context Protocol servers are permitted.

### 2.4 Compliance and Logging Configuration
Under the **Compliance** section, select **Edit** to configure logging and retention policies to meet internal legal and regulatory requirements:
- **Metadata logging:** Set to **Enabled**.
  - Records operational request metadata including token counts (`totalTokenCount`, `inputTokenCount`, `outputTokenCount`), latency, timestamps, authenticated user identities (`labels.user_id`), client surfaces, and model IDs.
- **Prompts and responses logging:** Set to **Enabled**.
  - Captures developer prompts, context references, and model responses into Cloud Logging (`jsonPayload.request.prompt` and `jsonPayload.response.candidates`) for security auditing, compliance reviews, and governance.
  - *Alternative (Metadata-Only):* When set to **Disabled**, prompt text and response bodies are omitted from Cloud Logging, persisting only operational metadata.

### 2.5 Model Availability
Under **Model availability**, choose whether **Antigravity authorized models** allows `All models` or restrict developer execution to specific corporate-approved foundational models (such as `gemini-1.5-pro` or `gemini-1.5-flash`).

---

## 3. Log Routing and Centralization (Cloud Logging to BigQuery)

### 3.1 Telemetry Resource & Log Streams
All Antigravity telemetry is emitted under the monitored resource:
- **`resource.type`**: `businessaicode.googleapis.com/BAICInstance`
- **`resource.labels.location`**: `global` (or regional)
- **`resource.labels.resource_container`**: Numeric GCP Project Number

Three distinct log streams are produced:
1. `businessaicode.googleapis.com%2Finference_response`: Emitted upon completion of every model inference turn. Contains token consumption, latency, model experience, and response metadata.
2. `businessaicode.googleapis.com%2Fclient_telemetry`: Emitted for developer interactions and milestones. Contains event types (`InferenceInteraction`, `InferenceResolved`), interaction types (`PROPOSAL_ACCEPTANCE`, `PERMISSION_GRANT`), and outcomes (`ACCEPTED`, `REJECTED`, `MODIFIED`).
3. `businessaicode.googleapis.com%2Finference_request`: Emitted when an inference turn begins. Contains conversational messages, context files, and developer instructions (subject to prompt logging configuration).

### 3.2 Setting Up the Dedicated BigQuery Dataset

Create a dedicated dataset (`ge_app_agy_telemetry`) with regional residency and an automated daily partition expiration policy (default: 90 days):

```bash
# Configuration Variables
export PROJECT_ID="your-gcp-project-id"
export REGION="us-central1"
export DATASET_ID="ge_app_agy_telemetry"
export RETENTION_DAYS="90"

# Compute default partition expiration in seconds (90 days = 7,776,000 seconds)
export EXPIRATION_SEC=$(( RETENTION_DAYS * 86400 ))

# Create BigQuery Dataset with partition expiration
bq --location="${REGION}" mk \
  --dataset \
  --default_partition_expiration="${EXPIRATION_SEC}" \
  --description "Gemini Enterprise Antigravity Telemetry Repository (90-day retention)" \
  "${PROJECT_ID}:${DATASET_ID}"
```

### 3.3 Creating the Log Router Sink
Deploy the Log Router Sink that filters across all Antigravity streams under the `BAICInstance` resource:

```bash
export SINK_NAME="ge-app-agy-telemetry-sink"

# Deploy Log Router Sink streaming to BigQuery with partitioned tables
gcloud logging sinks create "${SINK_NAME}" \
  "bigquery.googleapis.com/projects/${PROJECT_ID}/datasets/${DATASET_ID}" \
  --log-filter='resource.type="businessaicode.googleapis.com/BAICInstance" AND logName =~ "businessaicode.googleapis.com"' \
  --use-partitioned-tables \
  --project="${PROJECT_ID}"
```

### 3.4 Authorizing the Sink Writer Identity
Cloud Logging assigns a unique service account to write into BigQuery. Grant this identity `roles/bigquery.dataEditor` scoped strictly to the telemetry dataset:

```bash
# Retrieve the service account identity generated by Cloud Logging
export SINK_WRITER_IDENTITY=$(gcloud logging sinks describe "${SINK_NAME}" \
  --project="${PROJECT_ID}" \
  --format='value(writerIdentity)')

echo "Sink Writer Identity: ${SINK_WRITER_IDENTITY}"

# Grant BigQuery Data Editor permission on the dataset
bq add-iam-policy-binding \
  --member="${SINK_WRITER_IDENTITY}" \
  --role="roles/bigquery.dataEditor" \
  "${PROJECT_ID}:${DATASET_ID}"
```

Once granted, incoming log events stream into three partitioned tables:
- `ge_app_agy_telemetry.businessaicode_googleapis_com_inference_response`
- `ge_app_agy_telemetry.businessaicode_googleapis_com_client_telemetry`
- `ge_app_agy_telemetry.businessaicode_googleapis_com_inference_request`

---

## 4. Analytical SQL Data Marts

To deliver actionable reporting without pipeline latency, deploy three standardized BigQuery analytical data mart views, plus a rolling adoption scorecard view.

### 4.1 View 1: Developer Adoption Mart (`v_ge_app_agy_adoption`)
Tracks daily active users, session trajectories, inference volume, and surface distribution. It deduplicates incoming log entries on `insertId` and normalizes the `user:` prefix in `labels.user_id`:

```sql
CREATE OR REPLACE VIEW `ge_app_agy_telemetry.v_ge_app_agy_adoption`
OPTIONS(
  description = "Antigravity developer adoption mart: daily active users, session trajectories, inference volume, and surface breakdown."
) AS
WITH raw_deduped AS (
  SELECT
    timestamp,
    insertId,
    labels.user_id AS raw_user_id,
    labels.trajectory_id,
    labels.request_id,
    labels.client_name,
    labels.client_version,
    labels.model
  FROM
    `ge_app_agy_telemetry.businessaicode_googleapis_com_inference_response`
  WHERE
    timestamp IS NOT NULL
  QUALIFY ROW_NUMBER() OVER(PARTITION BY insertId ORDER BY timestamp DESC) = 1
)
SELECT
  DATE(timestamp) AS event_date,
  REGEXP_REPLACE(raw_user_id, r'^user:', '') AS user_email,
  COALESCE(client_name, 'unspecified') AS client_name,
  COALESCE(client_version, 'unspecified') AS client_version,
  COALESCE(model, 'unspecified') AS model,
  COUNT(request_id) AS total_inferences,
  COUNT(DISTINCT trajectory_id) AS active_trajectories,
  ROUND(SAFE_DIVIDE(COUNT(request_id), COUNT(DISTINCT trajectory_id)), 2) AS inferences_per_trajectory,
  COUNT(DISTINCT EXTRACT(HOUR FROM timestamp)) AS active_hours_count,
  MIN(timestamp) AS first_activity_utc,
  MAX(timestamp) AS last_activity_utc
FROM
  raw_deduped
GROUP BY
  1, 2, 3, 4, 5;
```

### 4.2 View 2: Agent Trust and Quality Mart (`v_ge_app_agy_trust_quality`)
Evaluates developer trust by analyzing code diff proposals, modification rates, terminal permission grants, and full session resolutions:

```sql
CREATE OR REPLACE VIEW `ge_app_agy_telemetry.v_ge_app_agy_trust_quality`
OPTIONS(
  description = "Antigravity trust and quality mart: proposal acceptances, code modification rates, permission grants, and session resolution rates."
) AS
WITH raw_deduped AS (
  SELECT
    timestamp,
    insertId,
    labels.user_id AS raw_user_id,
    labels.trajectory_id,
    labels.request_id,
    labels.client_name,
    labels.model,
    jsonpayload_v1_clienttelemetrylog.eventtype AS event_type,
    jsonpayload_v1_clienttelemetrylog.metadata.interactiontype AS interaction_type,
    jsonpayload_v1_clienttelemetrylog.metadata.interactionoutcome AS interaction_outcome
  FROM
    `ge_app_agy_telemetry.businessaicode_googleapis_com_client_telemetry`
  WHERE
    timestamp IS NOT NULL
  QUALIFY ROW_NUMBER() OVER(PARTITION BY insertId ORDER BY timestamp DESC) = 1
)
SELECT
  DATE(timestamp) AS event_date,
  REGEXP_REPLACE(raw_user_id, r'^user:', '') AS user_email,
  COALESCE(client_name, 'unspecified') AS client_name,
  COALESCE(model, 'unspecified') AS model,
  COUNT(1) AS total_events,
  -- Trajectory Resolution
  COUNT(DISTINCT IF(event_type = 'InferenceResolved', trajectory_id, NULL)) AS resolved_trajectories,
  COUNT(DISTINCT trajectory_id) AS total_trajectories,
  ROUND(SAFE_DIVIDE(
    COUNT(DISTINCT IF(event_type = 'InferenceResolved', trajectory_id, NULL)),
    NULLIF(COUNT(DISTINCT trajectory_id), 0)
  ), 4) AS trajectory_resolution_rate,
  -- Permission Grants (Terminal / File / Tools)
  COUNTIF(interaction_type = 'PERMISSION_GRANT') AS permission_requests_total,
  COUNTIF(interaction_type = 'PERMISSION_GRANT' AND interaction_outcome = 'ACCEPTED') AS permission_grants_accepted,
  COUNTIF(interaction_type = 'PERMISSION_GRANT' AND interaction_outcome = 'REJECTED') AS permission_grants_rejected,
  ROUND(SAFE_DIVIDE(
    COUNTIF(interaction_type = 'PERMISSION_GRANT' AND interaction_outcome = 'ACCEPTED'),
    NULLIF(COUNTIF(interaction_type = 'PERMISSION_GRANT'), 0)
  ), 4) AS permission_grant_rate,
  -- Code Proposal Acceptance
  COUNTIF(interaction_type = 'PROPOSAL_ACCEPTANCE') AS proposals_total,
  COUNTIF(interaction_type = 'PROPOSAL_ACCEPTANCE' AND interaction_outcome = 'ACCEPTED') AS proposals_accepted,
  COUNTIF(interaction_type = 'PROPOSAL_ACCEPTANCE' AND interaction_outcome = 'MODIFIED') AS proposals_modified,
  COUNTIF(interaction_type = 'PROPOSAL_ACCEPTANCE' AND interaction_outcome = 'REJECTED') AS proposals_rejected,
  ROUND(SAFE_DIVIDE(
    COUNTIF(interaction_type = 'PROPOSAL_ACCEPTANCE' AND interaction_outcome = 'ACCEPTED'),
    NULLIF(COUNTIF(interaction_type = 'PROPOSAL_ACCEPTANCE'), 0)
  ), 4) AS proposal_acceptance_rate
FROM
  raw_deduped
GROUP BY
  1, 2, 3, 4;
```

### 4.3 View 3: Token Economics and FinOps Mart (`v_ge_app_agy_token_economics`)
Calculates token consumption volumes, turn context depth, and showback costs (comparing list rates against promotional tiers):

```sql
CREATE OR REPLACE VIEW `ge_app_agy_telemetry.v_ge_app_agy_token_economics`
OPTIONS(
  description = "Antigravity token consumption and FinOps mart: per-user token volumes, context sizes, estimated costs, and subscription tier classification."
) AS
WITH raw_deduped AS (
  SELECT
    timestamp,
    insertId,
    labels.user_id AS raw_user_id,
    labels.trajectory_id,
    labels.request_id,
    labels.client_name,
    labels.model,
    jsonpayload_v1_inferenceresponselog.experience,
    SAFE_CAST(jsonpayload_v1_inferenceresponselog.metadata.totaltokencount AS INT64) AS total_token_count
  FROM
    `ge_app_agy_telemetry.businessaicode_googleapis_com_inference_response`
  WHERE
    timestamp IS NOT NULL
  QUALIFY ROW_NUMBER() OVER(PARTITION BY insertId ORDER BY timestamp DESC) = 1
)
SELECT
  DATE(timestamp) AS event_date,
  REGEXP_REPLACE(raw_user_id, r'^user:', '') AS user_email,
  COALESCE(client_name, 'unspecified') AS client_name,
  COALESCE(model, 'unspecified') AS model,
  COALESCE(experience, 'unspecified') AS experience,
  COUNT(1) AS total_inferences,
  SUM(COALESCE(total_token_count, 0)) AS total_tokens,
  ROUND(AVG(COALESCE(total_token_count, 0)), 2) AS avg_tokens_per_inference,
  MIN(total_token_count) AS min_tokens_in_turn,
  MAX(total_token_count) AS max_tokens_in_turn,
  COUNT(DISTINCT trajectory_id) AS active_trajectories,
  ROUND(SAFE_DIVIDE(
    SUM(COALESCE(total_token_count, 0)),
    NULLIF(COUNT(DISTINCT trajectory_id), 0)
  ), 2) AS avg_tokens_per_trajectory,
  -- List cost calculation ($0.15 per 1M tokens)
  ROUND(SUM(COALESCE(total_token_count, 0)) * 0.00000015, 4) AS estimated_cost_usd_list,
  -- Promotional discount rate ($0.075 per 1M tokens)
  ROUND(SUM(COALESCE(total_token_count, 0)) * 0.000000075, 4) AS estimated_cost_usd_discounted,
  -- Subscription Tier
  CASE
    WHEN client_name IN ('antigravity_hub', 'antigravity_cli', 'vscode') THEN 'SEAT_INCLUDED'
    ELSE 'PAYGO_AUTOMATION'
  END AS subscription_tier_type
FROM
  raw_deduped
GROUP BY
  1, 2, 3, 4, 5, 15;
```

### 4.4 Rolling Active User Adoption View (HAU / DAU / WAU / MAU)
This query powers executive adoption scorecards and time-series graphs matching Cloud Monitoring and Looker Studio:

```sql
CREATE OR REPLACE VIEW `ge_app_agy_telemetry.v_active_user_metrics` AS
WITH snapshot_time AS (
  SELECT CURRENT_TIMESTAMP() AS now
),
events AS (
  SELECT
    timestamp,
    REGEXP_REPLACE(labels.user_id, r'^user:', '') AS user_email
  FROM
    `ge_app_agy_telemetry.businessaicode_googleapis_com_inference_response`
  WHERE
    timestamp IS NOT NULL
    AND labels.user_id IS NOT NULL
)
SELECT
  (SELECT COUNT(DISTINCT user_email) FROM events, snapshot_time WHERE timestamp >= TIMESTAMP_SUB(snapshot_time.now, INTERVAL 1 HOUR)) AS hau,
  (SELECT COUNT(DISTINCT user_email) FROM events, snapshot_time WHERE timestamp >= TIMESTAMP_SUB(snapshot_time.now, INTERVAL 24 HOUR)) AS dau,
  (SELECT COUNT(DISTINCT user_email) FROM events, snapshot_time WHERE timestamp >= TIMESTAMP_SUB(snapshot_time.now, INTERVAL 7 DAY)) AS wau,
  (SELECT COUNT(DISTINCT user_email) FROM events, snapshot_time WHERE timestamp >= TIMESTAMP_SUB(snapshot_time.now, INTERVAL 30 DAY)) AS mau;
```

---

## 5. Selective Access Control and Custom IAM Roles

### 5.1 The Access Dilemma
In Gemini Enterprise, standard user access is provided by the predefined role:
`roles/discoveryengine.agentspaceUser` (Gemini Enterprise User).

This role bundles:
1. Gemini Enterprise search, general chat, and document grounding.
2. AI developer tools and Antigravity execution permissions (`businessaicode.*`).

If an administrator strips `roles/discoveryengine.agentspaceUser` to curb excessive Antigravity usage or restrict unapproved developers, **the user is locked out of basic enterprise search and chat**.

### 5.2 The Custom Role Solution
As documented in Google Cloud's official documentation ([Create a custom role to restrict access to AI developer tools](https://docs.cloud.google.com/gemini/enterprise/docs/ai-developer-tools-creating-custom-roles)), organizations can restrict Antigravity by cloning `roles/discoveryengine.agentspaceUser` and omitting all permissions starting with `businessaicode.`.

Users assigned this custom role retain full access to Gemini Enterprise search and chat, but Antigravity calls are blocked with `PERMISSION_DENIED`.

### 5.3 Defining Dual Marker Roles
To automate quota capping safely without race conditions or unintended restorations, systems must distinguish between **automatic quota capping** and **manual administrative revocation**:

| Role ID | Purpose | Managed By | Eligible for Auto-Restore? |
| :--- | :--- | :--- | :--- |
| `CustomAntigravityCapBlocked` | Applied when user exceeds usage quota | Automated Batch Job | **Yes** (when quota window resets) |
| `CustomAntigravityAdminBlocked` | Applied when admin manually revokes Antigravity | IT Administrator | **No** (requires explicit admin allow) |
| `CustomAntigravityRestrictedUser` | Legacy single marker role | Legacy Deployments | Treated as Admin Blocked (immune to restore) |

### 5.4 Creating the Marker Roles via CLI

Generate the role definitions by inspecting `roles/discoveryengine.agentspaceUser`, filtering out `businessaicode.*` and `resourcemanager.projects.list`:

```bash
# Fetch base permissions from roles/discoveryengine.agentspaceUser excluding businessaicode.*
PERMS=$(gcloud iam roles describe roles/discoveryengine.agentspaceUser \
  --format="value(includedPermissions)" \
  | tr ';' '\n' \
  | grep -v '^businessaicode\.' \
  | grep -v '^resourcemanager\.projects\.list' \
  | paste -sd, -)

# 1. Create the Cap-Blocked Custom Role (for automated quota management)
gcloud iam roles create CustomAntigravityCapBlocked \
  --project="${PROJECT_ID}" \
  --title="Custom Gemini Enterprise Cap Blocked User" \
  --description="Restricts AI developer tools due to quota capping while preserving Gemini Enterprise search and chat." \
  --permissions="${PERMS}" \
  --stage="GA"

# 2. Create the Admin-Blocked Custom Role (for manual administrative blocking)
gcloud iam roles create CustomAntigravityAdminBlocked \
  --project="${PROJECT_ID}" \
  --title="Custom Gemini Enterprise Admin Blocked User" \
  --description="Restricts AI developer tools due to administrative decision while preserving Gemini Enterprise search and chat." \
  --permissions="${PERMS}" \
  --stage="GA"
```

---

## 6. Automated Quota Enforcement Engine (Batch Architecture)

To implement a reliable rate-limiting and quota capping worker, run a scheduled batch container on Cloud Run Jobs that evaluates user metrics and modifies IAM policy bindings.

### 6.1 The 6-State IAM Decision Model
Before mutating any IAM policy, every user entity must be classified into a mutually exclusive state (Rules R1 through R9):

```
                                  [ User Principal ]
                                          |
                         +----------------+----------------+
                         |                                 |
                 Direct "user:" Binding?           Group / Domain / Ancestor /
                         |                         Admin Role Binding?
                         |                                 |
                +--------+--------+                        v
                |                 |                 [ NOT_ENFORCEABLE ]
          Allowed Role?     Marker Role?            (Manual Action Required;
                |                 |                  Refuse Auto-Mutation)
                v                 |
      [ ENFORCEABLE_ALLOWED ]     +------------------+
      (Eligible for Auto-Cap)     |                  |
                       CapBlocked Role?    AdminBlocked Role?
                                  |                  |
                                  v                  v
                         [ CAPPED_BY_TOOL ]  [ BLOCKED_BY_ADMIN ]
                         (Eligible for       (Immune to Auto-Restore)
                          Auto-Restore)
```

1. **`ENFORCEABLE_ALLOWED`**: Direct binding on `roles/discoveryengine.agentspaceUser`. Only state eligible for automated capping.
2. **`CAPPED_BY_TOOL`**: Direct binding on `CustomAntigravityCapBlocked`. Eligible for automatic restoration when consumption falls below limits or window resets.
3. **`BLOCKED_BY_ADMIN`**: Direct binding on `CustomAntigravityAdminBlocked` (or legacy `CustomAntigravityRestrictedUser`). **Never restored automatically**.
4. **`NOT_ENFORCEABLE`**: Principal receives access through Google Groups (`group:`), Workspace domains (`domain:`), inherited organization/folder bindings, or privileged administrative roles (`roles/owner`, `roles/editor`, `roles/discoveryengine.admin`, `roles/discoveryengine.editor`, `roles/discoveryengine.agentspaceAdmin`). The worker **refuses mutation** and alerts administrators.
5. **`NO_ACCESS`**: User has no active bindings on the project.
6. **`UNKNOWN`**: Policy read failure or indeterminate state; triggers safety abort.

### 6.2 The 5 Safety Gates
To prevent mass lockouts caused by telemetry latency or API degradations, the batch worker must pass five deterministic gates before committing changes:
- **`G1_POLICY_READABLE`**: If Cloud IAM fails to return the project policy, abort cycle immediately (Exit code 3).
- **`G2_ANY_DETERMINATE`**: If no users resolve to an enforceable state, abort cycle.
- **`G3_TELEMETRY_HEALTHY`**: If Cloud Logging queries fail or return 0 rows, **withhold all automatic un-capping operations**. This prevents logging service interruptions from prematurely unblocking capped users.
- **`G4_CHANGE_BUDGET` (Circuit Breaker):** If planned IAM mutations exceed `max(10, 20% of the active user population)`, abort cycle and raise an alert.
- **`G5_NON_USER_GRANT_ABSENT`**: Flag and refuse automated actions for users whose effective access is granted via non-user principals (`group:`, `domain:`).

### 6.3 Reference Python Implementation

Below is a complete, self-contained reference script (`quota_enforcer.py`) using the official Google Cloud Python client libraries, incorporating the safety gates, the 6-state model, and administrative audit logging to `projects/{PROJECT_ID}/logs/antigravity-admin%2Factions`:

```python
"""
quota_enforcer.py
Independent reference script for Gemini Enterprise Antigravity Quota Enforcement.
Dependencies: google-cloud-resourcemanager>=3.14.0, google-cloud-logging>=3.11.0
"""

import os
import sys
from datetime import datetime, timezone
from typing import Dict, List, Set, Tuple
from google.cloud import resourcemanager_v3
from google.cloud import logging_v2

# Configuration
PROJECT_ID = os.environ.get("GCP_PROJECT_ID")
DAILY_TOKEN_CAP = int(os.environ.get("DAILY_TOKEN_CAP", "500000"))
DAILY_REQUEST_CAP = int(os.environ.get("DAILY_REQUEST_CAP", "1000"))
MAX_CHANGE_PERCENT = 0.20
MIN_CHANGE_FLOOR = 10

ROLE_BASE = os.environ.get("AGY_ALLOWED_ROLE", "roles/discoveryengine.agentspaceUser")
ROLE_CAP = f"projects/{PROJECT_ID}/roles/CustomAntigravityCapBlocked"
ROLE_ADMIN = f"projects/{PROJECT_ID}/roles/CustomAntigravityAdminBlocked"
ROLE_LEGACY = f"projects/{PROJECT_ID}/roles/CustomAntigravityRestrictedUser"

PRIVILEGED_ROLES = {
    "roles/owner",
    "roles/editor",
}

OTHER_ACCESS_ROLES = {
    "roles/discoveryengine.admin",
    "roles/discoveryengine.editor",
    "roles/discoveryengine.agentspaceAdmin",
}


def query_daily_consumption(project_id: str) -> Tuple[Dict[str, Tuple[int, int]], int]:
    """Queries Cloud Logging for the current UTC day's usage per user."""
    client = logging_v2.LoggingServiceV2Client()
    start_of_day = datetime.now(timezone.utc).replace(
        hour=0, minute=0, second=0, microsecond=0
    ).isoformat()

    log_filter = (
        f'log_id("businessaicode.googleapis.com/inference_response") AND '
        f'timestamp >= "{start_of_day}"'
    )

    user_metrics: Dict[str, Dict[str, int]] = {}
    total_entries = 0

    entries = client.list_log_entries(
        resource_names=[f"projects/{project_id}"],
        filter_=log_filter,
        page_size=1000,
    )

    for entry in entries:
        total_entries += 1
        raw_user_id = entry.labels.get("user_id", "")
        # Normalize user: prefix if present
        user_id = raw_user_id.replace("user:", "").strip()
        if not user_id:
            continue

        if user_id not in user_metrics:
            user_metrics[user_id] = {"requests": 0, "tokens": 0}

        user_metrics[user_id]["requests"] += 1
        metadata = entry.json_payload.get("metadata", {})
        tokens = int(metadata.get("totalTokenCount", metadata.get("totaltokencount", 0)))
        user_metrics[user_id]["tokens"] += tokens

    return {u: (m["requests"], m["tokens"]) for u, m in user_metrics.items()}, total_entries


def get_iam_policy(project_id: str) -> resourcemanager_v3.Policy:
    """Fetches IAM Policy version 3 with full bindings and conditions."""
    client = resourcemanager_v3.ProjectsClient()
    request = resourcemanager_v3.GetIamPolicyRequest(
        resource=f"projects/{project_id}",
        options={"requested_policy_version": 3}
    )
    return client.get_iam_policy(request=request)


def write_admin_audit_log(project_id: str, action: str, user_email: str, reason: str):
    """Writes administrative audit record to Cloud Logging."""
    try:
        client = logging_v2.LoggingServiceV2Client()
        log_name = f"projects/{project_id}/logs/antigravity-admin%2Factions"
        payload = {
            "action": action,
            "user_email": user_email,
            "reason": reason,
            "actor": "quota_enforcement_worker",
            "timestamp": datetime.now(timezone.utc).isoformat()
        }
        entry = logging_v2.LogEntry(
            log_name=log_name,
            json_payload=payload,
            severity="INFO"
        )
        client.write_log_entries(entries=[entry])
    except Exception as e:
        print(f"Warning: Failed to write audit log: {e}", file=sys.stderr)


def evaluate_and_enforce(project_id: str):
    print(f"Starting Quota Enforcement Cycle for project: {project_id}")

    # 1. Gate 1: IAM Policy Readable
    try:
        policy = get_iam_policy(project_id)
    except Exception as e:
        print(f"Gate 1 Failed: Cannot read IAM policy: {e}", file=sys.stderr)
        sys.exit(3)

    # 2. Extract Principals and Determine Non-Enforceable (Privileged / Group / Domain) Access
    direct_users: Set[str] = set()
    non_enforceable_users: Set[str] = set()

    for binding in policy.bindings:
        for member in binding.members:
            if member.startswith("user:"):
                user_email = member[5:]
                direct_users.add(user_email)
                if binding.role in PRIVILEGED_ROLES or binding.role in OTHER_ACCESS_ROLES:
                    non_enforceable_users.add(user_email)
            elif member.startswith("group:") or member.startswith("domain:"):
                # Gate 5: Flag indirect non-user grants
                print(f"Gate 5 Warning: Detected non-user binding: {binding.role} -> {member}")

    # 3. Gate 2: Any Determinate Users
    if not direct_users:
        print("Gate 2 Failed: No direct user principals found in project policy.", file=sys.stderr)
        sys.exit(3)

    # 4. Fetch Telemetry
    try:
        consumption, log_count = query_daily_consumption(project_id)
    except Exception as e:
        print(f"Telemetry query error: {e}", file=sys.stderr)
        log_count = 0
        consumption = {}

    # Gate 3: Telemetry Health Check
    telemetry_healthy = (log_count > 0)
    if not telemetry_healthy:
        print("Gate 3 Alert: Telemetry unhealthy or 0 rows returned. Automatic restorations withheld.")

    # 5. Classify Users and Determine Ops
    to_cap: Set[str] = set()
    to_restore: Set[str] = set()

    for user in direct_users:
        if user in non_enforceable_users:
            # Rule R6: Skip privileged accounts and non-enforceable grants
            continue

        reqs, tokens = consumption.get(user, (0, 0))
        is_over_cap = (reqs >= DAILY_REQUEST_CAP or tokens >= DAILY_TOKEN_CAP)

        # Check current binding
        is_allowed = any(b.role == ROLE_BASE and f"user:{user}" in b.members for b in policy.bindings)
        is_capped = any(b.role == ROLE_CAP and f"user:{user}" in b.members for b in policy.bindings)
        is_admin_blocked = any(
            (b.role == ROLE_ADMIN or b.role == ROLE_LEGACY) and f"user:{user}" in b.members
            for b in policy.bindings
        )

        if is_admin_blocked:
            # Rule R3 / R8: Admin blocked accounts are strictly immune to automated restoration
            continue

        if is_allowed and is_over_cap:
            to_cap.add(user)
        elif is_capped and not is_over_cap and telemetry_healthy:
            to_restore.add(user)

    total_mutations = len(to_cap) + len(to_restore)
    print(f"Evaluated {len(direct_users)} users: {len(to_cap)} to cap, {len(to_restore)} to restore.")

    # 6. Gate 4: Change Budget / Circuit Breaker
    change_limit = max(MIN_CHANGE_FLOOR, int(len(direct_users) * MAX_CHANGE_PERCENT))
    if total_mutations > change_limit:
        print(f"Gate 4 Circuit Breaker Tripped: {total_mutations} changes exceeds budget limit of {change_limit}.", file=sys.stderr)
        sys.exit(3)

    if total_mutations == 0:
        print("No policy changes required. Cycle complete.")
        return

    # 7. Apply Atomic Policy Modifications
    def add_member(role: str, member: str):
        for b in policy.bindings:
            if b.role == role and not b.condition:
                if member not in b.members:
                    b.members.append(member)
                return
        policy.bindings.append(resourcemanager_v3.Binding(role=role, members=[member]))

    def remove_member(role: str, member: str):
        for b in policy.bindings:
            if b.role == role and not b.condition:
                if member in b.members:
                    b.members.remove(member)

    for user in to_cap:
        member = f"user:{user}"
        remove_member(ROLE_BASE, member)
        add_member(ROLE_CAP, member)
        write_admin_audit_log(project_id, "AUTO_CAP", user, "Exceeded daily token/request threshold")
        print(f"[ACTION] CAPPED: {user}")

    for user in to_restore:
        member = f"user:{user}"
        remove_member(ROLE_CAP, member)
        add_member(ROLE_BASE, member)
        write_admin_audit_log(project_id, "AUTO_RESTORE", user, "Daily quota window reset")
        print(f"[ACTION] RESTORED: {user}")

    # Set updated IAM Policy using optimistic concurrency control (etag)
    client = resourcemanager_v3.ProjectsClient()
    set_request = resourcemanager_v3.SetIamPolicyRequest(
        resource=f"projects/{project_id}",
        policy=policy
    )
    client.set_iam_policy(request=set_request)
    print("IAM Policy updated successfully.")


if __name__ == "__main__":
    if not PROJECT_ID:
        print("Error: GCP_PROJECT_ID environment variable is required.", file=sys.stderr)
        sys.exit(1)
    evaluate_and_enforce(PROJECT_ID)
```

---

## 7. Production Deployment & Scheduled Execution

### 7.1 Containerizing the Worker
Create a lightweight `Dockerfile`:

```dockerfile
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY quota_enforcer.py .
ENTRYPOINT ["python", "quota_enforcer.py"]
```

`requirements.txt`:
```text
google-cloud-resourcemanager>=3.14.0
google-cloud-logging>=3.11.0
```

### 7.2 Service Account Permissions
The batch execution service account requires permissions to read Cloud Logging and update IAM bindings on the project:

```bash
export RUN_SA="sa-antigravity-enforcer@${PROJECT_ID}.iam.gserviceaccount.com"

# Create Service Account
gcloud iam service-accounts create sa-antigravity-enforcer \
  --display-name="Antigravity Quota Enforcement Worker" \
  --project="${PROJECT_ID}"

# Grant Project IAM Admin (to manage bindings)
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${RUN_SA}" \
  --role="roles/resourcemanager.projectIamAdmin"

# Grant Logging Viewer (to inspect consumption logs)
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${RUN_SA}" \
  --role="roles/logging.viewer"
```

### 7.3 Deploying the Cloud Run Job
Build the image and register the Cloud Run Job:

```bash
export IMAGE_URI="gcr.io/${PROJECT_ID}/antigravity-quota-enforcer:v1"

# Build image using Cloud Build
gcloud builds submit --tag "${IMAGE_URI}" .

# Create Cloud Run Job
gcloud run jobs create antigravity-quota-job \
  --image="${IMAGE_URI}" \
  --region="${REGION}" \
  --service-account="${RUN_SA}" \
  --set-env-vars="GCP_PROJECT_ID=${PROJECT_ID},DAILY_TOKEN_CAP=500000,DAILY_REQUEST_CAP=1000" \
  --project="${PROJECT_ID}"
```

### 7.4 Configuring Cloud Scheduler
Trigger the enforcement job periodically (e.g., every 30 minutes) to evaluate active limits:

```bash
gcloud scheduler jobs create http antigravity-quota-trigger \
  --location="${REGION}" \
  --schedule="*/30 * * * *" \
  --uri="https://${REGION}-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/${PROJECT_ID}/jobs/antigravity-quota-job:run" \
  --http-method="POST" \
  --oauth-service-account-email="${RUN_SA}" \
  --project="${PROJECT_ID}"
```

---

## 8. Summary Checklist for Enterprise Implementation

| Milestone | Task | Verification Check |
| :--- | :--- | :--- |
| **1. Admin Console** | Enable AI Developer Tools & Configure Compliance Logging | Verify `Prompts and responses logging` matches corporate retention policy. |
| **2. Log Router** | Create BigQuery Log Sink (`ge-app-agy-telemetry-sink`) | Confirm streaming rows populate `ge_app_agy_telemetry` tables. |
| **3. Dashboards** | Deploy Mart Views (`v_ge_app_agy_adoption`, `trust_quality`, `token_economics`) | Verify HAU, DAU, WAU, and MAU scorecards display active usage. |
| **4. Custom IAM** | Deploy `CustomAntigravityCapBlocked` and `CustomAntigravityAdminBlocked` Roles | Confirm custom roles contain base permissions minus `businessaicode.*`. |
| **5. Batch Engine** | Deploy Cloud Run Job & Cloud Scheduler | Test circuit breaker threshold and confirm atomic swap between allowed and cap roles. |

---

## 9. Official Google Cloud References

- [Google Cloud Documentation: Create a custom role to restrict access to AI developer tools](https://docs.cloud.google.com/gemini/enterprise/docs/ai-developer-tools-creating-custom-roles)
- [Google Cloud Documentation: Gemini Enterprise Access Control](https://docs.cloud.google.com/gemini/enterprise/docs/access-control)
- [Google Cloud Documentation: Export Cloud Logging logs to BigQuery](https://docs.cloud.google.com/logging/docs/export/bigquery)
- [Google Cloud Documentation: Creating and managing custom IAM roles](https://docs.cloud.google.com/iam/docs/creating-custom-roles)
- [Google Cloud Documentation: Cloud Resource Manager REST API v3 (setIamPolicy)](https://docs.cloud.google.com/resource-manager/reference/rest/v3/projects/setIamPolicy)
