-- =============================================================================
-- View 00: v_ge_app_agy_user_summary
-- =============================================================================
-- Grain:   one row per (window_days, user) for window_days IN (7, 90), plus one
--          'all_users' row per window (scope = 'all_users', user_email = NULL).
-- Sources: RAW inference_response (usage, tokens) + RAW client_telemetry
--          (permission accept/reject).
-- Privacy: reads no prompt/response text; outputs metrics only.
-- Correctness notes:
--   * Windows are rolling from query time: timestamp >= CURRENT_TIMESTAMP() - N days
--     (CURRENT_TIMESTAMP() is evaluated once per query, so all CTEs agree).
--   * all_users rows are computed with GROUPING SETS over the same events, so
--     distinct counts (users, sessions, days) are exact — never summed from
--     user rows. scope is derived from GROUPING(), so it cannot collide with a
--     real 'unknown' user.
--   * Response stats and client stats are FULL OUTER JOINed so a user present in
--     only one stream is not dropped.
--   * top_model: exact count, ties broken by model name (deterministic).
--   * Dedupe on (insertId, timestamp). If RAW retention is < 90 days the 90-day
--     window contains less than 90 days of data.
-- Placeholders: {{PROJECT_ID}} {{DATASET_ID}} (views dataset) {{RAW_DATASET_ID}}
-- =============================================================================

CREATE OR REPLACE VIEW `{{PROJECT_ID}}.{{DATASET_ID}}.v_ge_app_agy_user_summary` (
  window_days                OPTIONS(description = "Rolling window length in days (7 or 90), counted back from query time (UTC)."),
  scope                      OPTIONS(description = "'user' = one developer; 'all_users' = everyone combined (computed directly, not summed)."),
  user_email                 OPTIONS(description = "labels.user_id without the 'user:' prefix ('unknown' if missing); NULL on all_users rows."),
  active_users               OPTIONS(description = "Distinct users with at least one model response in the window (1 or 0 on user rows)."),
  inferences                 OPTIONS(description = "Number of model responses (deduplicated inference_response rows)."),
  trajectories               OPTIONS(description = "Distinct labels.trajectory_id (sessions) with at least one response in the window."),
  active_days                OPTIONS(description = "Distinct UTC dates with at least one response."),
  inferences_per_trajectory  OPTIONS(description = "inferences / trajectories (2 decimals); NULL if no trajectory id."),
  total_tokens               OPTIONS(description = "SUM of metadata.totaltokencount."),
  prompt_tokens              OPTIONS(description = "SUM of metadata.prompttokencount."),
  candidates_tokens          OPTIONS(description = "SUM of metadata.candidatestokencount."),
  thoughts_tokens            OPTIONS(description = "SUM of metadata.thoughtstokencount."),
  cached_content_tokens      OPTIONS(description = "SUM of metadata.cachedcontenttokencount."),
  avg_tokens_per_inference   OPTIONS(description = "AVG of metadata.totaltokencount over responses that logged it (2 decimals)."),
  max_tokens_per_inference   OPTIONS(description = "MAX of metadata.totaltokencount."),
  models_used                OPTIONS(description = "Distinct labels.model values."),
  top_model                  OPTIONS(description = "Model with the most responses; ties broken alphabetically."),
  clients                    OPTIONS(description = "Distinct labels.client_name values, sorted, comma-separated."),
  first_seen                 OPTIONS(description = "Earliest response timestamp in the window."),
  last_seen                  OPTIONS(description = "Latest response timestamp in the window."),
  permission_requests_total  OPTIONS(description = "client_telemetry events with metadata.interactiontype = 'PERMISSION_GRANT' in the window."),
  permission_grants_accepted OPTIONS(description = "PERMISSION_GRANT events with interactionoutcome = 'ACCEPTED'."),
  permission_grants_rejected OPTIONS(description = "PERMISSION_GRANT events with interactionoutcome = 'REJECTED'."),
  permission_grant_rate      OPTIONS(description = "permission_grants_accepted / permission_requests_total (4 decimals); NULL if no requests."),
  token_share                OPTIONS(description = "total_tokens / all_users total_tokens in the same window (4 decimals); 1.0 on all_users rows.")
)
OPTIONS(
  description = "Antigravity per-user summary over rolling 7 and 90 day windows, with an all_users row per window. Sources: inference_response + client_telemetry. No prompt text."
) AS
WITH
windows AS (
  SELECT window_days FROM UNNEST([7, 90]) AS window_days
),

