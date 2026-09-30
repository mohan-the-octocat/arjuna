-- =============================================================================
-- View 9: v_ge_app_agy_approval_posture
-- =============================================================================
-- Granularity: project_id x user_email.
-- Purpose: Permission grant acceptance, rejection, fast approvals, and decision
--          latency posture.
-- =============================================================================

CREATE OR REPLACE VIEW `{{PROJECT_ID}}.{{DATASET_ID}}.v_ge_app_agy_approval_posture`
OPTIONS(
  description = "Antigravity approval posture view: permission grants accepted/rejected, fast approvals (<=2s), and median decision latency per project and user."
) AS
WITH grants_deduped AS (
  SELECT
    timestamp AS grant_ts,
    insertId,
    COALESCE(REGEXP_EXTRACT(logName, r'^projects/([^/]+)/'), resource.labels.resource_container, 'unspecified') AS project_id,
    REGEXP_REPLACE(labels.user_id, r'^user:', '') AS user_email,
    labels.request_id,
    jsonpayload_v1_clienttelemetrylog.metadata.interactionoutcome AS interaction_outcome
  FROM
    `{{PROJECT_ID}}.{{DATASET_ID}}.businessaicode_googleapis_com_client_telemetry`
  WHERE
    timestamp IS NOT NULL
    AND jsonpayload_v1_clienttelemetrylog.metadata.interactiontype = 'PERMISSION_GRANT'
  QUALIFY ROW_NUMBER() OVER(PARTITION BY insertId ORDER BY timestamp DESC) = 1
),
resp_deduped AS (
  SELECT
    request_id,
    MIN(timestamp) AS resp_ts
  FROM (
    SELECT
      timestamp,
      insertId,
      labels.request_id
    FROM
      `{{PROJECT_ID}}.{{DATASET_ID}}.businessaicode_googleapis_com_inference_response`
    WHERE
      timestamp IS NOT NULL
      AND labels.request_id IS NOT NULL
    QUALIFY ROW_NUMBER() OVER(PARTITION BY insertId ORDER BY timestamp DESC) = 1
  )
  GROUP BY
    request_id
),
joined AS (
  SELECT
    g.project_id,
    g.user_email,
    g.interaction_outcome,
    IF(
      r.resp_ts IS NOT NULL AND g.grant_ts >= r.resp_ts,
      TIMESTAMP_DIFF(g.grant_ts, r.resp_ts, MILLISECOND) / 1000.0,
      NULL
    ) AS decision_seconds
  FROM
    grants_deduped g
  LEFT JOIN
    resp_deduped r
    USING (request_id)
)
SELECT
  project_id,
  user_email,
  COUNTIF(interaction_outcome = 'ACCEPTED') AS grants_accepted,
  COUNTIF(interaction_outcome = 'REJECTED') AS grants_rejected,
  -- fast_approval_seconds = 2 (configured in dashboards/local-web/admin_config.json)
  COUNTIF(decision_seconds IS NOT NULL AND decision_seconds <= 2.0) AS fast_grants,
  ROUND(APPROX_QUANTILES(decision_seconds, 100 IGNORE NULLS)[SAFE_OFFSET(50)], 2) AS median_decision_seconds
FROM
  joined
GROUP BY
  project_id, user_email;
