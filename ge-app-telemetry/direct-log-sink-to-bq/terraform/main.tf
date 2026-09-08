# ==============================================================================
# Google Antigravity (Gemini Enterprise) - Terraform Ingestion Pipeline
# ==============================================================================

locals {
  target_project_id = coalesce(var.destination_project_id, var.project_id)
  partition_expiration_ms = var.partition_expiration_days > 0 ? var.partition_expiration_days * 86400 * 1000 : null
  
  # Strip 'serviceAccount:' prefix if present for BigQuery dataset access userByEmail
  sink_writer_email = replace(google_logging_project_sink.agy_telemetry_sink.writer_identity, "serviceAccount:", "")
}

# ------------------------------------------------------------------------------
# 1. Dedicated BigQuery Dataset
# ------------------------------------------------------------------------------
resource "google_bigquery_dataset" "agy_telemetry" {
  project                     = local.target_project_id
  dataset_id                  = var.dataset_id
  location                    = var.dataset_location
  description                 = "Google Antigravity Enterprise Telemetry Mart (Gemini Enterprise)"
  default_partition_expiration_ms = local.partition_expiration_ms
  labels                      = var.resource_labels

  lifecycle {
    prevent_destroy = false
  }
}

# ------------------------------------------------------------------------------
# 2. Cloud Logging Router Sink
# ------------------------------------------------------------------------------
resource "google_logging_project_sink" "agy_telemetry_sink" {
  name                   = var.sink_name
  project                = var.project_id
  destination            = "bigquery.googleapis.com/projects/${local.target_project_id}/datasets/${google_bigquery_dataset.agy_telemetry.dataset_id}"
  filter                 = "resource.type=\"businessaicode.googleapis.com/BAICInstance\" AND logName=~\"businessaicode.googleapis.com\""
  unique_writer_identity = true
  description            = "Routes Google Antigravity GE logs to dedicated BigQuery dataset"

  bigquery_options {
    use_partitioned_tables = true
  }

  dynamic "exclusions" {
    for_each = var.exclude_prompt_contents ? [1] : []
    content {
      name        = "exclude-prompt-contents"
      description = "Excludes raw prompt text and code diffs from BigQuery for Zero Data Retention"
      filter      = "logName=~\"businessaicode.googleapis.com%2Finference_response\" AND jsonPayload.contents:*"
    }
  }
}

# ------------------------------------------------------------------------------
# 3. IAM Permissions: Grant Sink Writer Access on BigQuery Dataset
# ------------------------------------------------------------------------------
resource "google_bigquery_dataset_access" "sink_writer_access" {
  project       = local.target_project_id
  dataset_id    = google_bigquery_dataset.agy_telemetry.dataset_id
  role          = "roles/bigquery.dataEditor"
  user_by_email = local.sink_writer_email
}

# ------------------------------------------------------------------------------
# 4. Optional: Grant Read Access to Downstream Consumer Identities
# ------------------------------------------------------------------------------
resource "google_bigquery_dataset_access" "readers_access" {
  for_each      = toset(var.reader_service_accounts)
  project       = local.target_project_id
  dataset_id    = google_bigquery_dataset.agy_telemetry.dataset_id
  role          = "roles/bigquery.dataViewer"
  user_by_email = replace(each.value, "serviceAccount:", "")
}
