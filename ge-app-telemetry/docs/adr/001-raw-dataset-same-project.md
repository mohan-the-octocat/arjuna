# ADR-001: RAW dataset lives in the AGY-linked project

- **Date:** 2026-10-05
- **Status:** Accepted
- **Deciders:** sanjitmehta
- **Related:** Prompt-free telemetry (RAW → CURATED → Views) spec

## Context
The telemetry pipeline is moving to a layered design:

- **RAW** (`ge_app_agy_raw`) receives every `businessaicode.googleapis.com` log entry (`inference_request`, `inference_response`, `client_telemetry`) from a single Log Router sink. It contains **full prompts and model output**, and has a short retention period (2 days by default, or N days if prompts are kept for review).
- **CURATED** (`ge_app_agy_telemetry`) is populated by a scheduled-query `MERGE` that copies only prompt-free columns. Views, the dashboard and Looker read from it.

Antigravity / Gemini Enterprise is linked to a single GCP project, and its logs are emitted there. Putting RAW in a separate project would isolate prompts from project-level IAM. It would also add a cross-project sink identity, extra IAM bindings, and more setup steps for customers.

## Decision
Create the RAW dataset in the **same AGY-linked project** as the CURATED dataset.

`deploy.sh` and Terraform **don't expose a `--raw-project-id` / `raw_project_id` override** in this release.

## Consequences
**Positive**
- Simpler deployment: a single project, a same-project sink, and no cross-project IAM.
- Matches the customer mental model of "my AGY project".
- Fewer moving parts to validate in `deploy.sh`, `cleanup.sh` and Terraform.

**Negative / risks**
- Anyone with project-level **Owner**, **Editor**, or **BigQuery Admin / Data Owner / Data Viewer** inherits read access to RAW, and therefore to prompts.
- Hard isolation of prompts would later require a new flag plus a migration.

**Mitigations**
- `deploy.sh` lists the principals that hold those project-level roles and warns that they can read prompts.
- The docs recommend no project-level BigQuery data roles for humans. Analysts should get dataset-level `READER` on CURATED only.
- Prompt reviewers get dataset-level `READER` on RAW via `--prompt-reviewers`.
- The default is not to keep prompts. RAW then expires in about 2 days with 48h time travel, and prompt logs are excluded from the Cloud Logging `_Default` bucket.
- If isolation is needed later, migration is cheap because RAW has a short retention: create a new sink to the new project and let the old RAW expire.

## Alternatives considered
| Option | Why not now |
| :--- | :--- |
| Separate "prompts" project via `--raw-project-id` | Extra setup and IAM complexity. Deferred until a customer needs hard isolation |
| Redact before BigQuery (Pub/Sub + Dataflow) | Adds a streaming pipeline and its cost; out of scope for this fix |

## Amendment (2026-10-14)
- Testing showed that BigQuery adds default dataset access entries `READER:projectReaders`, `WRITER:projectWriters` and `OWNER:projectOwners` to every new dataset. That means even the basic **Viewer** role could read RAW. Under ADR-006, `deploy.sh` removes `projectReaders` and `projectWriters` from both datasets, keeping only owners.
- Project-level IAM roles (Editor, BigQuery Admin / Data Owner / Data Viewer) **still inherit read access**; dataset ACLs cannot remove that. Hard isolation remains deferred (ADR-007 item 2: separate locked project).
- Context update: under ADR-006, RAW is the long-term store (retention `--retention-days`), not a 2-day staging buffer.
