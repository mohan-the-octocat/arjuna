# Google Cloud Monitoring Dashboard for Google Antigravity Telemetry

This directory contains code-defined Google Cloud Monitoring (GCM) dashboard templates and deployment tooling for Google Antigravity developer telemetry.

---

## Technical Context & Architectural Boundary

Cloud Monitoring supports SQL-defined charts via the `opsAnalyticsQuery` field in its dashboard API. However, there is a key architectural boundary to understand:

1. **Log Analytics Scope:** The backend query engine for `opsAnalyticsQuery` in Cloud Monitoring is **Cloud Logging Log Analytics**. It expects 4-part table references targeting Log Analytics log buckets:
   ```text
   `project_id.location.bucket_id.view_id`
   ```
   *(e.g., `my-project.global._Default._Default`)*
2. **BigQuery Dataset Boundary:** When `opsAnalyticsQuery` is pointed directly at a 3-part BigQuery dataset view (such as `project_id.ge_app_agy_telemetry.v_ge_app_agy_adoption`), the Cloud Monitoring API validates the JSON syntax at write time, but Cloud Console returns a render-time execution error:
   ```text
   Query error: Request contains an invalid argument.
   ```
3. **Recommended Production Visualizations:**
   * **Looker Studio (Cloud BI):** Connects natively to the BigQuery analytical views (`v_ge_app_agy_adoption`, `v_ge_app_agy_trust_quality`, `v_ge_app_agy_token_economics`) with zero-ETL and full interactive filtering. Access via BigQuery Console > **Explore data** > **Explore with Looker Studio**.
   * **Local Web Dashboard:** See [`../local-web/`](../local-web/) for an executive web dashboard running on Node.js with Chart.js and live BigQuery sync.

---

## Directory Contents

| File | Description |
| :--- | :--- |
| `ge_app_agy_dashboard.json.template` | Parameterized dashboard JSON template defining 6 SQL-backed charts and a 48-column mosaic layout. |
| `deploy_dashboard.sh` | Bash deployer that substitutes parameters, verifies etag, and creates or updates dashboards idempotently. |
| `README.md` | Architectural documentation, schema constraints, and deployment notes. |

---

## Deployment Script Usage (For Log Analytics Targets)

If your environment has Cloud Logging buckets upgraded to Log Analytics and linked to BigQuery, the included deployment script can deploy the dashboard definition:

```bash
# Validate configuration without deploying (dry-run):
./deploy_dashboard.sh -p <PROJECT_ID> -d <DATASET_ID> --validate-only

# Deploy or update idempotently:
./deploy_dashboard.sh -p <PROJECT_ID> -d <DATASET_ID>
```

### Script Flags
* `-p, --project <PROJECT_ID>`: Target Google Cloud project.
* `-d, --dataset <DATASET_ID>`: BigQuery dataset name.
* `--validate-only`: Validates the JSON schema against the Cloud Monitoring API without persisting.

---

## Teardown

To delete an existing dashboard from Cloud Monitoring:
```bash
gcloud monitoring dashboards delete <DASHBOARD_ID> --project=<PROJECT_ID> --quiet
```
