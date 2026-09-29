-- Verifies the planted stories directly in BigQuery after load.sh.
-- Usage:
--   sed "s/{{PROJECT_ID}}/<project>/g; s/{{DATASET_ID}}/ge_app_agy_telemetry/g" verify_stories.sql \
--     | bq query --use_legacy_sql=false --format=pretty --max_rows=200
WITH
req AS (
  SELECT timestamp, labels.user_id AS u, labels.trajectory_id AS t, labels.request_id AS r,
         labels.client_version AS v, labels.model AS m,
         jsonpayload_v1_inferencerequestlog.experience AS e,
         jsonpayload_v1_inferencerequestlog.input.messages[SAFE_OFFSET(0)].content AS c,
         resource.labels.resource_container AS proj
  FROM `{{PROJECT_ID}}.{{DATASET_ID}}.businessaicode_googleapis_com_inference_request`
),
resp AS (
  SELECT labels.trajectory_id AS t, labels.client_version AS v,
         SAFE_CAST(jsonpayload_v1_inferenceresponselog.metadata.totaltokencount AS INT64) AS tok,
         jsonpayload_v1_inferenceresponselog.metadata.prompttokencount IS NULL AS no_breakdown,
         jsonpayload_v1_inferenceresponselog.metadata.quotatype AS q,
         resource.labels.resource_container AS proj
  FROM `{{PROJECT_ID}}.{{DATASET_ID}}.businessaicode_googleapis_com_inference_response`
),
ct AS (
  SELECT timestamp, labels.trajectory_id AS t,
         jsonpayload_v1_clienttelemetrylog.eventtype AS et,
         jsonpayload_v1_clienttelemetrylog.metadata.interactiontype AS it,
         jsonpayload_v1_clienttelemetrylog.metadata.interactionoutcome AS io
  FROM `{{PROJECT_ID}}.{{DATASET_ID}}.businessaicode_googleapis_com_client_telemetry`
),
traj AS (
  SELECT t, ANY_VALUE(e) AS e, COUNT(DISTINCT r) AS steps, MIN(timestamp) AS first_ts
  FROM req WHERE t IS NOT NULL GROUP BY t
),
monthly AS (
  SELECT FORMAT_DATE('%Y-%m', DATE(timestamp)) AS mon, COUNT(DISTINCT u) AS users,
         COUNT(DISTINCT t) AS trajectories
  FROM req GROUP BY 1
)
SELECT '01 span' AS check_name, CONCAT(CAST(MIN(DATE(timestamp)) AS STRING), ' .. ', CAST(MAX(DATE(timestamp)) AS STRING)) AS k,
       COUNT(*) AS n FROM req
UNION ALL SELECT '02 users (distinct)', '', COUNT(DISTINCT u) FROM req
UNION ALL SELECT '03 monthly active users', mon, users FROM monthly
UNION ALL SELECT '04 monthly trajectories', mon, trajectories FROM monthly
UNION ALL SELECT '05 calls by client version', v, COUNT(*) FROM req GROUP BY v
UNION ALL SELECT '06 background share % by version', v, CAST(ROUND(100 * COUNTIF(t IS NULL) / COUNT(*)) AS INT64) FROM req GROUP BY v
UNION ALL SELECT '07 responses without token breakdown %', '', CAST(ROUND(100 * COUNTIF(no_breakdown) / COUNT(*)) AS INT64) FROM resp
UNION ALL SELECT '08 quotatype', IFNULL(q, 'NULL'), COUNT(*) FROM resp GROUP BY q
UNION ALL SELECT '09 model share % Sept 22-29', m, CAST(ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER ()) AS INT64)
  FROM req WHERE t IS NOT NULL AND DATE(timestamp) >= '2026-09-22' GROUP BY m
UNION ALL SELECT '10 rework % by experience', traj.e,
  CAST(ROUND(100 * COUNTIF(io IN ('MODIFIED', 'REJECTED')) / COUNT(*)) AS INT64)
  FROM ct JOIN traj USING (t) WHERE it = 'PROPOSAL_ACCEPTANCE' GROUP BY traj.e
UNION ALL SELECT '11 runaway trajectories (>300 steps)', CAST(DATE(first_ts) AS STRING), steps FROM traj WHERE steps > 300
UNION ALL SELECT '12 request rows with secret shapes', '',
  COUNTIF(REGEXP_CONTAINS(c, r'AIza[0-9A-Za-z_\-]{35}|(?i)password\s*=|\b[A-Z]{5}[0-9]{4}[A-Z]\b')) FROM req
UNION ALL SELECT '13 tokens (M) by project number', proj, CAST(ROUND(SUM(tok) / 1e6) AS INT64) FROM resp GROUP BY proj
UNION ALL SELECT '14 resolved trajectories %', '',
  CAST(ROUND(100 * (SELECT COUNT(DISTINCT t) FROM ct WHERE et = 'InferenceResolved') / (SELECT COUNT(*) FROM traj)) AS INT64)
UNION ALL SELECT '15 permission rejections %', '', CAST(ROUND(100 * COUNTIF(io = 'REJECTED') / COUNT(*)) AS INT64)
  FROM ct WHERE it = 'PERMISSION_GRANT'
UNION ALL SELECT '16 high-tier trajectories <=3 steps', '', COUNT(*) FROM traj WHERE ENDS_WITH(e, '-high') AND steps <= 3
ORDER BY check_name, k
