variable "project" {
  type        = string
  description = "The GCP project to create or deploy the GCP resources into"
}

variable "create_project" {
  type        = bool
  description = "Whether or not the GCP project needs to be created by this terraform"
  default     = false
}

variable "project_org_id" {
  type        = string
  description = "The gcloud org ID to put the GCP project in"
  default     = ""
}

variable "project_billing_account" {
  type        = string
  description = "The billing account to associate to the GCP project"
  default     = ""
}

variable "region" {
  type        = string
  description = "The region to deploy CloudRun"
  default     = "us-east5"
}

variable "repository" {
  type        = string
  description = "The AR repo to create or push the vault image into"
  default     = "private"
}

variable "create_repository" {
  type        = bool
  description = "Whether or not the AR repo needs to be created by this terraform"
  default     = true
}

variable "country" {
  type    = string
  default = "us"
}
