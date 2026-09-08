# Antigravity Extensions

Enterprise extensions, telemetry pipelines, and integrations for **Google Antigravity** across Gemini Enterprise and Vertex AI Agent Platform.

---

## Modules and Architecture

* **[`ge-app-telemetry/`](ge-app-telemetry/):** Telemetry, data pipeline, and observability for Antigravity with Gemini Enterprise (GE App).
  * [`SPEC.md`](ge-app-telemetry/SPEC.md): Technical specification, telemetry taxonomy (`businessaicode.googleapis.com`), and data governance.
  * [`direct-log-sink-to-bq/`](ge-app-telemetry/direct-log-sink-to-bq/): Cloud Logging Router sink pushing to BigQuery dataset `ge_app_agy_telemetry` via `deploy.sh` or `terraform/`.
* *(Upcoming)* **`geap-paygo-telemetry/`:** Telemetry pipeline for Antigravity used via standalone Agent Platform (GEAP / Vertex AI) consumption.

---

## Quickstart

To deploy the direct log sink for Gemini Enterprise Antigravity:
```bash
cd ge-app-telemetry/direct-log-sink-to-bq
./deploy.sh
```
See the [direct-log-sink-to-bq README](ge-app-telemetry/direct-log-sink-to-bq/README.md) for configuration and deployment details.
