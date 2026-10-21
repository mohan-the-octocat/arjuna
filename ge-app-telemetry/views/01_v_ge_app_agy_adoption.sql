-- =============================================================================
-- View 01: v_ge_app_agy_adoption
-- =============================================================================
-- Grain:   one row per UTC day x user x client x client_version x model.
-- Source:  RAW inference_response (one row = one model response = one inference).
-- Privacy: reads no prompt/response text; outputs metrics only.
-- Notes:   * Dedupe on (insertId, timestamp) — Cloud Logging's uniqueness key.
--          * Day boundaries are UTC.
--          * `trajectories` counts distinct sessions per row; summing rows across
--            days can double count sessions that span midnight (use
--            v_ge_app_agy_user_summary for window totals).
-- Placeholders: {{PROJECT_ID}} {{DATASET_ID}} (views dataset) {{RAW_DATASET_ID}}
-- =============================================================================

CREATE OR REPLACE VIEW `{{PROJECT_ID}}.{{DATASET_ID}}.v_ge_app_agy_adoption` (
  event_date                OPTIONS(description = "UTC date of the response (DATE(timestamp))."),
  user_email                OPTIONS(description = "labels.user_id without the 'user:' prefix; 'unknown' if missing."),
  client_name               OPTIONS(description = "labels.client_name, e.g. antigravity_cli / antigravity_hub; 'unspecified' if missing."),
  client_version            OPTIONS(description = "labels.client_version; 'unspecified' if missing."),
  model                     OPTIONS(description = "labels.model; 'unspecified' if missing."),
  total_inferences          OPTIONS(description = "Number of model responses (deduplicated inference_response rows)."),
  trajectories              OPTIONS(description = "Distinct labels.trajectory_id (sessions) with at least one response in this row."),
  inferences_per_trajectory OPTIONS(description = "total_inferences / trajectories (2 decimals); NULL if no trajectory id."),
  active_hours_count        OPTIONS(description = "Distinct UTC hours (0-23) with at least one response."),
  first_activity_utc        OPTIONS(description = "Earliest response timestamp in this row."),
  last_activity_utc         OPTIONS(description = "Latest response timestamp in this row.")
)
OPTIONS(
  description = "Antigravity adoption: daily inferences and sessions per user, client, version and model. Source: inference_response. No prompt text."
) AS
WITH responses AS (
  SELECT
    timestamp,
    labels.user_id        AS raw_user_id,
    labels.trajectory_id  AS trajectory_id,
    labels.client_name    AS client_name,
    labels.client_version AS client_version,
    labels.model          AS model
  FROM
    `{{PROJECT_ID}}.{{RAW_DATASET_ID}}.businessaicode_googleapis_com_inference_response`
  WHERE
    timestamp IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (PARTITION BY insertId, timestamp ORDER BY receiveTimestamp DESC) = 1
)
SELECT
  DATE(timestamp)                                                     AS event_date,
  COALESCE(NULLIF(REGEXP_REPLACE(raw_user_id, r'^user:', ''), ''), 'unknown') AS user_email,
  COALESCE(client_name, 'unspecified')                                AS client_name,
  COALESCE(client_version, 'unspecified')                             AS client_version,
  COALESCE(model, 'unspecified')                                      AS model,
  COUNT(*)                                                            AS total_inferences,
  COUNT(DISTINCT trajectory_id)                                       AS trajectories,
  ROUND(SAFE_DIVIDE(COUNT(*), NULLIF(COUNT(DISTINCT trajectory_id), 0)), 2) AS inferences_per_trajectory,
  COUNT(DISTINCT EXTRACT(HOUR FROM timestamp))                        AS active_hours_count,
  MIN(timestamp)                                                      AS first_activity_utc,
  MAX(timestamp)                                                      AS last_activity_utc
FROM
  responses
GROUP BY
  1, 2, 3, 4, 5;