-- ---------------------------------------------------------------------------
-- Model responses (usage + tokens), deduplicated and normalized
-- ---------------------------------------------------------------------------
responses AS (
  SELECT
    timestamp,
    COALESCE(NULLIF(REGEXP_REPLACE(labels.user_id, r'^user:', ''), ''), 'unknown') AS user_key,
    labels.trajectory_id                                                          AS trajectory_id,
    COALESCE(labels.model, 'unspecified')                                         AS model_key,
    COALESCE(labels.client_name, 'unspecified')                                   AS client_key,
    SAFE_CAST(jsonpayload_v1_inferenceresponselog.metadata.totaltokencount         AS INT64) AS total_token_count,
    SAFE_CAST(jsonpayload_v1_inferenceresponselog.metadata.prompttokencount        AS INT64) AS prompt_token_count,
    SAFE_CAST(jsonpayload_v1_inferenceresponselog.metadata.candidatestokencount    AS INT64) AS candidates_token_count,
    SAFE_CAST(jsonpayload_v1_inferenceresponselog.metadata.thoughtstokencount      AS INT64) AS thoughts_token_count,
    SAFE_CAST(jsonpayload_v1_inferenceresponselog.metadata.cachedcontenttokencount AS INT64) AS cached_content_token_count
  FROM
    `{{PROJECT_ID}}.{{RAW_DATASET_ID}}.businessaicode_googleapis_com_inference_response`
  WHERE
    timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 90 DAY)
  QUALIFY ROW_NUMBER() OVER (PARTITION BY insertId, timestamp ORDER BY receiveTimestamp DESC) = 1
),
responses_windowed AS (
  SELECT w.window_days, r.*
  FROM responses AS r
  JOIN windows AS w
    ON r.timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL w.window_days DAY)
),
response_stats AS (
  SELECT
    window_days,
    IF(GROUPING(user_key) = 1, 'all_users', 'user')   AS scope,
    IF(GROUPING(user_key) = 1, NULL, user_key)        AS user_email,
    COUNT(DISTINCT user_key)                          AS active_users,
    COUNT(*)                                          AS inferences,
    COUNT(DISTINCT trajectory_id)                     AS trajectories,
    COUNT(DISTINCT DATE(timestamp))                   AS active_days,
    IFNULL(SUM(total_token_count), 0)                 AS total_tokens,
    IFNULL(SUM(prompt_token_count), 0)                AS prompt_tokens,
    IFNULL(SUM(candidates_token_count), 0)            AS candidates_tokens,
    IFNULL(SUM(thoughts_token_count), 0)              AS thoughts_tokens,
    IFNULL(SUM(cached_content_token_count), 0)        AS cached_content_tokens,
    ROUND(AVG(total_token_count), 2)                  AS avg_tokens_per_inference,
    MAX(total_token_count)                            AS max_tokens_per_inference,
    COUNT(DISTINCT model_key)                         AS models_used,
    STRING_AGG(DISTINCT client_key, ', ' ORDER BY client_key) AS clients,
    MIN(timestamp)                                    AS first_seen,
    MAX(timestamp)                                    AS last_seen
  FROM responses_windowed
  GROUP BY GROUPING SETS ((window_days, user_key), (window_days))
),
model_counts AS (
  SELECT
    window_days,
    IF(GROUPING(user_key) = 1, 'all_users', 'user')   AS scope,
    IF(GROUPING(user_key) = 1, NULL, user_key)        AS user_email,
    model_key,
    COUNT(*)                                          AS n
  FROM responses_windowed
  GROUP BY GROUPING SETS ((window_days, user_key, model_key), (window_days, model_key))
),
top_models AS (
  SELECT window_days, scope, user_email, model_key AS top_model
  FROM model_counts
  QUALIFY ROW_NUMBER() OVER (PARTITION BY window_days, scope, user_email ORDER BY n DESC, model_key ASC) = 1
),

