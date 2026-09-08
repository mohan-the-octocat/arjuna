# Google Antigravity Local Web Dashboard

This directory provides a lightweight, interactive web dashboard that visualizes developer telemetry, quality/trust metrics, and FinOps token economics from BigQuery data marts (`ge_app_agy_telemetry`).

---

## Access Links

* **Workstation / Laptop Browser URL:** [http://sanjitmehta-work-1.c.googlers.com:8085](http://sanjitmehta-work-1.c.googlers.com:8085)
* **Localhost URL:** [http://localhost:8085](http://localhost:8085)

---

## Directory Structure

```text
local-web/
├── fetch_data.sh       # Queries BigQuery views and saves JSON snapshots to data/
├── server.mjs          # Zero-dependency Node.js HTTP server (handles static files & API)
├── start.sh            # Helper to fetch data and start background server
├── stop.sh             # Helper to stop background server
├── data/
│   ├── adoption.json
│   ├── trust_quality.json
│   ├── token_economics.json
│   └── telemetry.json  # Consolidated data bundle loaded by frontend
├── public/
│   └── index.html      # Responsive dashboard UI (Chart.js, KPI cards, attribution table)
└── README.md
```

---

## Operational Commands

### Start the Server
```bash
./start.sh [PORT]    # Defaults to port 8085
```

### Stop the Server
```bash
./stop.sh
```

### Refresh Data from BigQuery
You can either click the **"↻ Refresh from BigQuery"** button in the dashboard UI header, or run:
```bash
./fetch_data.sh <PROJECT_ID> <DATASET_ID>
# Example:
./fetch_data.sh default-project-alpha-1 ge_app_agy_telemetry
```

---

## Features & Visualizations

1. **Executive KPI Cards:**
   * **Developer Adoption:** Daily Active Developers, Total Inferences, Total Trajectories.
   * **Agent Trust & Quality:** Task Resolution Rate (%), Permission Grant Acceptance Rate (%), Avg Inferences per Task.
   * **FinOps:** Estimated Model List Cost (USD), 50% Flash Discounted Cost (USD), Total Processed Tokens (M).
2. **Interactive Trend Charts:**
   * Daily Inference Volume Over Time.
   * Active Multi-turn Trajectories Over Time.
   * Developer Tool Approvals (Accepted vs. Rejected permissions).
   * Model Usage Distribution (Gemini 3.7 Flash, 3.5 Flash, 3.1 Pro, etc.).
   * Daily Processed Token Volumes.
   * Daily Model Cost Attribution (List price vs. 50% Flash discount).
3. **Model & Tier Attribution Table:**
   * Granular date-by-date breakdown of model usage, token consumption, and subscription status (`SEAT_INCLUDED`).
