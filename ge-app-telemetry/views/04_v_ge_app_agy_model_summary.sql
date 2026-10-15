-- =============================================================================
-- View 04: v_ge_app_agy_model_summary
-- =============================================================================
-- Grain:   one row per (window_days, model) for window_days IN (7, 90), plus one
--          'all_models' row per window (scope = 'all_models', model = NULL).
-- Source:  RAW inference_response (usage, tokens).
--          Permission outcomes are NOT included: client_telemetry interaction
--          events carry no labels.model (verified in live logs).
-- Privacy: reads no prompt/response text; outputs metrics only.
-- Correctness notes (same pattern as v_ge_app_agy_user_summary):
--   * Rolling windows from query time (CURRENT_TIMESTAMP() evaluated once).
--   * all_models rows via GROUPING SETS -> exact distinct users/sessions/days.
--   * Dedupe on (insertId, timestamp).
-- Placeholders: {{PROJECT_ID}} {{DATASET_ID}} (views dataset) {{RAW_DATASET_ID}}
-- =============================================================================

CREATE OR REPLACE VIEW `{{PROJECT_ID}}.{{DATASET_ID}}.v_ge_app_agy_model_summary` (
  window_days                OPTIONS(description = "Rolling window length in days (7 or 90), counted back from query time (UTC)."),
  scope                      OPTIONS(description = "'model' = one model; 'all_models' = all models combined (computed directly, not summed)."),
  model                      OPTIONS(description = "labels.model ('unspecified' if missing); NULL on all_models rows."),
  active_users               OPTIONS(description = "Distinct users with at least one response from this model in the window."),
  inferences                 OPTIONS(description = "Number of model responses (deduplicated inference_response rows)."),
  trajectories               OPTIONS(description = "Distinct labels.trajectory_id (sessions) with at least one response from this model."),
  active_days                OPTIONS(description = "Distinct UTC dates with at least one response from this model."),
  total_tokens               OPTIONS(description = "SUM of metadata.totaltokencount."),
  prompt_tokens              OPTIONS(description = "SUM of metadata.prompttokencount."),
  candidates_tokens          OPTIONS(description = "SUM of metadata.candidatestokencount."),
  thoughts_tokens            OPTIONS(description = "SUM of metadata.thoughtstokencount."),
  cached_content_tokens      OPTIONS(description = "SUM of metadata.cachedcontenttokencount."),
  avg_tokens_per_inference   OPTIONS(description = "AVG of metadata.totaltokencount over responses that logged it (2 decimals)."),
  max_tokens_per_inference   OPTIONS(description = "MAX of metadata.totaltokencount."),
  experiences                OPTIONS(description = "Distinct experience values (model + reasoning tier), sorted, comma-separated."),
  clients                    OPTIONS(description = "Distinct labels.client_name values, sorted, comma-separated."),
  first_seen                 OPTIONS(description = "Earliest response timestamp in the window."),
  last_seen                  OPTIONS(description = "Latest response timestamp in the window."),
  inference_share            OPTIONS(description = "inferences / all_models inferences in the same window (4 decimals); 1.0 on all_models rows."),
  token_share                OPTIONS(description = "total_tokens / all_models total_tokens in the same window (4 decimals); 1.0 on all_models rows.")
)
OPTIONS(
  description = "Antigravity per-model summary over rolling 7 and 90 day windows, with an all_models row per window. Source: inference_response. No prompt text."
) AS
WITH
windows AS (
  SELECT window_days FROM UNNEST([7, 90]) AS window_days
),
responses AS (
  SELECT
    timestamp,
    COALESCE(labels.model, 'unspecified')                                         AS model_key,
    COALESCE(NULLIF(REGEXP_REPLACE(labels.user_id, r'^user:', ''), ''), 'unknown') AS user_key,
    labels.trajectory_id                                                          AS trajectory_id,
    COALESCE(labels.client_name, 'unspecified')                                   AS client_key,
    COALESCE(jsonpayload_v1_inferenceresponselog.experience, 'unspecified')       AS experience_key,
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
    IF(GROUPING(model_key) = 1, 'all_models', 'model') AS scope,
    IF(GROUPING(model_key) = 1, NULL, model_key)       AS model,
    COUNT(DISTINCT user_key)                           AS active_users,
    COUNT(*)                                           AS inferences,
    COUNT(DISTINCT trajectory_id)                      AS trajectories,
    COUNT(DISTINCT DATE(timestamp))                    AS active_days,
    IFNULL(SUM(total_token_count), 0)                  AS total_tokens,
    IFNULL(SUM(prompt_token_count), 0)                 AS prompt_tokens,
    IFNULL(SUM(candidates_token_count), 0)             AS candidates_tokens,
    IFNULL(SUM(thoughts_token_count), 0)               AS thoughts_tokens,
    IFNULL(SUM(cached_content_token_count), 0)         AS cached_content_tokens,
    ROUND(AVG(total_token_count), 2)                   AS avg_tokens_per_inference,
    MAX(total_token_count)                             AS max_tokens_per_inference,
    STRING_AGG(DISTINCT experience_key, ', ' ORDER BY experience_key) AS experiences,
    STRING_AGG(DISTINCT client_key, ', ' ORDER BY client_key)         AS clients,
    MIN(timestamp)                                     AS first_seen,
    MAX(timestamp)                                     AS last_seen
  FROM responses_windowed
  GROUP BY GROUPING SETS ((window_days, model_key), (window_days))
)
SELECT
  x.window_days,
  x.scope,
  x.model,
  x.active_users,
  x.inferences,
  x.trajectories,
  x.active_days,
  x.total_tokens,
  x.prompt_tokens,
  x.candidates_tokens,
  x.thoughts_tokens,
  x.cached_content_tokens,
  x.avg_tokens_per_inference,
  x.max_tokens_per_inference,
  x.experiences,
  x.clients,
  x.first_seen,
  x.last_seen,
  ROUND(SAFE_DIVIDE(
    x.inferences,
    NULLIF(MAX(IF(x.scope = 'all_models', x.inferences, NULL)) OVER (PARTITION BY x.window_days), 0)
  ), 4) AS inference_share,
  ROUND(SAFE_DIVIDE(
    x.total_tokens,
    NULLIF(MAX(IF(x.scope = 'all_models', x.total_tokens, NULL)) OVER (PARTITION BY x.window_days), 0)
  ), 4) AS token_share
FROM response_stats AS x;
