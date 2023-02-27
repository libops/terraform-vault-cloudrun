variable "project" {
  type        = string
  description = "The GCP project to create or deploy the GCP resources into"
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
