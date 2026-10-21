-- =============================================================================
-- View 06: v_ge_app_agy_code_citations
-- =============================================================================
-- Grain:   one row per citation, i.e. per public source that a model response
--          closely matched (a response can carry several citations).
-- Source:  RAW inference_response,
--          output.attributionContext.citationMetadata.citations[].
-- Privacy: reads no prompt/response text. Outputs the cited URL, its license
--          and the character range of the match, never the matched text.
-- Notes:   * Citations are rare: they appear only when generated output closely
--            resembles existing public code.
--          * start/end indexes are character offsets in the response; the sink
--            stores JSON numbers as FLOAT, so they are cast to INT64 here. A
--            missing startIndex means 0 (protobuf JSON omits zero values).
--          * Covers all retained history (RAW retention).
--          * Dedupe on (insertId, timestamp); day boundaries are UTC.
-- Placeholders: {{PROJECT_ID}} {{DATASET_ID}} (views dataset) {{RAW_DATASET_ID}}
-- =============================================================================

CREATE OR REPLACE VIEW `{{PROJECT_ID}}.{{DATASET_ID}}.v_ge_app_agy_code_citations` (
  event_date      OPTIONS(description = "UTC date of the response (DATE(timestamp))."),
  event_timestamp OPTIONS(description = "Timestamp of the response."),
  user_email      OPTIONS(description = "labels.user_id without the 'user:' prefix; 'unknown' if missing."),
  client_name     OPTIONS(description = "labels.client_name; 'unspecified' if missing."),
  model           OPTIONS(description = "labels.model; 'unspecified' if missing."),
  trajectory_id   OPTIONS(description = "labels.trajectory_id (session); NULL for background calls."),
  request_id      OPTIONS(description = "labels.request_id of the response."),
  url             OPTIONS(description = "Public source the output resembles (citation url); 'unknown' if missing."),
  license         OPTIONS(description = "License of the cited source; 'unknown' if not reported."),
  start_index     OPTIONS(description = "Start character offset of the match in the response (0 when not logged: protobuf omits zero values)."),
  end_index       OPTIONS(description = "End character offset of the match in the response."),
  matched_chars   OPTIONS(description = "end_index - start_index: length of the matching span in characters.")
)
OPTIONS(
  description = "Antigravity code citations: model responses that closely matched public source code, with the cited URL and license. Source: inference_response. No prompt or response text."
) AS
WITH responses AS (
  SELECT
    timestamp,
    labels.user_id       AS raw_user_id,
    labels.client_name   AS client_name,
    labels.model         AS model,
    labels.trajectory_id AS trajectory_id,
    labels.request_id    AS request_id,
    jsonpayload_v1_inferenceresponselog.output.attributioncontext.citationmetadata.citations AS citations
  FROM
    `{{PROJECT_ID}}.{{RAW_DATASET_ID}}.businessaicode_googleapis_com_inference_response`
  WHERE
    timestamp IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (PARTITION BY insertId, timestamp ORDER BY receiveTimestamp DESC) = 1
)
SELECT
  DATE(r.timestamp)                                                             AS event_date,
  r.timestamp                                                                   AS event_timestamp,
  COALESCE(NULLIF(REGEXP_REPLACE(r.raw_user_id, r'^user:', ''), ''), 'unknown') AS user_email,
  COALESCE(r.client_name, 'unspecified')                                        AS client_name,
  COALESCE(r.model, 'unspecified')                                              AS model,
  r.trajectory_id                                                               AS trajectory_id,
  r.request_id                                                                  AS request_id,
  COALESCE(NULLIF(c.url, ''), 'unknown')                                        AS url,
  COALESCE(NULLIF(c.license, ''), 'unknown')                                    AS license,
  IFNULL(SAFE_CAST(c.startindex AS INT64), 0)                                   AS start_index,
  SAFE_CAST(c.endindex AS INT64)                                                AS end_index,
  SAFE_CAST(c.endindex AS INT64) - IFNULL(SAFE_CAST(c.startindex AS INT64), 0)  AS matched_chars
FROM
  responses AS r,
  UNNEST(r.citations) AS c;
