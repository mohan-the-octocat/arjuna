-- =============================================================================
-- View 5: v_ge_app_agy_trajectory_outcomes
-- =============================================================================
-- Granularity: trajectory_id (non-null only).
-- Purpose: Per-trajectory cost, step depth, resolution status, proposal rework,
--          and permission grant counts.
-- =============================================================================

CREATE OR REPLACE VIEW `{{PROJECT_ID}}.{{DATASET_ID}}.v_ge_app_agy_trajectory_outcomes`
OPTIONS(
  description = "Antigravity trajectory outcomes mart: per-trajectory steps, tokens, estimated cost, resolution status, proposals, and permissions."
) AS
WITH resp_deduped AS (
  SELECT
    timestamp,
    insertId,
    COALESCE(REGEXP_EXTRACT(logName, r'^projects/([^/]+)/'), resource.labels.resource_container, 'unspecified') AS project_id,
    REGEXP_REPLACE(labels.user_id, r'^user:', '') AS user_email,
    labels.trajectory_id,
    labels.request_id,
    COALESCE(labels.client_name, 'unspecified') AS client_name,
    COALESCE(labels.client_version, 'unspecified') AS client_version,
    COALESCE(labels.model, 'unspecified') AS model,
    COALESCE(jsonpayload_v1_inferenceresponselog.experience, 'unspecified') AS experience,
    SAFE_CAST(jsonpayload_v1_inferenceresponselog.metadata.totaltokencount AS INT64) AS total_token_count
  FROM
    `{{PROJECT_ID}}.{{DATASET_ID}}.businessaicode_googleapis_com_inference_response`
  WHERE
    timestamp IS NOT NULL
  QUALIFY ROW_NUMBER() OVER(PARTITION BY insertId ORDER BY timestamp DESC) = 1
),
ct_deduped AS (
  SELECT
    timestamp,
    insertId,
    labels.trajectory_id,
    jsonpayload_v1_clienttelemetrylog.eventtype AS event_type,
    jsonpayload_v1_clienttelemetrylog.metadata.interactiontype AS interaction_type,
    jsonpayload_v1_clienttelemetrylog.metadata.interactionoutcome AS interaction_outcome
  FROM
    `{{PROJECT_ID}}.{{DATASET_ID}}.businessaicode_googleapis_com_client_telemetry`
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
),
resp_agg AS (
  SELECT
    r.trajectory_id,
    APPROX_TOP_COUNT(r.user_email, 1)[OFFSET(0)].value AS user_email,
    APPROX_TOP_COUNT(r.project_id, 1)[OFFSET(0)].value AS project_id,
    APPROX_TOP_COUNT(r.client_name, 1)[OFFSET(0)].value AS client_name,
    APPROX_TOP_COUNT(r.client_version, 1)[OFFSET(0)].value AS client_version,
    APPROX_TOP_COUNT(r.model, 1)[OFFSET(0)].value AS model,
    APPROX_TOP_COUNT(r.experience, 1)[OFFSET(0)].value AS experience,
    MIN(r.timestamp) AS first_ts,
    MAX(r.timestamp) AS last_ts,
    COUNT(DISTINCT r.request_id) AS steps,
    SUM(COALESCE(r.total_token_count, 0)) AS total_tokens,
    ROUND(SUM(COALESCE(r.total_token_count, 0) * COALESCE(rc.usd_per_1m_tokens, fb.usd_per_1m_tokens, 0.15) / 1e6), 4) AS est_cost_usd
  FROM
    resp_deduped r
  LEFT JOIN
    rate_lookup rc
    ON r.model = rc.model
  CROSS JOIN
    fallback_rate fb
  WHERE
    r.trajectory_id IS NOT NULL
  GROUP BY
    r.trajectory_id
),
ct_agg AS (
  SELECT
    trajectory_id,
    LOGICAL_OR(event_type = 'InferenceResolved') AS resolved,
    COUNTIF(interaction_type = 'PROPOSAL_ACCEPTANCE' AND interaction_outcome = 'ACCEPTED') AS proposals_accepted,
    COUNTIF(interaction_type = 'PROPOSAL_ACCEPTANCE' AND interaction_outcome = 'MODIFIED') AS proposals_modified,
    COUNTIF(interaction_type = 'PROPOSAL_ACCEPTANCE' AND interaction_outcome = 'REJECTED') AS proposals_rejected,
    COUNTIF(interaction_type = 'PERMISSION_GRANT' AND interaction_outcome = 'ACCEPTED') AS permissions_accepted,
    COUNTIF(interaction_type = 'PERMISSION_GRANT' AND interaction_outcome = 'REJECTED') AS permissions_rejected
  FROM
    ct_deduped
  WHERE
    trajectory_id IS NOT NULL
  GROUP BY
    trajectory_id
)
SELECT
  ra.trajectory_id,
  ra.user_email,
  ra.project_id,
  ra.client_name,
  ra.client_version,
  ra.model,
  ra.experience,
  ra.first_ts,
  ra.last_ts,
  ra.steps,
  ra.total_tokens,
  ra.est_cost_usd,
  COALESCE(ca.resolved, FALSE) AS resolved,
  COALESCE(ca.proposals_accepted, 0) AS proposals_accepted,
  COALESCE(ca.proposals_modified, 0) AS proposals_modified,
  COALESCE(ca.proposals_rejected, 0) AS proposals_rejected,
  COALESCE(ca.permissions_accepted, 0) AS permissions_accepted,
  COALESCE(ca.permissions_rejected, 0) AS permissions_rejected
FROM
  resp_agg ra
LEFT JOIN
  ct_agg ca
  USING (trajectory_id);
