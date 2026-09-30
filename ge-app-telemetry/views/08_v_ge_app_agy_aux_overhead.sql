-- =============================================================================
-- View 8: v_ge_app_agy_aux_overhead
-- =============================================================================
-- Granularity: event_date x client_name x client_version.
-- Purpose: Background auxiliary call and token overhead by client version.
-- =============================================================================

CREATE OR REPLACE VIEW `{{PROJECT_ID}}.{{DATASET_ID}}.v_ge_app_agy_aux_overhead`
OPTIONS(
  description = "Antigravity auxiliary call overhead view: total vs NULL-trajectory calls and tokens by date, client surface, and version."
) AS
WITH raw_deduped AS (
  SELECT
    timestamp,
    insertId,
    COALESCE(labels.client_name, 'unspecified') AS client_name,
    COALESCE(labels.client_version, 'unspecified') AS client_version,
    labels.trajectory_id,
    SAFE_CAST(jsonpayload_v1_inferenceresponselog.metadata.totaltokencount AS INT64) AS total_token_count
  FROM
    `{{PROJECT_ID}}.{{DATASET_ID}}.businessaicode_googleapis_com_inference_response`
  WHERE
    timestamp IS NOT NULL
  QUALIFY ROW_NUMBER() OVER(PARTITION BY insertId ORDER BY timestamp DESC) = 1
)
SELECT
  DATE(timestamp) AS event_date,
  client_name,
  client_version,
  COUNT(1) AS total_calls,
  COUNTIF(trajectory_id IS NULL) AS aux_calls,
  SUM(COALESCE(total_token_count, 0)) AS total_tokens,
  SUM(IF(trajectory_id IS NULL, COALESCE(total_token_count, 0), 0)) AS aux_tokens
FROM
  raw_deduped
GROUP BY
  event_date, client_name, client_version;
