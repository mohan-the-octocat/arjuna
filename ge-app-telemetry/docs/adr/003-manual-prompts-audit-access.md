# ADR-003: Prompts audit access is granted manually (no automated reader grants)

- **Date:** 2026-10-05
- **Status:** Superseded by [ADR-006](006-mvp-locked-raw-authorized-views.md) (curation removed for the MVP)
- **Deciders:** sanjitmehta
- **Related:** [ADR-001](001-raw-dataset-same-project.md), [ADR-002](002-fixed-pipeline-defaults.md)

## Context
When prompts audit is enabled, `ge_app_agy_prompts_audit` holds full prompts and model responses. Automating reader grants (an interactive "Who may read prompts?" question or an `--audit-readers` flag) needs principal validation, idempotent dataset ACL edits, and clear removal semantics in `cleanup.sh`. Prompting for it during deploy also adds friction.

## Decision
`deploy.sh` and Terraform **don't grant any human or group read access** to the prompts audit dataset. They grant only:
- the curation service account: `WRITER` on the prompts audit dataset (and `READER` on RAW);
- the sink writer identity: `WRITER` on RAW.

After deployment, when prompts audit is enabled, `deploy.sh` prints:
```
ℹ No one has been granted read access to ge_app_agy_prompts_audit.
  Note: project Owners/Editors/BigQuery Admins can already read it (see ADR-001).
  To grant a reviewer access: BigQuery console → dataset → Sharing → Permissions,
  add the principal with role "BigQuery Data Viewer".
```

## Consequences
**Positive**
- Simpler deploy flow, with no extra questions.
- Access decisions stay with the customer's data owner and their own IAM process.

**Negative**
- Until someone grants access, only project-level Owner, Editor, or BigQuery Admin/Data Owner/Data Viewer principals can read prompts (ADR-001).
- Grants are outside the scripts' control: `cleanup.sh` deletes the dataset (and its ACLs) but doesn't track who was granted access.

## Future work
- Add an `--audit-readers` flag and Terraform variable (`user:` / `group:` principals) that grants dataset-level `READER`.
- Have `deploy.sh` list the project-level principals that inherit read on prompts.
- Optionally, IAM conditions or a separate prompts project (see ADR-001's alternatives).
