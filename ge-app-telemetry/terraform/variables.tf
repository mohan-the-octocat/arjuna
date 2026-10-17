# ==============================================================================
# Google Antigravity (Gemini Enterprise) - Terraform Variables
# ==============================================================================

variable "project_id" {
  description = "Source GCP project where Antigravity (Gemini Enterprise) is active and writes logs. The sink is created here."
  type        = string
}

variable "destination_project_id" {
  description = "GCP project hosting the BigQuery datasets. Defaults to project_id."
  type        = string
  default     = ""
}

variable "raw_dataset_id" {
  description = "RAW dataset: all log fields incl. prompts and responses. Owners only."
  type        = string
  default     = "ge_app_agy_raw"

  validation {
    condition     = can(regex("^[A-Za-z0-9_]+$", var.raw_dataset_id)) && length(var.raw_dataset_id) <= 1024
    error_message = "raw_dataset_id may contain only letters, digits and underscores."
  }
}

variable "dataset_id" {
  description = "Views dataset: authorized views over RAW that never return prompt text."
  type        = string
  default     = "ge_app_agy_telemetry"

  validation {
    condition     = can(regex("^[A-Za-z0-9_]+$", var.dataset_id)) && length(var.dataset_id) <= 1024
    error_message = "dataset_id may contain only letters, digits and underscores."
  }
}

variable "dataset_location" {
  description = "Data residency location for both datasets (e.g. us-central1, asia-northeast1, EU). Cannot be changed after creation."
  type        = string
  default     = "us-central1"
}

variable "sink_name" {
  description = "Cloud Logging Log Router sink name."
  type        = string
  default     = "ge-app-agy-telemetry-sink"
}

variable "partition_expiration_days" {
  description = "RAW retention: days before daily partitions expire. 0 = never expire. Below 90 the 90-day window in v_ge_app_agy_user_summary is incomplete."
  type        = number
  default     = 90

  validation {
    condition     = var.partition_expiration_days >= 0 && floor(var.partition_expiration_days) == var.partition_expiration_days
    error_message = "partition_expiration_days must be a non-negative integer."
  }
}

variable "view_readers" {
  description = "Principals granted read access (READER) on the views dataset only; RAW stays owners-only. Format: user:EMAIL, group:EMAIL, serviceAccount:EMAIL or domain:DOMAIN."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for m in var.view_readers : can(regex("^(user|group|serviceAccount|domain):.+$", m))
    ])
    error_message = "Each view_readers entry must look like user:EMAIL, group:EMAIL, serviceAccount:EMAIL or domain:DOMAIN."
  }
}

variable "enable_apis" {
  description = "Enable the Logging and BigQuery APIs on the source (and destination) project."
  type        = bool
  default     = true
}

variable "allow_destroy" {
  description = "If true, `terraform destroy` deletes the RAW tables and their data. Keep false in production."
  type        = bool
  default     = false
}

variable "resource_labels" {
  description = "Labels attached to the datasets, RAW tables and view-creation jobs."
  type        = map(string)
  default = {
    "managed-by"     = "antigravity-extensions"
    "module"         = "ge-app-telemetry"
    "telemetry-type" = "gemini-enterprise-antigravity"
  }
}