-- ---------------------------------------------------------------------------
-- Client events (permission accept/reject), deduplicated and normalized
-- ---------------------------------------------------------------------------
client_events AS (
  SELECT
    timestamp,
    COALESCE(NULLIF(REGEXP_REPLACE(labels.user_id, r'^user:', ''), ''), 'unknown') AS user_key,
    jsonpayload_v1_clienttelemetrylog.metadata.interactiontype    AS interaction_type,
    jsonpayload_v1_clienttelemetrylog.metadata.interactionoutcome AS interaction_outcome
  FROM
    `{{PROJECT_ID}}.{{RAW_DATASET_ID}}.businessaicode_googleapis_com_client_telemetry`
  WHERE
    timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 90 DAY)
  QUALIFY ROW_NUMBER() OVER (PARTITION BY insertId, timestamp ORDER BY receiveTimestamp DESC) = 1
),
client_events_windowed AS (
  SELECT w.window_days, c.*
  FROM client_events AS c
  JOIN windows AS w
    ON c.timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL w.window_days DAY)
),
client_stats AS (
  SELECT
    window_days,
    IF(GROUPING(user_key) = 1, 'all_users', 'user')   AS scope,
    IF(GROUPING(user_key) = 1, NULL, user_key)        AS user_email,
    COUNTIF(interaction_type = 'PERMISSION_GRANT')                                     AS permission_requests_total,
    COUNTIF(interaction_type = 'PERMISSION_GRANT' AND interaction_outcome = 'ACCEPTED') AS permission_grants_accepted,
    COUNTIF(interaction_type = 'PERMISSION_GRANT' AND interaction_outcome = 'REJECTED') AS permission_grants_rejected
  FROM client_events_windowed
  GROUP BY GROUPING SETS ((window_days, user_key), (window_days))
),

-- ---------------------------------------------------------------------------
-- Combine (FULL OUTER JOIN keeps users present in only one stream)
-- ---------------------------------------------------------------------------
combined AS (
  SELECT
    COALESCE(r.window_days, c.window_days)   AS window_days,
    COALESCE(r.scope, c.scope)               AS scope,
    COALESCE(r.user_email, c.user_email)     AS user_email,
    IFNULL(r.active_users, 0)                AS active_users,
    IFNULL(r.inferences, 0)                  AS inferences,
    IFNULL(r.trajectories, 0)                AS trajectories,
    IFNULL(r.active_days, 0)                 AS active_days,
    IFNULL(r.total_tokens, 0)                AS total_tokens,
    IFNULL(r.prompt_tokens, 0)               AS prompt_tokens,
    IFNULL(r.candidates_tokens, 0)           AS candidates_tokens,
    IFNULL(r.thoughts_tokens, 0)             AS thoughts_tokens,
    IFNULL(r.cached_content_tokens, 0)       AS cached_content_tokens,
    r.avg_tokens_per_inference,
    r.max_tokens_per_inference,
    IFNULL(r.models_used, 0)                 AS models_used,
    r.clients,
    r.first_seen,
    r.last_seen,
    IFNULL(c.permission_requests_total, 0)   AS permission_requests_total,
    IFNULL(c.permission_grants_accepted, 0)  AS permission_grants_accepted,
    IFNULL(c.permission_grants_rejected, 0)  AS permission_grants_rejected
  FROM response_stats AS r
  FULL OUTER JOIN client_stats AS c
    ON  r.window_days = c.window_days
    AND r.scope = c.scope
    AND IFNULL(r.user_email, '') = IFNULL(c.user_email, '')
)
SELECT
  x.window_days,
  x.scope,
  x.user_email,
  x.active_users,
  x.inferences,
  x.trajectories,
  x.active_days,
  ROUND(SAFE_DIVIDE(x.inferences, NULLIF(x.trajectories, 0)), 2) AS inferences_per_trajectory,
  x.total_tokens,
  x.prompt_tokens,
  x.candidates_tokens,
  x.thoughts_tokens,
  x.cached_content_tokens,
  x.avg_tokens_per_inference,
  x.max_tokens_per_inference,
  x.models_used,
  t.top_model,
  x.clients,
  x.first_seen,
  x.last_seen,
  x.permission_requests_total,
  x.permission_grants_accepted,
  x.permission_grants_rejected,
  ROUND(SAFE_DIVIDE(x.permission_grants_accepted, NULLIF(x.permission_requests_total, 0)), 4) AS permission_grant_rate,
  ROUND(SAFE_DIVIDE(
    x.total_tokens,
    NULLIF(MAX(IF(x.scope = 'all_users', x.total_tokens, NULL)) OVER (PARTITION BY x.window_days), 0)
  ), 4) AS token_share
FROM combined AS x
LEFT JOIN top_models AS t
  ON  t.window_days = x.window_days
  AND t.scope = x.scope
  AND IFNULL(t.user_email, '') = IFNULL(x.user_email, '');
