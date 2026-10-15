# ==============================================================================
# Google Antigravity (Gemini Enterprise) - Terraform Telemetry Pipeline
# ==============================================================================
# Same layout as ../deploy.sh:
#   1. RAW dataset (default ge_app_agy_raw): ALL log fields incl. prompts and
#      responses. Owners only. Tables pre-created from ../../schemas/raw/*.json.
#   2. Views dataset (default ge_app_agy_telemetry): authorized views over RAW
#      (../../views/*.sql) that never return prompt text. Owners only, plus
#      optional readers (var.view_readers).
#   3. Cloud Logging sink -> RAW (no exclusions). Its writer identity gets
#      WRITER on RAW only.
#
# Both datasets are created with an explicit access list (projectOwners only),
# so BigQuery's default projectReaders/projectWriters entries are never added.
# Further entries are managed with google_bigquery_dataset_access, hence
# lifecycle.ignore_changes = [access] on the datasets.
# ==============================================================================

locals {
  dest_project_id = coalesce(var.destination_project_id, var.project_id)

  partition_expiration_ms = var.partition_expiration_days > 0 ? var.partition_expiration_days * 86400 * 1000 : null

  schema_dir = "${path.module}/../../schemas/raw"
  views_dir  = "${path.module}/../../views"

  table_prefix = "businessaicode_googleapis_com_"
  raw_tables   = toset(["inference_request", "inference_response", "client_telemetry"])

  # View files in deployment order; view name = file name without the "NN_" prefix.
  view_files = [
    "00_v_ge_app_agy_user_summary.sql",
    "01_v_ge_app_agy_adoption.sql",
    "02_v_ge_app_agy_trust_quality.sql",
    "03_v_ge_app_agy_token_economics.sql",
    "04_v_ge_app_agy_model_summary.sql",
    "05_v_ge_app_agy_daily_sessions.sql",
  ]

  views = {
    for f in local.view_files :
    trimsuffix(substr(f, 3, -1), ".sql") => replace(replace(replace(
      file("${local.views_dir}/${f}"),
      "{{PROJECT_ID}}", local.dest_project_id),
      "{{DATASET_ID}}", var.dataset_id),
    "{{RAW_DATASET_ID}}", var.raw_dataset_id)
  }

  sink_filter      = "resource.type=\"businessaicode.googleapis.com/BAICInstance\" AND logName=~\"businessaicode.googleapis.com\""
  sink_destination = "bigquery.googleapis.com/projects/${local.dest_project_id}/datasets/${var.raw_dataset_id}"
  sink_writer      = trimprefix(google_logging_project_sink.agy_telemetry_sink.writer_identity, "serviceAccount:")

  # "user:a@x.com" -> { kind = "user", id = "a@x.com" }
  readers = {
    for m in var.view_readers : m => {
      kind = split(":", m)[0]
      id   = join(":", slice(split(":", m), 1, length(split(":", m))))
    }
  }
}

