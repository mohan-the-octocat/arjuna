terraform {
  required_version = ">= 1.3"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0, < 9.0" # tested with 8.7
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.0"
    }
  }
}
