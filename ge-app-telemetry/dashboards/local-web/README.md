# Google Antigravity Local Web Dashboard

A lightweight, dependency-free web dashboard (Node.js + Chart.js) for Antigravity developer telemetry. It reads **only the views dataset** (`ge_app_agy_telemetry`, authorized views over the locked RAW dataset), so no prompt text is ever fetched.

> [!IMPORTANT]
> Both BigQuery datasets are owner-only by default, so run `fetch_data.sh` / `start.sh` as a **project owner**. The server has **no login**: use it on trusted machines only.

---

## Quick start
```bash
./fetch_data.sh <PROJECT_ID> [DATASET_ID]   # default dataset: ge_app_agy_telemetry
./start.sh [PORT]                           # default port 8085; prints the URL
./stop.sh
```
The **↻ Refresh** button in the header re-runs `fetch_data.sh` for the same project and dataset as the current data, and reloads it.

**Who can open it:** by default the server only accepts connections from the same machine (`127.0.0.1`). The server has no login, and the data includes user emails and usage.

If you run it on a remote workstation and browse from a laptop, either:
```bash
# Option A (recommended): SSH tunnel from the laptop, then open http://localhost:8085
ssh -L 8085:localhost:8085 <workstation>

# Option B: listen on all interfaces; anyone who can reach the port can see the data
HOST=0.0.0.0 ./start.sh 8085
```

---

## Tabs
| Tab | KPIs | Charts & tables |
| :--- | :--- | :--- |
| **Overview** (7d / 90d toggle) | Active users · Inferences · Sessions · Total tokens · Permission grant rate | Daily inferences + active users · Daily tokens · **User table** (sortable; click a row to filter all tabs) |
| **Adoption & Enablement** | Users · Peak daily active users · Days with activity · Inferences · Clients | Daily active users · Surface mix (Hub / CLI / IDE) · **Daily sessions** (exact) + inferences per session · Inferences per active user · Client versions |
| **Fleet & Models** (7d / 90d toggle) | — | Inference share by model · Daily inferences by model · Reasoning tier (experience) · Model × client · **Model table** |
| **Usage & Tokens** | Total / prompt / output / thinking / cached tokens · Tokens per inference | Daily tokens by type · Tokens by model · Tokens by experience · Tokens per inference · Largest single inference by model |
| **Value & Quality** | Permission requests · Accepted · Rejected · Grant rate · Finished turns · Code citations | Decisions per day · Grant rate by user · Grant rate by client · Finished turns per day · **Code citations table** (cited public source and license; never the matched text) |

**Global controls:** date range (last 7 / 30 / 90 **UTC dates**, including today) for daily charts, and user, client and model filters. The **Rolling 7 / 90 days** toggle on Overview and Fleet & Models is different: it uses the summary views' rolling window (the last 7 × 24 or 90 × 24 hours up to now), so its totals can differ from a 7-day date range.

**Data notes:**
* No cost or billing estimates are shown.
* Flash-lite models are Antigravity **background calls**. They have no session id, so they show 0 sessions.
* Permission events carry no model label, so the model filter does not apply on Value & Quality.
* `InferenceResolved` ("finished turns") is an activity signal, not a success signal.

---

## Data sources (`fetch_data.sh` → `data/telemetry.json`)
| Key | View | Used for |
| :--- | :--- | :--- |
| `adoption` | `v_ge_app_agy_adoption` | Daily inferences, active users, surface mix, models, versions |
| `trust_quality` | `v_ge_app_agy_trust_quality` | Permission decisions, finished turns |
| `token_economics` | `v_ge_app_agy_token_economics` | Tokens by type / model / experience |
| `daily_sessions` | `v_ge_app_agy_daily_sessions` | Exact daily sessions for any filter combination |
| `user_summary` | `v_ge_app_agy_user_summary` | Overview KPIs and user table (7d / 90d, exact) |
| `model_summary` | `v_ge_app_agy_model_summary` | Fleet & Models table and share donut (7d / 90d, exact) |
| `code_citations` | `v_ge_app_agy_code_citations` | Code citations KPI and table (Value & Quality) |

`data/` is git-ignored: it contains user emails and is regenerated on every fetch.

---

## Directory structure
```text
local-web/
├── fetch_data.sh       # Queries the 7 views and writes data/telemetry.json
├── server.mjs          # Zero-dependency Node.js HTTP server (static files, /api/data, /api/refresh)
├── start.sh / stop.sh  # Background server lifecycle
├── public/index.html   # Dashboard UI (Chart.js 4.4.4, pinned)
├── data/               # Fetched JSON (git-ignored)
└── README.md
```
