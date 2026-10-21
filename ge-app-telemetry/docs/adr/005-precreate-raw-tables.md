# ADR-005: Pre-create RAW staging tables with the sink's schema

- **Date:** 2026-10-13
- **Status:** Accepted (applies to the MVP RAW dataset, ADR-006)
- **Deciders:** sanjitmehta
- **Related:** [ADR-002](002-fixed-pipeline-defaults.md), the prompt-free telemetry spec (§4.2)

## Context
The spec originally let the Cloud Logging sink auto-create the RAW tables. During the Mohan-branch test (2026-10-06) we saw that the sink only creates columns for fields it has already received. `client_telemetry.metadata.interactiontype/interactionoutcome` only appear on approve/reject events, so they were missing until such an event occurred, and any query referencing them failed (`Field name metadata does not exist in STRUCT<...>`).

The curation MERGEs select an **explicit column list** from RAW. With auto-created tables they would fail until every optional field had been seen at least once.

## Decision
`deploy.sh` pre-creates the three RAW tables (DAY-partitioned on `timestamp`, 2-day expiration):
- request and response use `schemas/raw/inference_request.json` and `inference_response.json`;
- client_telemetry uses `schemas/raw/client_telemetry.json`.

They carry the exact types the sink writes: all fields `STRING`, except `timestamp` and `receiveTimestamp`, which are `TIMESTAMP`. These types were taken from the live-verified sink schema.

On re-deploy, missing fields are merged in additively. The sink keeps adding any other new fields on its own.

## Consequences
- (+) Curation works from the first run, before every optional field has been seen.
- (+) Fresh installs are deterministic (same goal as the telemetry pre-creation).
- (−) If Google changed the type of an existing field, sink writes for those entries could fail with schema-mismatch errors. Mitigation: the types match live data today, and T2/T4 check row parity between Cloud Logging and RAW.

## Alternatives considered
| Option | Why not |
| :--- | :--- |
| Let the sink auto-create; build the MERGE dynamically from `INFORMATION_SCHEMA` (select `NULL` for missing fields) | More complex SQL (EXECUTE IMMEDIATE), harder to review |
| Let the sink auto-create; skip streams whose fields are missing | Silent data gaps |
