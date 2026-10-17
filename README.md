# Antigravity Extensions

Enterprise extensions, telemetry pipelines, and integrations for **Google Antigravity** across Gemini Enterprise and Vertex AI Agent Platform.

---

## Modules and Architecture

* **[`ge-app-telemetry/`](ge-app-telemetry/):** Telemetry, data pipeline, and observability for Antigravity with Gemini Enterprise (GE App). **Start with its [README](ge-app-telemetry/README.md).**
  * [`direct-log-sink-to-bq/`](ge-app-telemetry/direct-log-sink-to-bq/): Cloud Logging sink into a locked RAW BigQuery dataset (`ge_app_agy_raw`), deployed with `deploy.sh` or `terraform/`.
  * [`views/`](ge-app-telemetry/views/): Authorized views in `ge_app_agy_telemetry` that never return prompt text.
  * [`dashboards/local-web/`](ge-app-telemetry/dashboards/local-web/): Local web dashboard over the views.
* *(Upcoming)* **`geap-paygo-telemetry/`:** Telemetry pipeline for Antigravity used via standalone Agent Platform (GEAP / Vertex AI) consumption.

---

## Quickstart

To deploy the Gemini Enterprise Antigravity telemetry pipeline:
```bash
cd ge-app-telemetry/direct-log-sink-to-bq
./deploy.sh
```
See the [ge-app-telemetry README](ge-app-telemetry/README.md) for the full guide.
