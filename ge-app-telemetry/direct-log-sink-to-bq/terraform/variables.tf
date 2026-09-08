# ==============================================================================
# Google Antigravity (Gemini Enterprise) - Terraform Variables
# ==============================================================================

variable "project_id" {
  description = "The source GCP Project ID where Antigravity is active and emitting logs."
  type        = string
}

variable "destination_project_id" {
  description = "The target GCP Project ID hosting the BigQuery dataset. Defaults to var.project_id."
  type        = string
  default     = ""
}

variable "dataset_id" {
  description = "Dedicated BigQuery Dataset identifier for Antigravity telemetry."
  type        = string
  default     = "ge_app_agy_telemetry"
}

variable "dataset_location" {
  description = "Data residency location for the BigQuery dataset (e.g. us-central1, asia-northeast1, EU)."
  type        = string
  default     = "us-central1"
}

variable "sink_name" {
  description = "Cloud Logging Log Router sink name."
  type        = string
  default     = "ge-app-agy-telemetry-sink"
}

variable "partition_expiration_days" {
  description = "Number of days before BigQuery auto-expires daily log partitions. Set to 0 to disable."
  type        = number
  default     = 90
}

variable "exclude_prompt_contents" {
  description = "If true, excludes raw prompt text and code diffs from BigQuery for privacy/Zero Data Retention."
  type        = bool
  default     = true
}

variable "reader_service_accounts" {
  description = "Optional list of Service Accounts, Users, or Groups to grant roles/bigquery.dataViewer on the dataset."
  type        = list(string)
  default     = []
}

variable "resource_labels" {
  description = "Labels attached to the BigQuery dataset for FinOps and organizational tagging."
  type        = map(string)
  default = {
    "managed-by"     = "antigravity-extensions"
    "module"         = "ge-app-direct-log-sink-to-bq"
    "telemetry-type" = "gemini-enterprise-antigravity"
  }
}
