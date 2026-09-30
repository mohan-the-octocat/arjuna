-- =============================================================================
-- View 6: v_ge_app_agy_privacy_posture
-- =============================================================================
-- Granularity: Single summary row across dataset.
-- Purpose: Self-check on stored prompt text, response candidates, retention,
--          and unmasked user email exposure.
-- =============================================================================

CREATE OR REPLACE VIEW `{{PROJECT_ID}}.{{DATASET_ID}}.v_ge_app_agy_privacy_posture`
OPTIONS(
  description = "Antigravity privacy posture self-check view: prompt text storage, response candidate stripping, timestamp bounds, and distinct email count."
) AS
WITH req_deduped AS (
  SELECT
    timestamp,
    insertId,
    REGEXP_REPLACE(labels.user_id, r'^user:', '') AS user_email,
    EXISTS(
      SELECT 1
      FROM UNNEST(jsonpayload_v1_inferencerequestlog.input.messages) AS msg
      WHERE LENGTH(TRIM(COALESCE(msg.content, ''))) > 0
    ) AS has_prompt_text
  FROM
    `{{PROJECT_ID}}.{{DATASET_ID}}.businessaicode_googleapis_com_inference_request`
  WHERE
    timestamp IS NOT NULL
  QUALIFY ROW_NUMBER() OVER(PARTITION BY insertId ORDER BY timestamp DESC) = 1
),
resp_deduped AS (
  SELECT
    timestamp,
    insertId,
    REGEXP_REPLACE(labels.user_id, r'^user:', '') AS user_email,
    EXISTS(
      SELECT 1
      FROM UNNEST(jsonpayload_v1_inferenceresponselog.output.candidates) AS cand,
           UNNEST(cand.messages) AS msg
      WHERE LENGTH(TRIM(COALESCE(msg.content, ''))) > 0
    ) AS has_candidates
  FROM
    `{{PROJECT_ID}}.{{DATASET_ID}}.businessaicode_googleapis_com_inference_response`
  WHERE
    timestamp IS NOT NULL
  QUALIFY ROW_NUMBER() OVER(PARTITION BY insertId ORDER BY timestamp DESC) = 1
),
req_stats AS (
  SELECT
    COUNT(1) AS requests_total,
    COUNTIF(has_prompt_text) AS requests_with_prompt_text,
    MIN(timestamp) AS oldest_request_ts,
    MAX(timestamp) AS newest_request_ts
  FROM
    req_deduped
),
resp_stats AS (
  SELECT
    COUNT(1) AS responses_total,
    COUNTIF(has_candidates) AS responses_with_candidates
  FROM
    resp_deduped
),
email_stats AS (
  SELECT
    COUNT(DISTINCT user_email) AS distinct_user_emails
  FROM (
    SELECT user_email FROM req_deduped WHERE user_email IS NOT NULL AND user_email != ''
    UNION ALL
    SELECT user_email FROM resp_deduped WHERE user_email IS NOT NULL AND user_email != ''
  )
)
SELECT
  req_stats.requests_total,
  req_stats.requests_with_prompt_text,
  resp_stats.responses_total,
  resp_stats.responses_with_candidates,
  req_stats.oldest_request_ts,
  req_stats.newest_request_ts,
  email_stats.distinct_user_emails
FROM
  req_stats
CROSS JOIN
  resp_stats
CROSS JOIN
  email_stats;
