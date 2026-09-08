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
)
SELECT
  DATE(timestamp) AS event_date,
  REGEXP_REPLACE(raw_user_id, r'^user:', '') AS user_email,
  COALESCE(client_name, 'unspecified') AS client_name,
  COALESCE(model, 'unspecified') AS model,
  COALESCE(experience, 'unspecified') AS experience,
  COUNT(1) AS total_inferences,
  SUM(COALESCE(total_token_count, 0)) AS total_tokens,
  ROUND(AVG(COALESCE(total_token_count, 0)), 2) AS avg_tokens_per_inference,
  MIN(total_token_count) AS min_tokens_in_turn,
  MAX(total_token_count) AS max_tokens_in_turn,
  COUNT(DISTINCT trajectory_id) AS active_trajectories,
  ROUND(SAFE_DIVIDE(
    SUM(COALESCE(total_token_count, 0)),
    NULLIF(COUNT(DISTINCT trajectory_id), 0)
  ), 2) AS avg_tokens_per_trajectory,
  -- Cost calculations (Blended rate: $0.15 per 1M tokens)
  ROUND(SUM(COALESCE(total_token_count, 0)) * 0.00000015, 4) AS estimated_cost_usd_list,
  -- 50% Promotional discount for Gemini 3.5/3.7 Flash ($0.075 per 1M tokens)
  ROUND(SUM(COALESCE(total_token_count, 0)) * 0.000000075, 4) AS estimated_cost_usd_discounted,
  -- Seat vs Pay-as-you-go classification
  CASE 
    WHEN client_name IN ('antigravity_hub', 'antigravity_cli', 'vscode') THEN 'SEAT_INCLUDED'
    ELSE 'PAYGO_AUTOMATION'
  END AS subscription_tier_type
FROM
  raw_deduped
GROUP BY
  1, 2, 3, 4, 5, 15;
