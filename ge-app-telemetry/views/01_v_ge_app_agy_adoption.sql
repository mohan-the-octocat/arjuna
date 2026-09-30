-- =============================================================================
-- View 1: v_ge_app_agy_adoption
-- =============================================================================
-- Granularity: Daily per user, per client surface, per model.
-- Purpose: Tracks developer adoption, active usage, session depth, and stickiness.
-- =============================================================================

CREATE OR REPLACE VIEW `{{PROJECT_ID}}.{{DATASET_ID}}.v_ge_app_agy_adoption`
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
    `{{PROJECT_ID}}.{{DATASET_ID}}.businessaicode_googleapis_com_inference_response`
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
  COUNTIF(trajectory_id IS NOT NULL) AS trajectory_inferences,
  COUNTIF(trajectory_id IS NULL) AS aux_inferences,
  COUNT(DISTINCT trajectory_id) AS active_trajectories,
  ROUND(SAFE_DIVIDE(COUNTIF(trajectory_id IS NOT NULL), COUNT(DISTINCT trajectory_id)), 2) AS inferences_per_trajectory,
  COUNT(DISTINCT EXTRACT(HOUR FROM timestamp)) AS active_hours_count,
  MIN(timestamp) AS first_activity_utc,
  MAX(timestamp) AS last_activity_utc
FROM
  raw_deduped
GROUP BY
  1, 2, 3, 4, 5;
