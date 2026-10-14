# ADR-006: MVP — locked RAW dataset + authorized views (curation removed)

- **Date:** 2026-10-14
- **Status:** Accepted
- **Deciders:** sanjitmehta
- **Supersedes:** [ADR-002](002-fixed-pipeline-defaults.md), [ADR-003](003-manual-prompts-audit-access.md), [ADR-004](004-curation-failure-alerting-deferred.md)
- **Related:** [ADR-001](001-raw-dataset-same-project.md), [ADR-005](005-precreate-raw-tables.md), [ADR-007](007-deferred-mvp-items.md)

## Context
The curation design (RAW staging → scheduled-query MERGE → prompt-free telemetry + optional prompts audit) was implemented and tested end to end on 2026-10-14. It worked, but it adds a scheduled query, a curation service account, a lookback window, a 2-day staging TTL, a `_Default` exclusion and an optional audit dataset. That's too much to explain to customers for an MVP.

The dashboard also needs **prompt-derived metrics** (for example skills, subagent, slash-command and hook usage), which a prompt-free copy cannot provide without extra featurization.

## Decision
For the MVP:
1. **One sink → `ge_app_agy_raw`** in the AGY-linked project (ADR-001), carrying all fields including prompts. Tables are pre-created (ADR-005), with partition expiration from `--retention-days` (default 90).
2. **RAW is locked:** the default dataset access entries `projectReaders` and `projectWriters` are removed, so only project owners keep dataset-level access.
3. **`ge_app_agy_telemetry` holds views only.** Each view is an **authorized view** on RAW, and the dataset has the same owner-only lock. The MVP ships 4 views:
   - `v_ge_app_agy_user_summary`: rolling 7 and 90 day windows, per user plus an all-users row;
   - `v_ge_app_agy_adoption`;
   - `v_ge_app_agy_trust_quality`;
   - `v_ge_app_agy_token_economics`.

   Views may read prompt fields to compute metrics but **never output prompt text**.
   - **Facts only:** no cost or billing estimates (flat-rate cost, subscription tier) and no metrics based on unverified signals (proposal acceptance, which has never been observed; "resolution rate", since `InferenceResolved` also fires on rejected turns).
4. **Access beyond owners is granted manually** (for example a Looker Studio data-source owner or an analysts group). `deploy.sh` prints how.
5. The local dashboard keeps working when run by a project owner. It only reads `ge_app_agy_telemetry`.
6. **All curation machinery is removed:** scheduled query, curation service account, prompts audit dataset, `_Default` exclusion, and the `--curation-*` flags. `--enable-prompt-audit`, `--audit-*` and `--exclude-prompts` are deprecated with warnings. The tested curation code is preserved as a snapshot for a future strict mode (ADR-007).

## Consequences
- (+) A two-sentence customer story: *"All logs land in a locked raw dataset. Dashboards use a separate views dataset that never shows prompt text."*
- (+) Fewer moving parts: no scheduled jobs, no extra service accounts, no freshness lag.
- (+) Prompt-derived dashboard metrics are possible in SQL views.
- (−) **Prompts are stored for the full retention period.** There's no "don't store prompts" option in the MVP.
- (−) Project-level **Editor** and **BigQuery Admin / Data Owner / Data Viewer** IAM roles still inherit read access to both datasets (ADR-001).
- (−) Whoever can open the dashboard sees everything it shows. The local dashboard has no login (code review H2).

## Alternatives considered
| Option | Why not for MVP |
| :--- | :--- |
| Curation (RAW → curated copies) | Built and tested, but too complex to explain. Kept for a strict mode (ADR-007) |
| Column-level security (policy tags) | Needs Data Catalog taxonomy and extra IAM; harder to explain |
| Views open to broad readers | Prompt-derived views could be queried ad hoc; MVP keeps everything owner-only |