# ------------------------------------------------------------------------------
# 0. Required APIs
# ------------------------------------------------------------------------------
resource "google_project_service" "source" {
  for_each           = var.enable_apis ? toset(["logging.googleapis.com", "bigquery.googleapis.com"]) : toset([])
  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

resource "google_project_service" "destination" {
  for_each           = var.enable_apis && local.dest_project_id != var.project_id ? toset(["bigquery.googleapis.com"]) : toset([])
  project            = local.dest_project_id
  service            = each.value
  disable_on_destroy = false
}

# ------------------------------------------------------------------------------
# 1. RAW dataset (all fields incl. prompts; owners only)
# ------------------------------------------------------------------------------
resource "google_bigquery_dataset" "raw" {
  project                         = local.dest_project_id
  dataset_id                      = var.raw_dataset_id
  location                        = var.dataset_location
  description                     = "Antigravity RAW logs (all fields incl. prompts and responses). Owners only."
  default_partition_expiration_ms = local.partition_expiration_ms
  delete_contents_on_destroy      = var.allow_destroy
  labels                          = var.resource_labels

  access {
    role          = "OWNER"
    special_group = "projectOwners"
  }

  lifecycle {
    ignore_changes = [access]
  }

  depends_on = [google_project_service.source, google_project_service.destination]
}

# RAW tables are pre-created so the views never reference fields the sink has
# not seen yet. The sink may add columns later, so schema drift is ignored.
resource "google_bigquery_table" "raw" {
  for_each            = local.raw_tables
  project             = local.dest_project_id
  dataset_id          = google_bigquery_dataset.raw.dataset_id
  table_id            = "${local.table_prefix}${each.key}"
  schema              = file("${local.schema_dir}/${each.key}.json")
  deletion_protection = !var.allow_destroy
  labels              = var.resource_labels

  time_partitioning {
    type          = "DAY"
    field         = "timestamp"
    expiration_ms = local.partition_expiration_ms
  }

  lifecycle {
    ignore_changes = [schema]
  }
}

# ------------------------------------------------------------------------------
# 2. Views dataset (authorized views; no prompt text; owners + view_readers)
# ------------------------------------------------------------------------------
resource "google_bigquery_dataset" "views" {
  project                    = local.dest_project_id
  dataset_id                 = var.dataset_id
  location                   = var.dataset_location
  description                = "Antigravity telemetry views (authorized views over ${var.raw_dataset_id}; no prompt text). Owners only."
  delete_contents_on_destroy = true
  labels                     = var.resource_labels

  access {
    role          = "OWNER"
    special_group = "projectOwners"
  }

  lifecycle {
    ignore_changes = [access]

    precondition {
      condition     = var.dataset_id != var.raw_dataset_id
      error_message = "raw_dataset_id and dataset_id must be different datasets."
    }
  }

  depends_on = [google_project_service.source, google_project_service.destination]
}

# Views are created with the same DDL files as views/deploy_views.sh (this keeps
# the column descriptions). A changed SQL file gets a new job id, so the view is
# re-created on the next apply.
resource "random_id" "view_job" {
  for_each    = local.views
  byte_length = 4
  keepers = {
    sql = sha256(each.value)
  }
}

resource "google_bigquery_job" "view" {
  for_each = local.views
  project  = local.dest_project_id
  location = var.dataset_location
  job_id   = "agy_view_${each.key}_${random_id.view_job[each.key].hex}"
  labels   = var.resource_labels

  query {
    query              = each.value
    use_legacy_sql     = false
    create_disposition = ""
    write_disposition  = ""
  }

  depends_on = [google_bigquery_dataset.views, google_bigquery_table.raw]
}

# Authorize each view on RAW so it can read RAW without readers having RAW access.
resource "google_bigquery_dataset_access" "authorized_view" {
  for_each   = local.views
  project    = local.dest_project_id
  dataset_id = google_bigquery_dataset.raw.dataset_id

  view {
    project_id = local.dest_project_id
    dataset_id = google_bigquery_dataset.views.dataset_id
    table_id   = each.key
  }

  depends_on = [google_bigquery_job.view]
}

# Optional readers of the views dataset (never RAW).
resource "google_bigquery_dataset_access" "view_reader" {
  for_each       = local.readers
  project        = local.dest_project_id
  dataset_id     = google_bigquery_dataset.views.dataset_id
  role           = "READER"
  user_by_email  = contains(["user", "serviceAccount"], each.value.kind) ? each.value.id : null
  group_by_email = each.value.kind == "group" ? each.value.id : null
  domain         = each.value.kind == "domain" ? each.value.id : null
}

# ------------------------------------------------------------------------------
# 3. Cloud Logging sink -> RAW (no exclusions)
# ------------------------------------------------------------------------------
resource "google_logging_project_sink" "agy_telemetry_sink" {
  name                   = var.sink_name
  project                = var.project_id
  destination            = local.sink_destination
  filter                 = local.sink_filter
  unique_writer_identity = true
  description            = "Routes Google Antigravity GE logs to the locked RAW dataset ${var.raw_dataset_id}"

  bigquery_options {
    use_partitioned_tables = true
  }

  depends_on = [google_bigquery_table.raw]
}

resource "google_bigquery_dataset_access" "sink_writer" {
  project       = local.dest_project_id
  dataset_id    = google_bigquery_dataset.raw.dataset_id
  role          = "WRITER"
  user_by_email = local.sink_writer
}
