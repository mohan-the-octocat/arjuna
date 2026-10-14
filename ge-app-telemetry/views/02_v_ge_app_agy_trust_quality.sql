-- =============================================================================
-- View 02: v_ge_app_agy_trust_quality
-- =============================================================================
-- Grain:   one row per UTC day x user x client x model.
-- Source:  RAW client_telemetry.
-- Privacy: client_telemetry has no free text (verified); outputs metrics only.
-- Verified values (live logs): eventtype IN ('InferenceInteraction','InferenceResolved');
--   metadata.interactiontype = 'PERMISSION_GRANT'; interactionoutcome IN ('ACCEPTED','REJECTED').
-- Notes:   * 'InferenceResolved' marks a finished turn — it also fires after a
--            rejected permission, so it is NOT a success signal.
--          * PROPOSAL_ACCEPTANCE has not been observed in live logs and is not reported.
--          * Dedupe on (insertId, timestamp); day boundaries are UTC.
-- Placeholders: {{PROJECT_ID}} {{DATASET_ID}} (views dataset) {{RAW_DATASET_ID}}
-- =============================================================================

CREATE OR REPLACE VIEW `{{PROJECT_ID}}.{{DATASET_ID}}.v_ge_app_agy_trust_quality` (
  event_date                 OPTIONS(description = "UTC date of the client event (DATE(timestamp))."),
  user_email                 OPTIONS(description = "labels.user_id without the 'user:' prefix; 'unknown' if missing."),
  client_name                OPTIONS(description = "labels.client_name; 'unspecified' if missing."),
  model                      OPTIONS(description = "labels.model; 'unspecified' if missing."),
  total_events               OPTIONS(description = "Number of client_telemetry events (deduplicated)."),
  trajectories               OPTIONS(description = "Distinct labels.trajectory_id (sessions) with at least one client event in this row."),
  inference_resolved_events  OPTIONS(description = "Events with eventtype = 'InferenceResolved' (a turn finished; not a success signal)."),
  permission_requests_total  OPTIONS(description = "Events with metadata.interactiontype = 'PERMISSION_GRANT'."),
  permission_grants_accepted OPTIONS(description = "PERMISSION_GRANT events with interactionoutcome = 'ACCEPTED'."),
  permission_grants_rejected OPTIONS(description = "PERMISSION_GRANT events with interactionoutcome = 'REJECTED'."),
  permission_grant_rate      OPTIONS(description = "permission_grants_accepted / permission_requests_total (4 decimals); NULL if no requests.")
)
OPTIONS(
  description = "Antigravity trust: daily client events, sessions and permission accept/reject per user, client and model. Source: client_telemetry. No prompt text."
) AS
WITH events AS (
  SELECT
    timestamp,
    labels.user_id                                                AS raw_user_id,
    labels.trajectory_id                                          AS trajectory_id,
    labels.client_name                                            AS client_name,
    labels.model                                                  AS model,
    jsonpayload_v1_clienttelemetrylog.eventtype                   AS event_type,
    jsonpayload_v1_clienttelemetrylog.metadata.interactiontype    AS interaction_type,
    jsonpayload_v1_clienttelemetrylog.metadata.interactionoutcome AS interaction_outcome
  FROM
    `{{PROJECT_ID}}.{{RAW_DATASET_ID}}.businessaicode_googleapis_com_client_telemetry`
  WHERE
    timestamp IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (PARTITION BY insertId, timestamp ORDER BY receiveTimestamp DESC) = 1
)
SELECT
  DATE(timestamp)                                                     AS event_date,
  COALESCE(NULLIF(REGEXP_REPLACE(raw_user_id, r'^user:', ''), ''), 'unknown') AS user_email,
  COALESCE(client_name, 'unspecified')                                AS client_name,
  COALESCE(model, 'unspecified')                                      AS model,
  COUNT(*)                                                            AS total_events,
  COUNT(DISTINCT trajectory_id)                                       AS trajectories,
  COUNTIF(event_type = 'InferenceResolved')                           AS inference_resolved_events,
  COUNTIF(interaction_type = 'PERMISSION_GRANT')                      AS permission_requests_total,
  COUNTIF(interaction_type = 'PERMISSION_GRANT' AND interaction_outcome = 'ACCEPTED') AS permission_grants_accepted,
  COUNTIF(interaction_type = 'PERMISSION_GRANT' AND interaction_outcome = 'REJECTED') AS permission_grants_rejected,
  ROUND(SAFE_DIVIDE(
    COUNTIF(interaction_type = 'PERMISSION_GRANT' AND interaction_outcome = 'ACCEPTED'),
    NULLIF(COUNTIF(interaction_type = 'PERMISSION_GRANT'), 0)
  ), 4)                                                               AS permission_grant_rate
FROM
  events
GROUP BY
  1, 2, 3, 4;
