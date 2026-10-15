# Google Antigravity Telemetry for Gemini Enterprise
`ge-app-telemetry`

Turn Google Antigravity usage logs into **BigQuery datasets, ready-made views and a dashboard**, so platform, engineering and FinOps teams can see who uses Antigravity, how much, with which models, and how developers respond to agent permission requests. Prompt and response text stays locked away.

> **All logs land in a locked raw dataset that only project owners can read. Dashboards and analysts use a separate views dataset that never returns prompt text.**

---

## Contents
1. [What you get](#1-what-you-get)
2. [How it works](#2-how-it-works)
3. [Privacy & access model](#3-privacy--access-model)
4. [Prerequisites](#4-prerequisites)
5. [Quick start](#5-quick-start)
6. [Deploying in detail](#6-deploying-in-detail)
7. [Verifying the deployment](#7-verifying-the-deployment)
8. [Dashboards](#8-dashboards)
9. [Sharing access](#9-sharing-access)
10. [Views reference](#10-views-reference)
11. [Sample queries](#11-sample-queries)
12. [Operations](#12-operations)
13. [Command reference](#13-command-reference)
14. [Troubleshooting](#14-troubleshooting)
15. [Known limitations](#15-known-limitations)
16. [FAQ](#16-faq)
17. [Repository layout](#17-repository-layout)

---

## 1. What you get

| Component | What it is |
| :--- | :--- |
| **Log sink** `ge-app-agy-telemetry-sink` | Routes every Antigravity log entry (`businessaicode.googleapis.com`) from Cloud Logging into BigQuery in near real time |
| **RAW dataset** `ge_app_agy_raw` | The complete logs (requests, responses, client events), **including prompts and model responses**. Locked to project owners |
| **Views dataset** `ge_app_agy_telemetry` | 6 ready-made views (adoption, sessions, tokens, permission decisions, per-user and per-model summaries). **No prompt text.** Locked to project owners until you share it |
| **Local web dashboard** | A 5-tab dashboard (Overview, Adoption & Enablement, Fleet & Models, Usage & Tokens, Value & Quality) that runs on your workstation |
| **Looker Studio** | Point Looker Studio at the views for shareable reports |
| **View validation tool** | Tests every view against synthetic data with known answers |

**What you can answer:**
- How many developers use Antigravity daily and weekly, and on which surfaces (Hub, CLI, IDE)?
- How many sessions and inferences are there, per user, per day and per model?
- How many tokens are consumed, by type (prompt, output, thinking, cached), model and reasoning tier?
- Which models and client versions are in use?
- How often do developers accept or reject agent permission requests (for example terminal commands)?

---

## 2. How it works

```
┌────────────────────────────────────────────────────────────────────────┐
│  Developers: Antigravity Hub · Antigravity CLI (agy) · IDE extensions  │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ authenticated with a Gemini Enterprise license
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│  Cloud Logging  ·  resource: businessaicode.googleapis.com/BAICInstance │
│  logs: inference_request · inference_response · client_telemetry       │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ Log Router sink (streams new entries, ~1 min)
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│  RAW dataset  ge_app_agy_raw            (project owners only)           │
│  3 tables, daily partitions, retention = --retention-days (default 90) │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ authorized views (computed on query; no copies)
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│  VIEWS dataset  ge_app_agy_telemetry    (owners + whoever you share it) │
│  user_summary · adoption · trust_quality · token_economics ·           │
│  model_summary · daily_sessions                    — no prompt text    │
└───────────────────┬───────────────────────────────┬────────────────────┘
                    ▼                               ▼
           Local web dashboard              Looker Studio / BigQuery
```

1. Antigravity writes one log entry per model request, per model response and per client event (for example "user accepted a permission prompt").
2. A **Log Router sink** copies every new entry into the **RAW** dataset. It only exports entries written **after** the sink exists. Older entries still in Cloud Logging can be copied in with `backfill.sh` (see [Backfill history](#125-backfill-history)).
3. The **views** read RAW at query time. Because they're **authorized views**, people with access to the views dataset can query them **without** any access to RAW.
4. The **dashboard** queries the views only.

There are no scheduled jobs and no data copies: the views are always current, typically within a minute of usage.

---

## 3. Privacy & access model

### What is stored where
| Data | RAW `ge_app_agy_raw` | Views `ge_app_agy_telemetry` |
| :--- | :--- | :--- |
| User email, model, client, client version, session (trajectory) id, request id, timestamps | ✅ | ✅ |
| Token counts (total, prompt, output, thinking, cached) and quota type | ✅ | ✅ (aggregated) |
| Permission decisions (accepted / rejected) | ✅ | ✅ (aggregated) |
| **Prompt text** (`inference_request.input.messages[].content`) | ✅ | ❌ never |
| **Model response text** (`inference_response.output…messages[].content`) | ✅ | ❌ never |

### Who can read what
| Principal | RAW | Views |
| :--- | :--- | :--- |
| Project **Owners** | ✅ | ✅ |
| The sink's writer identity | write only | — |
| The 6 authorized views | ✅ (the views themselves, not their readers) | — |
| People / groups you grant **BigQuery Data Viewer on the views dataset** | ❌ | ✅ |
| Basic project **Viewer** role | ❌ (`deploy.sh` removes the default dataset entry) | ❌ (same) |
| Project **Editor**, **BigQuery Admin / Data Owner / Data Viewer** (project-level IAM) | ⚠️ ✅ inherited | ⚠️ ✅ inherited |

> [!IMPORTANT]
> Be explicit with stakeholders:
> * **Prompts and responses are stored** in RAW for the retention period you choose (default 90 days).
> * Project-level **Editor** and **BigQuery Admin / Data Owner / Data Viewer** IAM roles can read both datasets. Dataset settings cannot block inherited project roles. Keep those roles limited, or host the datasets in a dedicated project (see `--dest-project-id`).
> * The views and dashboards **never return prompt or response text**.

**Why not just filter prompts out of the logs?** Cloud Logging exclusions can only drop **whole** log entries, not individual fields. Response entries carry both the token counts (needed) and the model output (sensitive). Dropping them would lose the telemetry. So everything is stored, locked, and exposed only through views.

---

## 4. Prerequisites

### 4.1 Antigravity
- Developers use Antigravity (Hub, CLI or IDE) signed in with a **Gemini Enterprise** license tied to your Google Cloud project. Antigravity then writes `businessaicode.googleapis.com` logs to that project's Cloud Logging.
- To check: Cloud Console → **Logging → Logs Explorer**, query `resource.type="businessaicode.googleapis.com/BAICInstance"`.

### 4.2 Permissions for the person (or service account) running `deploy.sh`
| Role | Why |
| :--- | :--- |
| `roles/logging.configWriter` | Create / update the Log Router sink |
| `roles/bigquery.admin` | Create datasets, tables and views; set dataset access and view authorizations |
| `roles/serviceusage.serviceUsageAdmin` | Enable the Logging and BigQuery APIs if they're not already on |

Project **Owner** covers all of these. To **use** the dashboard as shipped, you also need to be a project **Owner**, or have been granted access to the views dataset (see [Sharing access](#9-sharing-access)).

### 4.3 Tools on your machine
| Tool | Notes |
| :--- | :--- |
| `gcloud` and `bq` (Google Cloud SDK) | Run `gcloud auth login` first |
| `jq`, `python3` | Used by the scripts (Python standard library only) |
| `node` (v18+) | Only for the local web dashboard |

### 4.4 APIs
`logging.googleapis.com` and `bigquery.googleapis.com`. `deploy.sh` enables them automatically.

---

## 5. Quick start

```bash
git clone <this repository> && cd antigravity-extensions/ge-app-telemetry

# 1. Authenticate
gcloud auth login
gcloud config set project <PROJECT_ID>

# 2. Deploy everything (interactive; press ENTER to accept defaults)
cd direct-log-sink-to-bq
./deploy.sh

# 3. Wait ~5 minutes for the new sink to start routing, then use Antigravity as usual

# 4. Open the dashboard
cd ../dashboards/local-web
./fetch_data.sh <PROJECT_ID>
./start.sh 8085        # prints the URL, e.g. http://<your-host>:8085
```

---

## 6. Deploying in detail

### 6.1 Interactive mode (recommended the first time)
```bash
cd ge-app-telemetry/direct-log-sink-to-bq
./deploy.sh
```
You're asked for each setting. Press **ENTER** to accept the value in brackets:

| Prompt | Default | What it means |
| :--- | :--- | :--- |
| Source GCP Project ID | active `gcloud` project | The project where Antigravity writes its logs. The sink is created here |
| Destination GCP Project ID | same as source | The project that hosts the two BigQuery datasets. Use a separate project if you want to isolate the data from the source project's Editors |
| Raw dataset ID | `ge_app_agy_raw` | Holds all log fields, including prompts |
| Views dataset ID | `ge_app_agy_telemetry` | Holds the views; this is what dashboards read |
| Dataset Residency Location | `us-central1` | BigQuery location for both datasets, e.g. `asia-northeast1`, `europe-west1`, `EU`, `US`. **Cannot be changed later** |
| Cloud Logging Sink Name | `ge-app-agy-telemetry-sink` | Name of the Log Router sink |
| Raw data retention in days | `90` | Days of data kept in RAW (prompts included); `0` = never delete. Values under 90 shorten the 90-day window in the user and model summaries (a warning is shown) |

A **summary** is then shown, together with a notice that prompts are stored in RAW and who can read it. Type `y` to proceed.

### 6.2 Headless mode (CI/CD, scripts)
```bash
./deploy.sh -p my-ge-project -l us-central1 -r 365 -y
```
All flags are listed in [Command reference](#13-command-reference).

### 6.3 Config file mode
```bash
cp config.example.yaml config.yaml     # edit the values
./deploy.sh --config=config.yaml -y
```
`config.yaml` is also picked up automatically when it's in the current directory. Supported keys:

| Key | Same as flag |
| :--- | :--- |
| `project_id` | `--project-id` |
| `destination_project_id` | `--dest-project-id` |
| `raw_dataset_id` | `--raw-dataset-id` |
| `dataset_id` | `--dataset-id` |
| `dataset_location` | `--location` |
| `sink_name` | `--sink-name` |
| `partition_expiration_days` | `--retention-days` |
| `deployer_service_account` | `--impersonate-sa` |

Flags on the command line take precedence over the config file.

### 6.4 What `deploy.sh` does, step by step
1. **Pre-flight:** checks that `gcloud`, `bq`, `jq` and `python3` are available and the schema files exist, loads the config, and validates your inputs.
2. **APIs:** enables Logging and BigQuery.
3. **Upgrade safety check:** if the views dataset still contains **tables** from an older version of this tool (which may contain prompts), it **stops** and prints migration steps (see [Upgrading](#124-upgrading-from-an-earlier-version)).
4. **Datasets:** creates RAW (with the retention you chose) and the views dataset in your location.
5. **RAW tables:** creates the 3 tables (`businessaicode_googleapis_com_inference_request`, `…_inference_response`, `…_client_telemetry`) from `schemas/raw/*.json`, partitioned daily on `timestamp`. Creating them up front means the views work even before any traffic arrives, and before rarely-seen fields have appeared. On re-runs, missing fields are added; nothing is ever removed.
6. **Sink:** creates or updates `ge-app-agy-telemetry-sink` with the filter `resource.type="businessaicode.googleapis.com/BAICInstance" AND logName=~"businessaicode.googleapis.com"`, writing to RAW with **no exclusions**.
7. **Lock-down:** grants the sink's writer identity write access to RAW, and removes BigQuery's default `projectReaders` / `projectWriters` entries from **both** datasets, so only project owners keep dataset access.
8. **Old prompt audit sink:** if `ge-app-agy-prompts-audit-sink` from an older version exists, it's deleted, because it would keep copying prompts elsewhere.
9. **Views:** runs `views/deploy_views.sh`, which creates or replaces the 6 views and **authorizes** each one on RAW.
10. **Summary:** prints what was created and how to share access.

### 6.5 Re-running `deploy.sh`
It's safe and idempotent. Existing datasets and tables are kept, missing schema fields are added, retention is updated, the lock-down and view authorizations are re-applied, and the views are replaced with the current SQL.

### 6.6 First data
> [!NOTE]
> A **newly created** sink takes a few minutes to start routing. In testing, logs written in the first ~3 minutes after creation were never exported, while everything after that arrived completely. **Wait ~5 minutes after the first deployment** before testing. After that, entries normally reach RAW within about a minute and appear in the views immediately. To recover the missed minutes, run `backfill.sh` (see [Backfill history](#125-backfill-history)).

### 6.7 Deploying with Terraform (alternative to `deploy.sh`)
`direct-log-sink-to-bq/terraform/` creates the same layout: both datasets locked to project owners, the 3 RAW tables from `schemas/raw/`, the sink to RAW, the 6 views from `views/*.sql` and their authorization on RAW.

```bash
cd ge-app-telemetry/direct-log-sink-to-bq/terraform
cp terraform.tfvars.example terraform.tfvars     # edit the values
terraform init
terraform plan
terraform apply
```

| Variable | Default | Description |
| :--- | :--- | :--- |
| `project_id` | required | Source project (where Antigravity logs; the sink is created here) |
| `destination_project_id` | same as `project_id` | Project hosting the datasets |
| `raw_dataset_id` | `ge_app_agy_raw` | RAW dataset (all fields incl. prompts; owners only) |
| `dataset_id` | `ge_app_agy_telemetry` | Views dataset (no prompt text) |
| `dataset_location` | `us-central1` | BigQuery location for both datasets. **Cannot be changed later** |
| `sink_name` | `ge-app-agy-telemetry-sink` | Log Router sink name |
| `partition_expiration_days` | `90` | RAW retention (`0` = never) |
| `view_readers` | `[]` | Read access to the **views dataset only**, e.g. `["group:analysts@example.com"]`. Prefixes: `user:`, `group:`, `serviceAccount:`, `domain:` |
| `enable_apis` | `true` | Enable the Logging and BigQuery APIs |
| `allow_destroy` | `false` | Allow `terraform destroy` to delete the RAW tables and their data |
| `resource_labels` | see file | Labels on datasets, tables and view-creation jobs |

Outputs: `raw_dataset_id`, `dataset_id`, `dataset_location`, `views`, `sink_name`, `sink_writer_identity`, `sink_destination`.

How it differs from `deploy.sh`:
- **Views** are created by running the same SQL files as BigQuery DDL jobs (this keeps the column descriptions). Editing a SQL file makes the next `terraform apply` re-create that view. If a view is deleted outside Terraform, recreate it with `terraform apply -replace='google_bigquery_job.view["<view_name>"]'` or run `views/deploy_views.sh`.
- **RAW table schemas** are created from `schemas/raw/` but later schema changes are ignored, because the sink adds columns on its own. To add fields from a newer schema file, run `deploy.sh` once (it only adds fields) or `bq update`.
- **Dataset access** is created as owners-only. Extra entries (sink writer, authorized views, `view_readers`) are separate `google_bigquery_dataset_access` resources; entries you add by hand are left alone.
- **Destroy:** with `allow_destroy = false` (default), `terraform destroy` fails on the RAW tables, which protects the data. Set it to `true` and apply first if you really want to delete everything.
- It does **not** delete the old `ge-app-agy-prompts-audit-sink`; see [Upgrading](#124-upgrading-from-an-earlier-version).

Use **either** `deploy.sh` **or** Terraform for a given project, not both, so there's one owner of the configuration.

---

## 7. Verifying the deployment

```bash
# Sink points at RAW, with no exclusions
gcloud logging sinks describe ge-app-agy-telemetry-sink --format="yaml(name,destination,exclusions)"

# RAW has 3 tables; the views dataset has 6 views and no tables
bq ls <PROJECT_ID>:ge_app_agy_raw
bq ls <PROJECT_ID>:ge_app_agy_telemetry

# Access: owners + sink writer + 6 authorized views; no projectReaders / projectWriters
bq show --format=prettyjson <PROJECT_ID>:ge_app_agy_raw | jq '.access'

# Generate some activity in Antigravity, wait ~1–2 minutes, then:
bq query --use_legacy_sql=false '
SELECT window_days, active_users, inferences, trajectories AS sessions, total_tokens
FROM `<PROJECT_ID>.ge_app_agy_telemetry.v_ge_app_agy_user_summary`
WHERE scope = "all_users" ORDER BY window_days'
```

Owners can inspect raw prompts (RAW only) if needed:
```bash
bq query --use_legacy_sql=false '
SELECT timestamp, labels.user_id, labels.model, m.content AS prompt_text
FROM `<PROJECT_ID>.ge_app_agy_raw.businessaicode_googleapis_com_inference_request`,
  UNNEST(jsonpayload_v1_inferencerequestlog.input.messages) m
ORDER BY timestamp DESC LIMIT 5'
```

---

## 8. Dashboards

### 8.1 Local web dashboard
```bash
cd ge-app-telemetry/dashboards/local-web
./fetch_data.sh <PROJECT_ID> [VIEWS_DATASET]   # default views dataset: ge_app_agy_telemetry
./start.sh [PORT]                               # default 8085; prints the URL
./stop.sh
```
- Run it as a **project owner**, or as someone with access to the views dataset.
- **↻ Refresh** in the header re-queries BigQuery.
- Fetched data is stored in `data/`, which is git-ignored because it contains user emails.

> [!WARNING]
> The local server has **no login** and listens on all network interfaces. Use it on trusted machines and networks only, and stop it when you're done (`./stop.sh`).

**Global controls**
| Control | Applies to |
| :--- | :--- |
| Range: last 7 / 30 / 90 days | Daily charts and KPIs computed from daily data |
| User / client / model filters | All charts that have that dimension. A banner shows active filters, with *Clear filters* |
| 7d / 90d toggle (Overview, Fleet & Models) | KPIs and tables computed from the exact window summaries |

**Tabs**
| Tab | KPIs | Charts & tables |
| :--- | :--- | :--- |
| **Overview** | Active users · Inferences · Sessions · Total tokens · Permission grant rate | Daily inferences + daily active users · Daily tokens · **User table**: one row per developer, sortable; click a row to filter every tab to that person |
| **Adoption & Enablement** | Users with activity · Peak daily active users · Days with activity · Inferences · Clients in use | Daily active users · Surface mix (Hub / CLI / IDE per day) · **Daily sessions** (exact) with inferences per session · Inferences per active user · Client versions |
| **Fleet & Models** | — | Inference share by model · Daily inferences by model · Reasoning tier (experience) · Model × client · **Model table** (users, inferences, share, sessions, tokens, avg/max tokens per inference, tiers, clients) |
| **Usage & Tokens** | Total · Prompt · Output · Thinking · Cached tokens · Tokens per inference | Daily tokens by type (with total and cached lines) · Tokens by model · Tokens by experience · Tokens per inference · Largest single inference by model |
| **Value & Quality** | Permission requests · Accepted · Rejected · Grant rate · Finished turns | Permission decisions per day · Grant rate by user · Grant rate by client · Finished turns per day |

**How to read some of the numbers**
- **Session** = one Antigravity conversation (trajectory). **Inference** = one model response.
- **Flash-lite models** (e.g. `gemini-3.5-flash-lite`) are **Antigravity background calls**. They have no session id, so they show 0 sessions and are excluded from "inferences per session".
- **Permission events carry no model label**, so the model filter does not apply on Value & Quality.
- **Finished turns** (`InferenceResolved`) means a turn completed. It also fires after a rejected permission, so it is **not** a success rate.
- **No cost figures** are shown. The logs contain token counts, not billing data.

### 8.2 Looker Studio
1. Open the [BigQuery console](https://console.cloud.google.com/bigquery) as a project owner.
2. Go to `<PROJECT_ID>` → `ge_app_agy_telemetry` → pick a view (e.g. `v_ge_app_agy_user_summary`).
3. Choose **Export → Explore with Looker Studio** (or create a BigQuery data source in Looker Studio).
4. In the data source settings, set **Data credentials → Owner's credentials**. Report viewers then see the charts **without** needing BigQuery access.
5. Share the report with the people or groups who need it.

Tip: use one data source per view. For daily charts use `v_ge_app_agy_adoption`, `…_token_economics`, `…_trust_quality` and `…_daily_sessions`. For KPIs and leaderboards use `…_user_summary` and `…_model_summary`.

---

## 9. Sharing access

Both datasets start **owner-only**. To let others use the data **without** exposing prompts:

| Who | How |
| :--- | :--- |
| **Analysts / a team group** | BigQuery console → `ge_app_agy_telemetry` → **Sharing → Permissions → Add principal** → role **BigQuery Data Viewer**. They also need `roles/bigquery.jobUser` on a project to run queries. They can query the views but **not** RAW |
| **Report viewers** | Use a Looker Studio report with **Owner's credentials** (see 8.2) and share the report; no BigQuery access needed |
| **Reviewers who must see prompts** | Grant BigQuery Data Viewer on **`ge_app_agy_raw`**. Do this only deliberately: it exposes all prompts and responses |

Never grant broad project-level BigQuery roles just to give access to the views. Grant at the dataset level instead.

---

## 10. Views reference

All views live in `ge_app_agy_telemetry`, read `ge_app_agy_raw`, and follow these rules:
- **No prompt or response text** is ever returned.
- **Duplicates removed** on `(insertId, timestamp)`.
- Days and windows are **UTC**.
- `user_email` = `labels.user_id` without the `user:` prefix, or `'unknown'` if missing. Other missing labels show as `'unspecified'`.
- Every column has a description in BigQuery (*Schema* tab).

### 10.1 `v_ge_app_agy_user_summary`: per developer, last 7 and 90 days
One row per `window_days` (7, 90) × user, **plus an `all_users` row per window**. That row is computed directly, not summed, so distinct counts are exact.

| Column | Meaning |
| :--- | :--- |
| `window_days` | 7 or 90 (rolling, from query time) |
| `scope` | `user` or `all_users` |
| `user_email` | Developer; `NULL` on `all_users` rows |
| `active_users` | Distinct users with ≥1 model response (1 or 0 on user rows) |
| `inferences` | Model responses |
| `trajectories` | Distinct sessions |
| `active_days` | Distinct days with activity |
| `inferences_per_trajectory` | inferences ÷ sessions |
| `total_tokens`, `prompt_tokens`, `candidates_tokens`, `thoughts_tokens`, `cached_content_tokens` | Token sums (output = candidates; thinking = thoughts) |
| `avg_tokens_per_inference`, `max_tokens_per_inference` | Per-response token size |
| `models_used`, `top_model` | Distinct models; most-used model (ties broken alphabetically) |
| `clients` | Surfaces used, e.g. `antigravity_cli, antigravity_hub` |
| `first_seen`, `last_seen` | First and last activity in the window |
| `permission_requests_total`, `permission_grants_accepted`, `permission_grants_rejected`, `permission_grant_rate` | Permission prompts and accept rate |
| `token_share` | User's share of all tokens in the window |

### 10.2 `v_ge_app_agy_model_summary`: per model, last 7 and 90 days
One row per `window_days` × model, **plus an `all_models` row per window**.

Columns: `window_days`, `scope` (`model` / `all_models`), `model`, `active_users`, `inferences`, `trajectories`, `active_days`, the five token sums, `avg_tokens_per_inference`, `max_tokens_per_inference`, `experiences` (reasoning tiers used), `clients`, `first_seen`, `last_seen`, `inference_share`, `token_share`.

No permission columns, because permission events carry no model label.

### 10.3 `v_ge_app_agy_adoption`: daily adoption
One row per day × user × client × client version × model.

| Column | Meaning |
| :--- | :--- |
| `event_date`, `user_email`, `client_name`, `client_version`, `model` | Dimensions |
| `total_inferences` | Model responses |
| `trajectories` | Distinct sessions in this row |
| `inferences_per_trajectory` | total_inferences ÷ trajectories |
| `active_hours_count` | Distinct UTC hours with activity |
| `first_activity_utc`, `last_activity_utc` | First and last activity |

### 10.4 `v_ge_app_agy_trust_quality`: daily permission decisions
One row per day × user × client × model.

| Column | Meaning |
| :--- | :--- |
| `event_date`, `user_email`, `client_name`, `model` | Dimensions (`model` is usually `unspecified` for permission events) |
| `total_events` | Client events |
| `trajectories` | Distinct sessions with client events |
| `inference_resolved_events` | Finished turns (not a success signal) |
| `permission_requests_total`, `permission_grants_accepted`, `permission_grants_rejected`, `permission_grant_rate` | Permission prompts and accept rate |

### 10.5 `v_ge_app_agy_token_economics`: daily tokens
One row per day × user × client × model × experience.

| Column | Meaning |
| :--- | :--- |
| `event_date`, `user_email`, `client_name`, `model`, `experience` | Dimensions (`experience` = model + reasoning tier, e.g. `gemini-4-argon-high`) |
| `total_inferences`, `trajectories` | Responses and sessions |
| `total_tokens`, `prompt_tokens`, `candidates_tokens`, `thoughts_tokens`, `cached_content_tokens` | Token sums as logged (they're not assumed to add up) |
| `avg_tokens_per_inference`, `min_tokens_per_inference`, `max_tokens_per_inference` | Per-response token size |

### 10.6 `v_ge_app_agy_daily_sessions`: exact daily sessions for any filter
One row per day × **every combination** of user, client and model, where `'(all)'` means "all values combined".

| Column | Meaning |
| :--- | :--- |
| `event_date`, `user_email`, `client_name`, `model` | Dimensions (`'(all)'` = combined) |
| `sessions` | Distinct sessions (exact) |
| `active_users` | Distinct users (exact) |
| `inferences` | All model responses, including background calls |
| `session_inferences` | Responses that belong to a session (excludes background calls) |

**How to use it:** pick the row whose dimensions match your filter, using `'(all)'` for every dimension you don't filter on. For example, all of Hub on one day is `user_email='(all)' AND client_name='antigravity_hub' AND model='(all)'`. **Never sum `sessions` across rows.** A session can span models, users' rows overlap, and summing would double count.

---

## 11. Sample queries
Replace `<PROJECT_ID>`.

**Team totals, last 7 and 90 days**
```sql
SELECT window_days, active_users, inferences, trajectories AS sessions, total_tokens, permission_grant_rate
FROM `<PROJECT_ID>.ge_app_agy_telemetry.v_ge_app_agy_user_summary`
WHERE scope = 'all_users' ORDER BY window_days;
```

**Top 20 developers by tokens this week**
```sql
SELECT user_email, inferences, trajectories AS sessions, total_tokens, ROUND(token_share * 100, 1) AS pct_tokens, top_model, clients
FROM `<PROJECT_ID>.ge_app_agy_telemetry.v_ge_app_agy_user_summary`
WHERE scope = 'user' AND window_days = 7
ORDER BY total_tokens DESC LIMIT 20;
```

**Daily active users and sessions (exact)**
```sql
SELECT event_date, active_users, sessions, inferences
FROM `<PROJECT_ID>.ge_app_agy_telemetry.v_ge_app_agy_daily_sessions`
WHERE user_email = '(all)' AND client_name = '(all)' AND model = '(all)'
ORDER BY event_date DESC;
```

**Model mix, last 90 days**
```sql
SELECT model, active_users, inferences, ROUND(inference_share * 100, 1) AS pct_inferences, total_tokens, experiences
FROM `<PROJECT_ID>.ge_app_agy_telemetry.v_ge_app_agy_model_summary`
WHERE scope = 'model' AND window_days = 90
ORDER BY inferences DESC;
```

**Tokens by type and model, last 30 days**
```sql
SELECT model, SUM(prompt_tokens) prompt, SUM(candidates_tokens) output, SUM(thoughts_tokens) thinking,
       SUM(cached_content_tokens) cached, SUM(total_tokens) total
FROM `<PROJECT_ID>.ge_app_agy_telemetry.v_ge_app_agy_token_economics`
WHERE event_date >= DATE_SUB(CURRENT_DATE(), INTERVAL 30 DAY)
GROUP BY model ORDER BY total DESC;
```

**Permission accept rate by user, last 30 days**
```sql
SELECT user_email, SUM(permission_requests_total) requests, SUM(permission_grants_accepted) accepted,
       ROUND(SAFE_DIVIDE(SUM(permission_grants_accepted), SUM(permission_requests_total)) * 100, 1) AS grant_rate_pct
FROM `<PROJECT_ID>.ge_app_agy_telemetry.v_ge_app_agy_trust_quality`
WHERE event_date >= DATE_SUB(CURRENT_DATE(), INTERVAL 30 DAY)
GROUP BY user_email HAVING requests > 0 ORDER BY requests DESC;
```

**Client version rollout**
```sql
SELECT client_name, client_version, COUNT(DISTINCT user_email) users, SUM(total_inferences) inferences
FROM `<PROJECT_ID>.ge_app_agy_telemetry.v_ge_app_agy_adoption`
WHERE event_date >= DATE_SUB(CURRENT_DATE(), INTERVAL 7 DAY)
GROUP BY 1, 2 ORDER BY 1, 2;
```

---

## 12. Operations

### 12.1 Change retention
```bash
./deploy.sh -p <PROJECT_ID> -r 365 -y     # or 0 = never expire
```
This updates RAW's default and per-table partition expiration. Shortening retention deletes older partitions **permanently**.

### 12.2 Redeploy or update the views only
```bash
cd ge-app-telemetry/views
./deploy_views.sh -p <PROJECT_ID> -d ge_app_agy_telemetry --raw-dataset-id ge_app_agy_raw -y
```
If you change view SQL, run the validation tool afterwards:
```bash
cd ge-app-telemetry/tools/view-validation
./run.sh -p <PROJECT_ID>          # synthetic data in isolated datasets; deleted afterwards
```

### 12.3 Pause collection
Disable the sink without deleting anything:
```bash
gcloud logging sinks update ge-app-agy-telemetry-sink --disabled --project=<PROJECT_ID>
# resume:
gcloud logging sinks update ge-app-agy-telemetry-sink --no-disabled --project=<PROJECT_ID>
```

### 12.4 Upgrading from an earlier version
Earlier versions wrote raw tables (including prompts) directly into `ge_app_agy_telemetry`, and could also create a prompt audit sink and dataset. `deploy.sh` **stops** if it finds tables in the views dataset. To upgrade:
```bash
# Option A: start fresh (simplest; history is removed)
./cleanup.sh -p <PROJECT_ID> -y -f
bq rm -r -f <PROJECT_ID>:ge_app_agy_prompts_audit      # old audit dataset, if you had one
./deploy.sh -p <PROJECT_ID> -y

# Option B: keep the old tables for reference, then deploy
bq mk --dataset --location=<LOCATION> <PROJECT_ID>:ge_app_agy_legacy
bq cp <PROJECT_ID>:ge_app_agy_telemetry.<table> <PROJECT_ID>:ge_app_agy_legacy.<table>   # per table
bq rm -f -t <PROJECT_ID>:ge_app_agy_telemetry.<table>                                    # per table
./deploy.sh -p <PROJECT_ID> -y
```
Old tables contain prompts, so restrict or delete `ge_app_agy_legacy` once you no longer need it. `deploy.sh` and `cleanup.sh` delete the old `ge-app-agy-prompts-audit-sink` automatically.

**If you deployed with the earlier Terraform version:** its state describes the old layout (tables in `ge_app_agy_telemetry`, an optional audit dataset and sink). Remove the old resources first, then apply the new configuration with a fresh state:
```bash
./cleanup.sh -p <PROJECT_ID> -y -f                      # sink, old audit sink, both datasets
bq rm -r -f <PROJECT_ID>:ge_app_agy_prompts_audit       # old audit dataset, if you had one
cd terraform && mv terraform.tfstate terraform.tfstate.old   # or use a new state backend/prefix
terraform init && terraform apply
```

### 12.5 Backfill history
The sink only exports new entries. `backfill.sh` copies entries that are **still in Cloud Logging** into RAW, for example activity from before you deployed, or from the first minutes of a new sink.

```bash
cd ge-app-telemetry/direct-log-sink-to-bq
./backfill.sh -p <PROJECT_ID> -n 7 --dry-run     # preview counts for the last 7 days
./backfill.sh -p <PROJECT_ID> -n 7 -y            # load them
./backfill.sh -p <PROJECT_ID> --start-time=2026-10-01T00:00:00Z --end-time=2026-10-03T00:00:00Z -s inference_response -y
```

How it works:
1. Reads the entries with `gcloud logging read` per log stream (`inference_response`, `client_telemetry`, `inference_request`).
2. Skips entries whose `insertId` is already in RAW (default), so it's safe to re-run and to overlap with what the sink already exported.
3. Maps each entry onto the **live RAW table schema**, using the same naming as the sink (field names matched case-insensitively, `@type` → `_type`). Fields the table doesn't have are dropped and listed in a warning.
4. Loads the rows into the RAW tables with `bq load`. They show up in the views immediately.

Things to know:
- Entries are stored **with all fields, including prompts and responses**, exactly like the sink stores them.
- Cloud Logging keeps entries in the `_Default` bucket for **30 days** unless you changed the bucket's retention, so older activity can't be recovered.
- Rows older than the RAW retention (`--retention-days`) are dropped by BigQuery's partition expiration.
- Run it as a project **Owner** (RAW is owners-only), with `roles/logging.viewer` on the source project.
- Large windows are read into memory; for heavy usage, backfill a few days at a time.

### 12.6 Uninstall
```bash
cd ge-app-telemetry/direct-log-sink-to-bq
./cleanup.sh                     # interactive; type "yes" to confirm
./cleanup.sh -p <PROJECT_ID> -y -f   # headless
```
This deletes the sink, the views dataset and the RAW dataset (**all stored logs, including prompts**). It aborts with an error if your credentials have expired, instead of reporting things as already deleted.

---

## 13. Command reference

### `direct-log-sink-to-bq/deploy.sh`
| Flag | Short | Default | Description |
| :--- | :--- | :--- | :--- |
| `--config FILE` | `-c` | `config.yaml` if present | YAML/JSON config file |
| `--project-id ID` | `-p` | active `gcloud` project | Source project (where Antigravity logs; sink is created here) |
| `--dest-project-id ID` | `-d` | same as `--project-id` | Project hosting the BigQuery datasets |
| `--raw-dataset-id ID` | | `ge_app_agy_raw` | RAW dataset (all fields incl. prompts; owners only) |
| `--dataset-id ID` | | `ge_app_agy_telemetry` | Views dataset (no prompt text; owners only) |
| `--location REGION` | `-l` | `us-central1` | BigQuery location for both datasets |
| `--sink-name NAME` | `-s` | `ge-app-agy-telemetry-sink` | Log Router sink name |
| `--retention-days DAYS` | `-r` | `90` | RAW retention (`0` = never) |
| `--impersonate-sa EMAIL` | | | Service account to impersonate for `gcloud` calls |
| `--yes` / `--headless` | `-y` | off | No prompts |
| `--help` | `-h` | | Show help |

### `direct-log-sink-to-bq/cleanup.sh`
| Flag | Short | Default | Description |
| :--- | :--- | :--- | :--- |
| `--config FILE` | `-c` | `config.yaml` if present | YAML/JSON config file |
| `--project-id ID` | `-p` | active `gcloud` project | Project where the sink is deployed |
| `--dest-project-id ID` | `-d` | same as `--project-id` | Project hosting the datasets |
| `--raw-dataset-id ID` | | `ge_app_agy_raw` | RAW dataset to delete |
| `--dataset-id ID` | | `ge_app_agy_telemetry` | Views dataset to delete |
| `--sink-name NAME` | `-s` | `ge-app-agy-telemetry-sink` | Sink to delete |
| `--force` | `-f` | off | Delete datasets without per-table prompts |
| `--yes` / `--headless` | `-y` | off | No confirmation |
| `--help` | `-h` | | Show help |

### `direct-log-sink-to-bq/backfill.sh`
| Flag | Short | Default | Description |
| :--- | :--- | :--- | :--- |
| `--config FILE` | `-c` | `config.yaml` if present | YAML config file (`project_id`, `destination_project_id`, `raw_dataset_id`, `lookback_days`, `skip_existing`, `deployer_service_account`) |
| `--project-id ID` | `-p` | active `gcloud` project | Source project (Cloud Logging) |
| `--dest-project-id ID` | `-d` | same as `--project-id` | Project hosting RAW |
| `--raw-dataset-id ID` | | `ge_app_agy_raw` | RAW dataset to load into |
| `--days DAYS` | `-n` | `7` | Look back this many days from now |
| `--start-time RFC3339` | | | Window start (overrides `--days`) |
| `--end-time RFC3339` | | now (UTC) | Window end |
| `--streams LIST` | `-s` | `all` | `all` or a comma list of `inference_response`, `client_telemetry`, `inference_request` |
| `--skip-existing BOOL` | | `true` | Skip entries whose `insertId` is already in RAW |
| `--dry-run` | | off | Show counts only |
| `--impersonate-sa EMAIL` | | | Service account to impersonate |
| `--yes` / `--headless` | `-y` | off | No confirmation |
| `--help` | `-h` | | Show help |

### `views/deploy_views.sh`
`deploy.sh` runs this for you; use it directly only to redeploy views.

| Flag | Short | Default | Description |
| :--- | :--- | :--- | :--- |
| `--config FILE` | `-c` | `config.yaml` if present | YAML config file |
| `--project-id ID` | `-p` | active `gcloud` project | Project hosting the datasets |
| `--dataset-id ID` | `-d` | `ge_app_agy_telemetry` | Views dataset. **Note:** `-d` here is the dataset, not the destination project as in `deploy.sh` |
| `--raw-dataset-id ID` | | `ge_app_agy_raw` | RAW dataset the views read |
| `--impersonate-sa EMAIL` | | | Service account to impersonate |
| `--yes` / `--headless` | `-y` | off | No prompts |
| `--help` | `-h` | | Show help |

### `dashboards/local-web/`
| Command | Description |
| :--- | :--- |
| `./fetch_data.sh <PROJECT_ID> [VIEWS_DATASET]` | Queries the 6 views into `data/telemetry.json` |
| `./start.sh [PORT]` | Starts the dashboard in the background (default 8085); fetches data first if none exists |
| `./stop.sh` | Stops it |

### `tools/view-validation/run.sh`
| Flag | Default | Description |
| :--- | :--- | :--- |
| `-p, --project-id ID` | required | Project for the temporary synthetic datasets |
| `-l, --location REGION` | `us-central1` | Their location |
| `--keep` | off | Keep `ge_app_agy_raw_synth` / `ge_app_agy_telemetry_synth` for inspection |

---

## 14. Troubleshooting

| Symptom | Likely cause | Fix |
| :--- | :--- | :--- |
| Views return no rows right after the first deploy | No Antigravity activity yet, or the new sink is still starting (~5 min) | Wait ~5 minutes, use Antigravity, re-query after 1–2 minutes |
| Some activity from the first minutes after deployment is missing | New sinks don't export during their first few minutes | Expected. Run `backfill.sh` (see [Backfill history](#125-backfill-history)) |
| `Reauthentication failed` / `Could not check dataset … ` | Expired `gcloud` credentials | `gcloud auth login`, then re-run |
| `deploy.sh` stops: "contains TABLES from the previous layout" | Upgrading from an older version | Follow [Upgrading](#124-upgrading-from-an-earlier-version) |
| `Access Denied` querying views | You're not an owner and weren't granted the views dataset | Grant BigQuery Data Viewer on the views dataset plus `bigquery.jobUser` (see [Sharing access](#9-sharing-access)) |
| Dashboard shows "Could not load telemetry data" | `data/telemetry.json` missing | Run `./fetch_data.sh <PROJECT_ID>` |
| Dashboard **Refresh** fails | Expired credentials, or the user running the server can't read the views | Re-authenticate; run the server as an owner |
| Model filter shows no permission data | Permission events have no model label | Expected; Value & Quality ignores the model filter |
| A model shows 0 sessions | It's a flash-lite background call (no session id) | Expected |
| `user_email = 'unknown'` | Log entries without a user label | Rare; counted, but not attributed |
| Warning about retention < 90 days | The 90-day summaries will only cover the retained days | Increase `-r` if you need full 90-day windows |

---

## 15. Known limitations
- **Limited history.** The sink only exports new log entries. `backfill.sh` can only recover what Cloud Logging still holds (30 days in the `_Default` bucket by default).
- **Prompts are stored** in RAW for the retention period, and there's no "don't store prompts" mode in this version.
- **Project-level IAM** (Editor, BigQuery Admin / Data Owner / Data Viewer) can read both datasets.
- **The local dashboard has no authentication.** Use Looker Studio with owner's credentials for shared reporting.
- **No cost / billing figures**: the logs contain token counts only.

---

## 16. FAQ

**Does anyone outside the project owners see prompts?**
Not through this tool. Views and dashboards never return prompt text. Prompts are readable only in RAW, which is owner-only at the dataset level. Project-level Editor and BigQuery admin roles can also read it, so manage those roles carefully.

**Is there a scheduled job or extra cost for processing?**
No jobs. You pay BigQuery storage for RAW, plus queries when views or dashboards run. At typical volumes this is very small. Older partitions automatically get BigQuery's lower long-term storage price.

**How fresh is the data?**
Usually within about a minute of usage. The views compute on query.

**Can the datasets live in a different project?**
Yes. Use `--dest-project-id`. The sink stays in the Antigravity project and writes to the other project's RAW dataset.

**Can I keep more than 90 days?**
Yes. Use `--retention-days 365` (or `0` to keep forever). Remember that prompts are kept for the same period.

**What's the difference between a session and an inference?**
A session (trajectory) is one Antigravity conversation. Each model response in it is an inference. Background flash-lite calls are inferences without a session.

**Why don't users and sessions add up across rows in the daily views?**
They're distinct counts per row. Use `v_ge_app_agy_daily_sessions` (exact for any filter) or the 7d/90d summary views.

---

## 17. Repository layout
```text
ge-app-telemetry/
├── README.md                         # This guide
├── schemas/raw/                      # RAW table schemas (pre-created by deploy.sh)
├── direct-log-sink-to-bq/
│   ├── deploy.sh                     # One-command deployment (datasets, lock-down, sink, views)
│   ├── cleanup.sh                    # Teardown
│   ├── config.example.yaml           # Config template
│   ├── backfill.sh                   # Copy older Cloud Logging entries into RAW
│   ├── terraform/                    # Terraform alternative to deploy.sh
│   └── README.md                     # Short module overview
├── views/
│   ├── 00_v_ge_app_agy_user_summary.sql
│   ├── 01_v_ge_app_agy_adoption.sql
│   ├── 02_v_ge_app_agy_trust_quality.sql
│   ├── 03_v_ge_app_agy_token_economics.sql
│   ├── 04_v_ge_app_agy_model_summary.sql
│   ├── 05_v_ge_app_agy_daily_sessions.sql
│   ├── deploy_views.sh               # Deploys + authorizes the views
│   └── README.md                     # View-by-view details
├── dashboards/local-web/             # Local web dashboard (Node.js + Chart.js)
├── tools/view-validation/            # Synthetic-data test for every view
└── docs/                             # Internal design notes
```
