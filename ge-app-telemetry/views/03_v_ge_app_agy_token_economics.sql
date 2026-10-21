-- =============================================================================
-- View 03: v_ge_app_agy_token_economics
-- =============================================================================
-- Grain:   one row per UTC day x user x client x model x experience.
-- Source:  RAW inference_response (metadata token counts, logged as STRING).
-- Privacy: reads no prompt/response text; outputs metrics only.
-- Notes:   * Token columns are raw sums of the logged counters; no relationship
--            between them (e.g. total = prompt + candidates + thoughts) is assumed.
--          * No cost or billing estimates are computed here.
--          * avg/min/max ignore responses without a token count.
--          * Dedupe on (insertId, timestamp); day boundaries are UTC.
-- Placeholders: {{PROJECT_ID}} {{DATASET_ID}} (views dataset) {{RAW_DATASET_ID}}
-- =============================================================================

CREATE OR REPLACE VIEW `{{PROJECT_ID}}.{{DATASET_ID}}.v_ge_app_agy_token_economics` (
  event_date               OPTIONS(description = "UTC date of the response (DATE(timestamp))."),
  user_email               OPTIONS(description = "labels.user_id without the 'user:' prefix; 'unknown' if missing."),
  client_name              OPTIONS(description = "labels.client_name; 'unspecified' if missing."),
  model                    OPTIONS(description = "labels.model; 'unspecified' if missing."),
  experience               OPTIONS(description = "jsonpayload experience, e.g. gemini-4-argon-high; 'unspecified' if missing."),
  total_inferences         OPTIONS(description = "Number of model responses (deduplicated inference_response rows)."),
  trajectories             OPTIONS(description = "Distinct labels.trajectory_id (sessions) with at least one response in this row."),
  total_tokens             OPTIONS(description = "SUM of metadata.totaltokencount (0 if none logged)."),
  prompt_tokens            OPTIONS(description = "SUM of metadata.prompttokencount (0 if none logged)."),
  candidates_tokens        OPTIONS(description = "SUM of metadata.candidatestokencount (0 if none logged)."),
  thoughts_tokens          OPTIONS(description = "SUM of metadata.thoughtstokencount (0 if none logged)."),
  cached_content_tokens    OPTIONS(description = "SUM of metadata.cachedcontenttokencount (0 if none logged)."),
  avg_tokens_per_inference OPTIONS(description = "AVG of metadata.totaltokencount over responses that logged it (2 decimals)."),
  min_tokens_per_inference OPTIONS(description = "MIN of metadata.totaltokencount."),
  max_tokens_per_inference OPTIONS(description = "MAX of metadata.totaltokencount.")
)
OPTIONS(
  description = "Antigravity token usage: daily token counters by type per user, client, model and experience. Source: inference_response. No prompt text, no cost estimates."
) AS
WITH responses AS (
  SELECT
    timestamp,
    labels.user_id                                    AS raw_user_id,
    labels.trajectory_id                              AS trajectory_id,
    labels.client_name                                AS client_name,
    labels.model                                      AS model,
    jsonpayload_v1_inferenceresponselog.experience    AS experience,
    SAFE_CAST(jsonpayload_v1_inferenceresponselog.metadata.totaltokencount         AS INT64) AS total_token_count,
    SAFE_CAST(jsonpayload_v1_inferenceresponselog.metadata.prompttokencount        AS INT64) AS prompt_token_count,
    SAFE_CAST(jsonpayload_v1_inferenceresponselog.metadata.candidatestokencount    AS INT64) AS candidates_token_count,
    SAFE_CAST(jsonpayload_v1_inferenceresponselog.metadata.thoughtstokencount      AS INT64) AS thoughts_token_count,
    SAFE_CAST(jsonpayload_v1_inferenceresponselog.metadata.cachedcontenttokencount AS INT64) AS cached_content_token_count
  FROM
    `{{PROJECT_ID}}.{{RAW_DATASET_ID}}.businessaicode_googleapis_com_inference_response`
  WHERE
    timestamp IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (PARTITION BY insertId, timestamp ORDER BY receiveTimestamp DESC) = 1
)
SELECT
  DATE(timestamp)                                                     AS event_date,
  COALESCE(NULLIF(REGEXP_REPLACE(raw_user_id, r'^user:', ''), ''), 'unknown') AS user_email,
  COALESCE(client_name, 'unspecified')                                AS client_name,
  COALESCE(model, 'unspecified')                                      AS model,
  COALESCE(experience, 'unspecified')                                 AS experience,
  COUNT(*)                                                            AS total_inferences,
  COUNT(DISTINCT trajectory_id)                                       AS trajectories,
  IFNULL(SUM(total_token_count), 0)                                   AS total_tokens,
  IFNULL(SUM(prompt_token_count), 0)                                  AS prompt_tokens,
  IFNULL(SUM(candidates_token_count), 0)                              AS candidates_tokens,
  IFNULL(SUM(thoughts_token_count), 0)                                AS thoughts_tokens,
  IFNULL(SUM(cached_content_token_count), 0)                          AS cached_content_tokens,
  ROUND(AVG(total_token_count), 2)                                    AS avg_tokens_per_inference,
  MIN(total_token_count)                                              AS min_tokens_per_inference,
  MAX(total_token_count)                                              AS max_tokens_per_inference
FROM
  responses
GROUP BY
  1, 2, 3, 4, 5;
