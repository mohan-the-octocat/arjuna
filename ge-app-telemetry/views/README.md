# Google Antigravity Analytical Views (Data Marts)
`ge-app-telemetry/views`

This directory provides standardized BigQuery SQL views for analyzing Google Antigravity developer telemetry in Gemini Enterprise.

---

## View Catalog

### 1. `v_ge_app_agy_adoption`
* **Source:** `businessaicode_googleapis_com_inference_response`
* **Granularity:** Daily per user, per client surface, per model.
* **Key Metrics:**
  * `total_inferences`: Number of prompt/response turns executed.
  * `active_trajectories`: Number of distinct agent task sessions.
  * `inferences_per_trajectory`: Session depth (interaction density).
  * `active_hours_count`: Hours with active usage across the day.
  * `first_activity_utc` / `last_activity_utc`: First and last activity timestamps.

### 2. `v_ge_app_agy_trust_quality`
* **Source:** `businessaicode_googleapis_com_client_telemetry`
* **Granularity:** Daily per user, per client surface, per model.
* **Key Metrics:**
  * `resolved_trajectories`: Sessions reaching completion (`InferenceResolved`).
  * `trajectory_resolution_rate`: Ratio of completed vs abandoned sessions.
  * `permission_requests_total`, `permission_grants_accepted`, `permission_grants_rejected`.
  * `permission_grant_rate`: Approval rate on shell/file execution permissions.
  * `proposals_total`, `proposals_accepted`, `proposals_modified`, `proposals_rejected`.
  * `proposal_acceptance_rate`: Percentage of suggestions accepted unchanged.
  * `proposal_modification_rate`: Percentage of suggestions accepted with developer edits.

### 3. `v_ge_app_agy_token_economics`
* **Source:** `businessaicode_googleapis_com_inference_response`
* **Granularity:** Daily per user, per model, per experience tier.
* **Key Metrics:**
  * `total_tokens`: Aggregate token count (`metadata.totalTokenCount`).
  * `avg_tokens_per_inference`: Average context size per turn.
  * `avg_tokens_per_trajectory`: Session-level token consumption proxy.
  * `estimated_cost_usd_list`: Standard blended list rate ($0.15 / 1M tokens).
  * `estimated_cost_usd_discounted`: Rate with 50% Flash promotional discount ($0.075 / 1M tokens).
  * `subscription_tier_type`: Classifies interactive seat usage (`SEAT_INCLUDED`) vs automation.

---

## Resiliency and Deduplication

All three views embed an automated deduplication CTE:
```sql
QUALIFY ROW_NUMBER() OVER(PARTITION BY insertId ORDER BY timestamp DESC) = 1
```
This ensures downstream dashboard queries and reports never encounter duplicate records from network retries or backfill executions.

---

## Deployment

Deploy or update all views using `deploy_views.sh`:

```bash
# Deploy to active gcloud project:
./deploy_views.sh

# Deploy to specific project headlessly:
./deploy_views.sh -p <PROJECT_ID> -d ge_app_agy_telemetry -y
```

---

## Sample Analytical Queries

### 1. Daily Active Users and Session Depth (Adoption)
```sql
SELECT 
  event_date,
  COUNT(DISTINCT user_email) AS daily_active_users,
  SUM(total_inferences) AS total_inferences,
  SUM(active_trajectories) AS total_sessions,
  ROUND(SAFE_DIVIDE(SUM(total_inferences), SUM(active_trajectories)), 2) AS avg_session_depth
FROM 
  `<PROJECT_ID>.ge_app_agy_telemetry.v_ge_app_agy_adoption`
GROUP BY 
  event_date
ORDER BY 
  event_date DESC;
```

### 2. Proposal Acceptance and Intervention Rates (Trust & Quality)
```sql
SELECT 
  event_date,
  client_name,
  SUM(proposals_total) AS total_proposals,
  ROUND(SAFE_DIVIDE(SUM(proposals_accepted), SUM(proposals_total)) * 100, 1) AS acceptance_rate_pct,
  ROUND(SAFE_DIVIDE(SUM(proposals_modified), SUM(proposals_total)) * 100, 1) AS modification_rate_pct,
  ROUND(SAFE_DIVIDE(SUM(permission_grants_accepted), SUM(permission_requests_total)) * 100, 1) AS permission_grant_rate_pct
FROM 
  `<PROJECT_ID>.ge_app_agy_telemetry.v_ge_app_agy_trust_quality`
GROUP BY 
  event_date, client_name
ORDER BY 
  event_date DESC;
```

### 3. Token Consumption and Spend Attribution by Model (FinOps)
```sql
SELECT 
  model,
  experience,
  SUM(total_inferences) AS total_turns,
  SUM(total_tokens) AS total_tokens,
  ROUND(SUM(estimated_cost_usd_discounted), 4) AS estimated_spend_usd
FROM 
  `<PROJECT_ID>.ge_app_agy_telemetry.v_ge_app_agy_token_economics`
GROUP BY 
  model, experience
ORDER BY 
  total_tokens DESC;
```
