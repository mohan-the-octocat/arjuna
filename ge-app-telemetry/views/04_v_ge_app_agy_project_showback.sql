-- =============================================================================
-- View 4: v_ge_app_agy_project_showback
-- =============================================================================
-- Granularity: event_date x project_id x user_email.
-- Purpose: GCP project showback and budget burn tracking.
-- =============================================================================

CREATE OR REPLACE VIEW `{{PROJECT_ID}}.{{DATASET_ID}}.v_ge_app_agy_project_showback`
OPTIONS(
  description = "Antigravity GCP project showback mart: daily inferences, trajectories, tokens, and estimated cost per project and user."
) AS
WITH raw_deduped AS (
  SELECT
    timestamp,
    insertId,
    REGEXP_EXTRACT(logName, r'^projects/([^/]+)/') AS log_project_id,
    resource.labels.resource_container AS project_number,
    labels.user_id AS raw_user_id,
    labels.trajectory_id,
    labels.model,
    SAFE_CAST(jsonpayload_v1_inferenceresponselog.metadata.totaltokencount AS INT64) AS total_token_count
  FROM
    `{{PROJECT_ID}}.{{DATASET_ID}}.businessaicode_googleapis_com_inference_response`
  WHERE
    timestamp IS NOT NULL
  QUALIFY ROW_NUMBER() OVER(PARTITION BY insertId ORDER BY timestamp DESC) = 1
),
rate_lookup AS (
  SELECT
    model,
    MAX(usd_per_1m_tokens) AS usd_per_1m_tokens
  FROM
    `{{PROJECT_ID}}.{{DATASET_ID}}.ge_app_agy_rate_card`
  GROUP BY
    model
),
fallback_rate AS (
  SELECT
    COALESCE(MAX(usd_per_1m_tokens), 0.15) AS usd_per_1m_tokens
  FROM
    `{{PROJECT_ID}}.{{DATASET_ID}}.ge_app_agy_rate_card`
  WHERE
    model = '*'
)
SELECT
  DATE(r.timestamp) AS event_date,
  COALESCE(r.log_project_id, r.project_number, 'unspecified') AS project_id,
  COALESCE(r.project_number, 'unspecified') AS project_number,
  REGEXP_REPLACE(r.raw_user_id, r'^user:', '') AS user_email,
  COUNT(1) AS inferences,
  COUNT(DISTINCT r.trajectory_id) AS trajectories,
  SUM(COALESCE(r.total_token_count, 0)) AS total_tokens,
  ROUND(SUM(COALESCE(r.total_token_count, 0) * COALESCE(rc.usd_per_1m_tokens, fb.usd_per_1m_tokens, 0.15) / 1e6), 4) AS est_cost_usd
FROM
  raw_deduped r
LEFT JOIN
  rate_lookup rc
  ON COALESCE(r.model, 'unspecified') = rc.model
CROSS JOIN
  fallback_rate fb
GROUP BY
  event_date, project_id, project_number, user_email;
