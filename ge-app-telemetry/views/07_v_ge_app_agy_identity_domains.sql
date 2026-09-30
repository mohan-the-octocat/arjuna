-- =============================================================================
-- View 7: v_ge_app_agy_identity_domains
-- =============================================================================
-- Granularity: domain x project_id.
-- Purpose: Identity hygiene monitoring across email domains and GCP projects.
-- =============================================================================

CREATE OR REPLACE VIEW `{{PROJECT_ID}}.{{DATASET_ID}}.v_ge_app_agy_identity_domains`
OPTIONS(
  description = "Antigravity identity domain hygiene view: users, inferences, and activity bounds per email domain and GCP project."
) AS
WITH raw_deduped AS (
  SELECT
    timestamp,
    insertId,
    COALESCE(REGEXP_EXTRACT(logName, r'^projects/([^/]+)/'), resource.labels.resource_container, 'unspecified') AS project_id,
    REGEXP_REPLACE(labels.user_id, r'^user:', '') AS user_email
  FROM
    `{{PROJECT_ID}}.{{DATASET_ID}}.businessaicode_googleapis_com_inference_response`
  WHERE
    timestamp IS NOT NULL
  QUALIFY ROW_NUMBER() OVER(PARTITION BY insertId ORDER BY timestamp DESC) = 1
)
SELECT
  LOWER(COALESCE(REGEXP_EXTRACT(user_email, r'@(.+)$'), 'unknown')) AS domain,
  project_id,
  COUNT(DISTINCT user_email) AS users,
  COUNT(1) AS inferences,
  MIN(timestamp) AS first_seen,
  MAX(timestamp) AS last_seen
FROM
  raw_deduped
GROUP BY
  domain, project_id;
