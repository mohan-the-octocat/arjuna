# `direct-log-sink-to-bq`

Deployment scripts for the Antigravity telemetry pipeline: a Cloud Logging sink that writes all Antigravity logs to a locked RAW BigQuery dataset, plus authorized views that never return prompt text.

**The full user guide is [`../README.md`](../README.md).** This page is only a map of the folder.

| File | Purpose | Guide section |
| :--- | :--- | :--- |
| `deploy.sh` | Creates or updates everything: RAW and views datasets (owners only), RAW tables, sink, view deployment and authorization. Safe to re-run | [Deploying in detail](../README.md#6-deploying-in-detail) |
| `config.example.yaml` | Config template for `deploy.sh` / `cleanup.sh` / `backfill.sh` | [Config file mode](../README.md#63-config-file-mode) |
| `cleanup.sh` | Deletes the sink, the views dataset and the RAW dataset (all stored logs) | [Uninstall](../README.md#126-uninstall) |
| `backfill.sh` | Copies entries still in Cloud Logging into RAW (skips ones already there) | [Backfill history](../README.md#125-backfill-history) |
| `terraform/` | Terraform alternative to `deploy.sh` with the same layout | [Deploying with Terraform](../README.md#67-deploying-with-terraform-alternative-to-deploysh) |

Quick start:
```bash
gcloud auth login
./deploy.sh                      # interactive; ENTER accepts defaults
./deploy.sh -p <PROJECT_ID> -y   # headless
./deploy.sh --help               # all flags
```

What gets created (defaults):
- `ge_app_agy_raw`: 3 daily-partitioned tables with **all** log fields, including prompts and responses. Project owners only.
- `ge_app_agy_telemetry`: 6 authorized views over RAW. No prompt text. Project owners only until you share it.
- `ge-app-agy-telemetry-sink`: routes `businessaicode.googleapis.com/BAICInstance` logs to RAW.
