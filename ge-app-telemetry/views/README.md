# Google Antigravity Analytical Views
`ge-app-telemetry/views`

BigQuery views for Google Antigravity telemetry in Gemini Enterprise. Each view is an **authorized view** that reads the locked RAW dataset (`ge_app_agy_raw`) and lives in the views dataset (`ge_app_agy_telemetry`).

**Privacy rule:** no view returns prompt or response text. Both datasets are locked to project owners.

**Conventions for all views:**
- Times and days are **UTC**.
- Duplicates are removed on `(insertId, timestamp)`.
- `user_email` is `labels.user_id` without the `user:` prefix, or `'unknown'` if missing. Other missing labels show as `'unspecified'`.
- Every column has a description in BigQuery (*Schema* tab).

---

## View Catalog

### 0. `v_ge_app_agy_user_summary`
* **Grain:** one row per `window_days` (rolling **7** and **90** days) × user, **plus an `all_users` row per window** (`scope = 'all_users'`, `user_email = NULL`).
* **Sources:** `inference_response` (usage, tokens) and `client_telemetry` (permission accept/reject).
* **Columns:**
  * Who and when: `window_days`, `scope`, `user_email`, `active_users`.
  * Usage: `inferences`, `trajectories`, `active_days`, `inferences_per_trajectory`.
  * Tokens: `total_tokens`, `prompt_tokens`, `candidates_tokens`, `thoughts_tokens`, `cached_content_tokens`, `avg_tokens_per_inference`, `max_tokens_per_inference`.
  * Models and clients: `models_used`, `top_model`, `clients`, `first_seen`, `last_seen`.
  * Permissions: `permission_requests_total`, `permission_grants_accepted`, `permission_grants_rejected`, `permission_grant_rate`.
  * Share: `token_share`.
* `all_users` rows are computed directly (`GROUPING SETS`), **not summed** from user rows, so distinct counts are exact.

### 1. `v_ge_app_agy_adoption`
* **Grain:** UTC day × user × client × client_version × model. **Source:** `inference_response`.
* **Columns:** `event_date`, `user_email`, `client_name`, `client_version`, `model`, `total_inferences`, `trajectories`, `inferences_per_trajectory`, `active_hours_count`, `first_activity_utc`, `last_activity_utc`.

### 2. `v_ge_app_agy_trust_quality`
* **Grain:** UTC day × user × client × model. **Source:** `client_telemetry`.
* **Columns:** `event_date`, `user_email`, `client_name`, `model`, `total_events`, `trajectories`, `inference_resolved_events`, `permission_requests_total`, `permission_grants_accepted`, `permission_grants_rejected`, `permission_grant_rate`.
* `inference_resolved_events` counts finished turns. It also fires after a rejected permission, so it is **not** a success signal.

### 3. `v_ge_app_agy_token_economics`
* **Grain:** UTC day × user × client × model × experience. **Source:** `inference_response`.
* **Columns:** `event_date`, `user_email`, `client_name`, `model`, `experience`, `total_inferences`, `trajectories`, `total_tokens`, `prompt_tokens`, `candidates_tokens`, `thoughts_tokens`, `cached_content_tokens`, `avg_tokens_per_inference`, `min_tokens_per_inference`, `max_tokens_per_inference`.
* Token columns are raw sums of the logged counters. **No cost or billing estimates** are computed.

### Not reported (by design)
| Metric | Reason |
| :--- | :--- |
| Cost / billing estimates, subscription tier | No billing data in the logs; guesses would be misleading |
| Proposal acceptance / modification | `PROPOSAL_ACCEPTANCE` events have not been observed in live logs |
| Session "resolution rate" | `InferenceResolved` also fires on rejected turns |

---

## Caveats
* **Sessions across days:** `trajectories` is a distinct count per row. Summing daily rows can double count sessions that span midnight. Use `v_ge_app_agy_user_summary` for window totals.
* **Retention:** if RAW retention (`deploy.sh -r`) is under 90 days, the 90-day window contains less data.

---

## Deployment

`direct-log-sink-to-bq/deploy.sh` deploys and authorizes these views automatically. To redeploy them on their own:

```bash
./deploy_views.sh -p <PROJECT_ID> -d ge_app_agy_telemetry --raw-dataset-id ge_app_agy_raw -y
```
The script substitutes `{{PROJECT_ID}}`, `{{DATASET_ID}}` and `{{RAW_DATASET_ID}}`, creates or replaces each view, and adds each view to the RAW dataset's access list (authorized view).

---

## Sample Queries

### Team totals for the last 7 and 90 days
```sql
SELECT window_days, active_users, inferences, trajectories, total_tokens, permission_grant_rate
FROM `<PROJECT_ID>.ge_app_agy_telemetry.v_ge_app_agy_user_summary`
WHERE scope = 'all_users'
ORDER BY window_days;
```

### Top users by tokens (last 7 days)
```sql
SELECT user_email, inferences, trajectories, total_tokens, token_share, top_model
FROM `<PROJECT_ID>.ge_app_agy_telemetry.v_ge_app_agy_user_summary`
WHERE scope = 'user' AND window_days = 7
ORDER BY total_tokens DESC
LIMIT 20;
```

### Daily active users and sessions
```sql
SELECT event_date, COUNT(DISTINCT user_email) AS daily_active_users, SUM(total_inferences) AS inferences
FROM `<PROJECT_ID>.ge_app_agy_telemetry.v_ge_app_agy_adoption`
GROUP BY event_date
ORDER BY event_date DESC;
```

### Tokens by model and type
```sql
SELECT model, SUM(prompt_tokens) AS prompt, SUM(candidates_tokens) AS output,
       SUM(thoughts_tokens) AS thinking, SUM(cached_content_tokens) AS cached, SUM(total_tokens) AS total
FROM `<PROJECT_ID>.ge_app_agy_telemetry.v_ge_app_agy_token_economics`
WHERE event_date >= DATE_SUB(CURRENT_DATE(), INTERVAL 30 DAY)
GROUP BY model
ORDER BY total DESC;
```
