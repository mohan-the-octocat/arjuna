-- =============================================================================
-- View 10: v_ge_app_agy_customization
-- =============================================================================
-- Granularity: event_date x user_email x trajectory_id.
-- Purpose: Detects skills, subagents, slash commands, and hooks from request
--          message wrapper formats.
-- =============================================================================

CREATE OR REPLACE VIEW `{{PROJECT_ID}}.{{DATASET_ID}}.v_ge_app_agy_customization`
OPTIONS(
  description = "Antigravity customization adoption view: per-trajectory detection of skills, subagents, slash commands, and PreInvocation hooks."
) AS
WITH req_deduped AS (
  SELECT
    timestamp,
    insertId,
    REGEXP_REPLACE(labels.user_id, r'^user:', '') AS user_email,
    labels.trajectory_id,
    jsonpayload_v1_inferencerequestlog.input.messages AS messages
  FROM
    `{{PROJECT_ID}}.{{DATASET_ID}}.businessaicode_googleapis_com_inference_request`
  WHERE
    timestamp IS NOT NULL
    AND labels.trajectory_id IS NOT NULL
  QUALIFY ROW_NUMBER() OVER(PARTITION BY insertId ORDER BY timestamp DESC) = 1
),
msg_parsed AS (
  SELECT
    DATE(r.timestamp) AS event_date,
    r.user_email,
    r.trajectory_id,
    REGEXP_CONTAINS(COALESCE(m.content, ''), r'<SKILL[>\s]') AS has_skill,
    REGEXP_CONTAINS(COALESCE(m.content, ''), r'<SUBAGENT[>\s]') AS has_subagent,
    STRPOS(COALESCE(m.content, ''), 'is a [Slash Command]') > 0 AS has_slash,
    STRPOS(COALESCE(m.content, ''), 'injected by a PreInvocation hook') > 0 AS has_hook,
    REGEXP_EXTRACT_ALL(COALESCE(m.content, ''), r'(/[a-zA-Z0-9_-]+)[^\n]*is a \[Slash Command\]') AS extracted_cmds
  FROM
    req_deduped r
  LEFT JOIN
    UNNEST(r.messages) AS m
),
traj_daily AS (
  SELECT
    event_date,
    user_email,
    trajectory_id,
    LOGICAL_OR(COALESCE(has_skill, FALSE)) AS uses_skill,
    LOGICAL_OR(COALESCE(has_subagent, FALSE)) AS uses_subagent,
    LOGICAL_OR(COALESCE(has_slash, FALSE)) AS uses_slash,
    LOGICAL_OR(COALESCE(has_hook, FALSE)) AS uses_hook,
    ARRAY_CONCAT_AGG(extracted_cmds) AS all_cmds
  FROM
    msg_parsed
  GROUP BY
    event_date, user_email, trajectory_id
)
SELECT
  event_date,
  user_email,
  trajectory_id,
  uses_skill,
  uses_subagent,
  uses_slash,
  uses_hook,
  ARRAY(
    SELECT DISTINCT cmd
    FROM UNNEST(all_cmds) AS cmd
    WHERE cmd IS NOT NULL AND cmd != ''
    ORDER BY cmd
  ) AS slash_commands
FROM
  traj_daily;
