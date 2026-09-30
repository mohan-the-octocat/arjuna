-- =============================================================================
-- View 3: v_ge_app_agy_token_economics
-- =============================================================================
-- Granularity: Daily per user, per model, per experience tier.
-- Purpose: FinOps visibility into token consumption, context depth, estimated
--          costs, and subscription tier classification.
-- =============================================================================

CREATE OR REPLACE VIEW `{{PROJECT_ID}}.{{DATASET_ID}}.v_ge_app_agy_token_economics`
OPTIONS(
  description = "Antigravity token consumption and FinOps mart: per-user token volumes, context sizes, estimated costs, and subscription tier classification."
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
    jsonpayload_v1_inferenceresponselog.experience,
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
  REGEXP_REPLACE(r.raw_user_id, r'^user:', '') AS user_email,
  COALESCE(r.client_name, 'unspecified') AS client_name,
  COALESCE(r.model, 'unspecified') AS model,
  COALESCE(r.experience, 'unspecified') AS experience,
  COUNT(1) AS total_inferences,
  COUNTIF(r.trajectory_id IS NOT NULL) AS trajectory_inferences,
  COUNTIF(r.trajectory_id IS NULL) AS aux_inferences,
  SUM(COALESCE(r.total_token_count, 0)) AS total_tokens,
  SUM(IF(r.trajectory_id IS NOT NULL, COALESCE(r.total_token_count, 0), 0)) AS trajectory_tokens,
  SUM(IF(r.trajectory_id IS NULL, COALESCE(r.total_token_count, 0), 0)) AS aux_tokens,
  ROUND(AVG(COALESCE(r.total_token_count, 0)), 2) AS avg_tokens_per_inference,
  MIN(r.total_token_count) AS min_tokens_in_turn,
  MAX(r.total_token_count) AS max_tokens_in_turn,
  COUNT(DISTINCT r.trajectory_id) AS active_trajectories,
  ROUND(SAFE_DIVIDE(
    SUM(IF(r.trajectory_id IS NOT NULL, COALESCE(r.total_token_count, 0), 0)),
    NULLIF(COUNT(DISTINCT r.trajectory_id), 0)
  ), 2) AS avg_tokens_per_trajectory,
  -- Cost calculations using per-model rate card with '*' fallback
  ROUND(SUM(COALESCE(r.total_token_count, 0) * COALESCE(rc.usd_per_1m_tokens, fb.usd_per_1m_tokens, 0.15) / 1e6), 4) AS estimated_cost_usd_list,
  ROUND(SUM(COALESCE(r.total_token_count, 0) * COALESCE(rc.usd_per_1m_tokens, fb.usd_per_1m_tokens, 0.15) / 1e6) * 0.5, 4) AS estimated_cost_usd_discounted,
  -- Seat vs Pay-as-you-go classification
  CASE 
    WHEN r.client_name IN ('antigravity_hub', 'antigravity_cli', 'vscode') THEN 'SEAT_INCLUDED'
    ELSE 'PAYGO_AUTOMATION'
  END AS subscription_tier_type
FROM
  raw_deduped r
LEFT JOIN
  rate_lookup rc
  ON COALESCE(r.model, 'unspecified') = rc.model
CROSS JOIN
  fallback_rate fb
GROUP BY
  event_date, user_email, client_name, model, experience, subscription_tier_type;
