# ==============================================================================
# Google Antigravity (Gemini Enterprise) - Terraform Outputs
# ==============================================================================

output "raw_dataset_id" {
  description = "RAW dataset (all fields incl. prompts; owners only)."
  value       = google_bigquery_dataset.raw.dataset_id
}

output "dataset_id" {
  description = "Views dataset (authorized views; no prompt text)."
  value       = google_bigquery_dataset.views.dataset_id
}

output "dataset_location" {
  description = "Location of both datasets."
  value       = google_bigquery_dataset.views.location
}

output "views" {
  description = "Fully-qualified IDs of the deployed views."
  value       = [for v in keys(local.views) : "${local.dest_project_id}.${var.dataset_id}.${v}"]
}

output "sink_name" {
  description = "Cloud Logging sink name."
  value       = google_logging_project_sink.agy_telemetry_sink.name
}

output "sink_writer_identity" {
  description = "Service account the sink writes as (has WRITER on RAW only)."
  value       = google_logging_project_sink.agy_telemetry_sink.writer_identity
}

output "sink_destination" {
  description = "Sink destination URI (the RAW dataset)."
  value       = local.sink_destination
}
