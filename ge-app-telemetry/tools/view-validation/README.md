# View validation (synthetic data)

Checks that every view returns **exactly** the right numbers. It loads synthetic Antigravity logs with known answers into isolated datasets and compares each view against them.

```bash
./run.sh -p <PROJECT_ID>            # generate, load, deploy views, validate, delete
./run.sh -p <PROJECT_ID> --keep     # keep ge_app_agy_raw_synth / ge_app_agy_telemetry_synth for inspection
```

Your real datasets (`ge_app_agy_raw`, `ge_app_agy_telemetry`) are never touched. Run it after changing any view SQL.

## What it does
| Step | File |
| :--- | :--- |
| Generate about 20 users × 30 days of logs plus an independently computed `ground_truth.json` | `generate.py` (Python standard library only) |
| Load into `ge_app_agy_raw_synth`, then deploy all views into `ge_app_agy_telemetry_synth` | `run.sh` (uses `../../schemas/raw` and `../../views/deploy_views.sh`) |
| Compare every view with the ground truth | `validate.py` (exit code 1 on any mismatch) |

## Edge cases built into the data
- Duplicate deliveries of the same log entry (same `insertId` + `timestamp`).
- Sessions crossing UTC midnight, and sessions that use two models.
- Background flash-lite calls **without** a session (trajectory) id.
- Missing user / client labels and missing token counts.
- Permission accept/reject events **without** a model label (as in live logs).
- No events within ±3 h of the 7-day window boundary, so the window checks are deterministic.

## Checks
- `v_ge_app_agy_daily_sessions`: every day × user × client × model combination (sessions, users, inferences).
- `v_ge_app_agy_adoption`: daily inferences and daily active users.
- `v_ge_app_agy_token_economics`: tokens by type and inferences per model.
- `v_ge_app_agy_trust_quality`: permission requests / accepted / rejected, finished turns, events.
- `v_ge_app_agy_user_summary`: 7d and 90d, every user plus the all-users row (9 metrics); token share sums to 1.
- `v_ge_app_agy_model_summary`: 7d and 90d, every model plus the all-models row.
