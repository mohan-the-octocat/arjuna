# ADR-004: Curation failure alerting is deferred

- **Date:** 2026-10-06
- **Status:** Superseded by [ADR-006](006-mvp-locked-raw-authorized-views.md) (no scheduled curation in the MVP)
- **Deciders:** sanjitmehta
- **Related:** [ADR-002](002-fixed-pipeline-defaults.md), the prompt-free telemetry spec (§4.5)

## Context
A BigQuery scheduled query (the curation step) copies data every 10 minutes from RAW staging into the telemetry and prompts audit datasets. RAW keeps data for 2 days. **If curation keeps failing for more than about 2 days, data expires from RAW before it's curated.** Telemetry gets gaps, and prompts never reach the audit dataset.

BigQuery Data Transfer Service's built-in failure emails go **only to the transfer owner**, and the recipient can't be changed. The scheduled query runs as the `agy-curation@` service account, so those emails wouldn't reach a person.

## Decision
This release ships **no automated failure alerting**. `deploy.sh` doesn't ask for an alert email.

After deployment, `deploy.sh` prints how to check curation health:
```
ℹ Curation runs every 10 minutes. To check run history:
  BigQuery console → Scheduled queries → ge-app-agy-curation → Run history
  If runs fail for more than ~2 days, data in staging expires before it is curated.
```

## Consequences
- (+) Simpler deploy: no Monitoring API, no notification channels, no extra IAM.
- (−) Failures are silent until someone checks run history or notices gaps in the dashboard.
- (−) Extended outages (more than ~2 days) cause permanent data loss for that window.

## Future requirement
Add failure alerting through **Cloud Monitoring**:
- New interactive question `Alert email for curation failures [<active gcloud account>]:`, where `none` skips it; new flag `--alert-email`.
- `deploy.sh` creates an email notification channel, plus a log-based alert policy on curation run errors (`resource.type="bigquery_dts_config" AND severity>=ERROR`, scoped to the transfer config ID). The exact filter must be verified by forcing a failure.
- Requires the Cloud Monitoring API and `roles/monitoring.editor` for the deployer.
- `cleanup.sh` removes the policy and the channel.
- Test: force a curation failure and confirm the email arrives.

**Alternative for later:** a Pub/Sub notification topic on the transfer config plus a function, to route alerts to Slack or PagerDuty.
