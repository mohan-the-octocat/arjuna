# ==============================================================================
# Google Antigravity (Gemini Enterprise) - Terraform Outputs
# ==============================================================================

output "dataset_id" {
  description = "The dedicated BigQuery dataset ID for Antigravity telemetry."
  value       = google_bigquery_dataset.agy_telemetry.dataset_id
}

output "dataset_location" {
  description = "The geographic region where the BigQuery dataset is located."
  value       = google_bigquery_dataset.agy_telemetry.location
}

output "sink_name" {
  description = "The Cloud Logging Log Router sink identifier."
  value       = google_logging_project_sink.agy_telemetry_sink.name
}

output "sink_writer_identity" {
  description = "The auto-generated service account identity assigned to the Cloud Logging sink."
  value       = google_logging_project_sink.agy_telemetry_sink.writer_identity
}

output "bigquery_destination_uri" {
  description = "The fully-qualified BigQuery sink destination URI."
  value       = "bigquery.googleapis.com/projects/${coalesce(var.destination_project_id, var.project_id)}/datasets/${google_bigquery_dataset.agy_telemetry.dataset_id}"
}

output "prompt_audit_dataset_id" {
  description = "The isolated BigQuery dataset ID for prompt audit logs (null if disabled)."
  value       = var.enable_prompt_audit_dataset ? google_bigquery_dataset.agy_prompt_audit[0].dataset_id : null
}

output "prompt_audit_sink_name" {
  description = "The Cloud Logging sink identifier for prompt audit logs (null if disabled)."
  value       = var.enable_prompt_audit_dataset ? google_logging_project_sink.agy_prompt_audit_sink[0].name : null
}

output "prompt_audit_sink_writer_identity" {
  description = "The service account identity assigned to the prompt audit sink (null if disabled)."
  value       = var.enable_prompt_audit_dataset ? google_logging_project_sink.agy_prompt_audit_sink[0].writer_identity : null
}
