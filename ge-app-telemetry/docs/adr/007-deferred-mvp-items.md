# ADR-007: Deferred items after the MVP

- **Date:** 2026-10-14
- **Status:** Accepted (future requirements)
- **Deciders:** sanjitmehta
- **Related:** [ADR-006](006-mvp-locked-raw-authorized-views.md)

Each item below is intentionally **out of the MVP**. Each one should get its own ADR when picked up.

| # | Item | Why deferred | Notes |
| :--- | :--- | :--- | :--- |
| 1 | **Prompt views dataset** for named reviewers (prompt text) | MVP shows no prompt text | A second authorized-views dataset (for example `ge_app_agy_prompts_audit`) with reviewer-only access; optional time filter (for example last 30 days) |
| 2 | **RAW in a separate locked project** | Editors and BigQuery Admins inherit read in the same project | Sink to a dataset in another project; authorized views work across projects in the same location. Also enables central collection from many AGY projects |
| 3 | **Dashboard identity + login** | Local dashboard runs as the caller and has no auth (H2) | `agy-dashboard@` SA; `fetch_data.sh` with `--impersonate-service-account`; IAP or Looker Studio for sharing |
| 4 | **Strict mode: "don't store prompts"** | Adds curation complexity | Reuse the tested curation snapshot (RAW 2d staging → curated copies, scheduled query, `_Default` exclusion) |
| 5 | **Per-team visibility** | MVP shows all users to all viewers | Row-level security or Looker user attributes |
| 6 | **Configurable internals / reader grants** | Simplicity | Flags for RAW name and reader groups, if customers ask |
| 7 | **Terraform parity** | Shell first | Mirror the MVP: RAW dataset + tables, views dataset, authorized-view access entries |
