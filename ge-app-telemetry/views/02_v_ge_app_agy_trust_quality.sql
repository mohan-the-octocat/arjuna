-- =============================================================================
-- View 2: v_ge_app_agy_trust_quality
-- =============================================================================
-- Granularity: Daily per user, per client surface, per model.
-- Purpose: Evaluates agent trust, proposal acceptance, modification rate, and
--          session resolution rate.
-- =============================================================================

CREATE OR REPLACE VIEW `{{PROJECT_ID}}.{{DATASET_ID}}.v_ge_app_agy_trust_quality`
OPTIONS(
  description = "Antigravity trust and quality mart: proposal acceptances, code modification rates, permission grants, and session resolution rates."
) AS
WITH raw_deduped AS (
  SELECT
    timestamp,
    insertId,
    labels.user_id AS raw_user_id,
    labels.trajectory_id,
    labels.request_id,
    labels.client_name,
    labels.model,
    jsonpayload_v1_clienttelemetrylog.eventtype AS event_type,
    jsonpayload_v1_clienttelemetrylog.metadata.interactiontype AS interaction_type,
    jsonpayload_v1_clienttelemetrylog.metadata.interactionoutcome AS interaction_outcome
  FROM
    `{{PROJECT_ID}}.{{DATASET_ID}}.businessaicode_googleapis_com_client_telemetry`
  WHERE
    timestamp IS NOT NULL
  QUALIFY ROW_NUMBER() OVER(PARTITION BY insertId ORDER BY timestamp DESC) = 1
)
SELECT
  DATE(timestamp) AS event_date,
  REGEXP_REPLACE(raw_user_id, r'^user:', '') AS user_email,
  COALESCE(client_name, 'unspecified') AS client_name,
  COALESCE(model, 'unspecified') AS model,
  COUNT(1) AS total_events,
  -- Session Completion & Resolution
  COUNT(DISTINCT IF(event_type = 'InferenceResolved', trajectory_id, NULL)) AS resolved_trajectories,
  COUNT(DISTINCT trajectory_id) AS total_trajectories,
  ROUND(SAFE_DIVIDE(
    COUNT(DISTINCT IF(event_type = 'InferenceResolved', trajectory_id, NULL)),
    NULLIF(COUNT(DISTINCT trajectory_id), 0)
  ), 4) AS trajectory_resolution_rate,
  -- Tool & Command Execution Permissions
  COUNTIF(interaction_type = 'PERMISSION_GRANT') AS permission_requests_total,
  COUNTIF(interaction_type = 'PERMISSION_GRANT' AND interaction_outcome = 'ACCEPTED') AS permission_grants_accepted,
  COUNTIF(interaction_type = 'PERMISSION_GRANT' AND interaction_outcome = 'REJECTED') AS permission_grants_rejected,
  ROUND(SAFE_DIVIDE(
    COUNTIF(interaction_type = 'PERMISSION_GRANT' AND interaction_outcome = 'ACCEPTED'),
    NULLIF(COUNTIF(interaction_type = 'PERMISSION_GRANT'), 0)
  ), 4) AS permission_grant_rate,
  -- Code & Diff Proposal Evaluation
  COUNTIF(interaction_type = 'PROPOSAL_ACCEPTANCE') AS proposals_total,
  COUNTIF(interaction_type = 'PROPOSAL_ACCEPTANCE' AND interaction_outcome = 'ACCEPTED') AS proposals_accepted,
  COUNTIF(interaction_type = 'PROPOSAL_ACCEPTANCE' AND interaction_outcome = 'MODIFIED') AS proposals_modified,
  COUNTIF(interaction_type = 'PROPOSAL_ACCEPTANCE' AND interaction_outcome = 'REJECTED') AS proposals_rejected,
  ROUND(SAFE_DIVIDE(
    COUNTIF(interaction_type = 'PROPOSAL_ACCEPTANCE' AND interaction_outcome = 'ACCEPTED'),
    NULLIF(COUNTIF(interaction_type = 'PROPOSAL_ACCEPTANCE'), 0)
  ), 4) AS proposal_acceptance_rate,
  ROUND(SAFE_DIVIDE(
    COUNTIF(interaction_type = 'PROPOSAL_ACCEPTANCE' AND interaction_outcome = 'MODIFIED'),
    NULLIF(COUNTIF(interaction_type = 'PROPOSAL_ACCEPTANCE'), 0)
  ), 4) AS proposal_modification_rate
FROM
  raw_deduped
GROUP BY
  1, 2, 3, 4;
