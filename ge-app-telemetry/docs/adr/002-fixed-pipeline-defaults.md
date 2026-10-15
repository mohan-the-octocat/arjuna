# ADR-002: Fixed defaults for pipeline internals (no advanced settings yet)

- **Date:** 2026-10-05
- **Status:** Superseded by [ADR-006](006-mvp-locked-raw-authorized-views.md) (curation removed for the MVP)
- **Deciders:** sanjitmehta
- **Related:** [ADR-001](001-raw-dataset-same-project.md), the prompt-free telemetry (RAW → CURATED → Views) spec

## Context
The new pipeline (sink → RAW staging → 10-minute curation → telemetry and prompts audit datasets) has several internal knobs. Exposing all of them as interactive questions or flags would make `deploy.sh` harder to understand and test. Most customers have no reason to change them.

## Decision
In this release the following values are **hard-coded defaults**. They are shown in the deployment summary, but **neither interactive questions nor CLI flags** expose them:

| Setting | Fixed default |
| :--- | :--- |
| RAW staging dataset name | `ge_app_agy_raw` |
| RAW partition retention | 2 days |
| RAW time travel | 48 hours (BigQuery minimum) |
| Exclude `inference_request` / `inference_response` from the Cloud Logging `_Default` bucket | Yes when prompts audit is off; no when it is on |
| Curation lookback window | 2 hours |
| Curation service account | `agy-curation@<project>.iam.gserviceaccount.com` |

These remain user-configurable:
- curation frequency (`--curation-schedule`, default `every 10 minutes`, min 5 min);
- telemetry and prompts audit dataset names and retention (existing flags).

## Consequences
**Positive**
- The interactive flow stays close to today's: the existing questions, minus "separate dataset?", plus "Curation frequency".
- Fewer combinations to validate and test.

**Negative**
- Customers with stricter or looser needs (e.g., a 1-day staging target, longer lookback for very late logs, a pre-existing SA) must edit the script or Terraform.
- Prompts audit time travel uses the BigQuery default (7 days) and isn't tunable.

## Future work
Introduce an "advanced" tier, flags only (`--raw-dataset-id`, `--raw-retention-days`, `--raw-time-travel-hours`, `--exclude-from-default-bucket`, `--curation-lookback-hours`, `--curation-sa`), with validation:
- raw retention ≥ 2 days;
- time travel 48–168h in multiples of 24;
- lookback ≥ 2× the schedule interval and < raw retention.
