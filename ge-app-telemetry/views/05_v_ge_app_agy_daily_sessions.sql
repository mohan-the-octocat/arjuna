-- =============================================================================
-- View 05: v_ge_app_agy_daily_sessions
-- =============================================================================
-- Grain:   one row per UTC day x every combination of (user, client, model),
--          where '(all)' in a dimension means "all values combined"
--          (event_date x every combination of user, client, model via GROUPING SETS).
-- Source:  RAW inference_response.
-- Purpose: exact distinct sessions / users per day for ANY dashboard filter
--          combination, without summing distinct counts across rows.
-- Privacy: reads no prompt/response text; outputs metrics only.
-- Notes:   * sessions = distinct labels.trajectory_id with >= 1 response that day
--            (responses without a trajectory id, e.g. flash-lite background
--            calls, count as inferences but not as sessions).
--          * A session that uses two models on a day counts once on the
--            model='(all)' row and once on each model's row (correct for
--            "sessions using model X").
--          * Dedupe on (insertId, timestamp); day boundaries are UTC.
-- Placeholders: {{PROJECT_ID}} {{DATASET_ID}} (views dataset) {{RAW_DATASET_ID}}
-- =============================================================================

CREATE OR REPLACE VIEW `{{PROJECT_ID}}.{{DATASET_ID}}.v_ge_app_agy_daily_sessions` (
  event_date   OPTIONS(description = "UTC date (DATE(timestamp))."),
  user_email   OPTIONS(description = "labels.user_id without the 'user:' prefix ('unknown' if missing); '(all)' = all users combined."),
  client_name  OPTIONS(description = "labels.client_name ('unspecified' if missing); '(all)' = all clients combined."),
  model        OPTIONS(description = "labels.model ('unspecified' if missing); '(all)' = all models combined."),
  sessions     OPTIONS(description = "Distinct labels.trajectory_id with at least one response in this row (exact)."),
  active_users OPTIONS(description = "Distinct users with at least one response in this row (exact)."),
  inferences   OPTIONS(description = "Number of model responses (deduplicated) in this row, incl. background calls without a session."),
  session_inferences OPTIONS(description = "Responses that carry a trajectory id (excludes background calls such as flash-lite).")
)
OPTIONS(
  description = "Antigravity exact daily sessions and active users for every user x client x model combination ('(all)' = combined). Source: inference_response. No prompt text."
) AS
WITH responses AS (
  SELECT
    DATE(timestamp)                                                               AS event_date,
    COALESCE(NULLIF(REGEXP_REPLACE(labels.user_id, r'^user:', ''), ''), 'unknown') AS user_key,
    COALESCE(labels.client_name, 'unspecified')                                   AS client_key,
    COALESCE(labels.model, 'unspecified')                                         AS model_key,
    labels.trajectory_id                                                          AS trajectory_id
  FROM
    `{{PROJECT_ID}}.{{RAW_DATASET_ID}}.businessaicode_googleapis_com_inference_response`
  WHERE
    timestamp IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (PARTITION BY insertId, timestamp ORDER BY receiveTimestamp DESC) = 1
)
SELECT
  event_date,
  IF(GROUPING(user_key) = 1, '(all)', user_key)     AS user_email,
  IF(GROUPING(client_key) = 1, '(all)', client_key) AS client_name,
  IF(GROUPING(model_key) = 1, '(all)', model_key)   AS model,
  COUNT(DISTINCT trajectory_id)                     AS sessions,
  COUNT(DISTINCT user_key)                          AS active_users,
  COUNT(*)                                          AS inferences,
  COUNTIF(trajectory_id IS NOT NULL)                AS session_inferences
FROM
  responses
GROUP BY
  -- Equivalent to event_date x CUBE(user, client, model); BigQuery does not allow
  -- CUBE together with another grouping element, so the 8 sets are listed explicitly.
  GROUPING SETS (
    (event_date, user_key, client_key, model_key),
    (event_date, user_key, client_key),
    (event_date, user_key, model_key),
    (event_date, client_key, model_key),
    (event_date, user_key),
    (event_date, client_key),
    (event_date, model_key),
    (event_date)
  );
