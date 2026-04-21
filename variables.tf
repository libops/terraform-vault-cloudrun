variable "project" {
  type        = string
  description = "The GCP project to create or deploy the GCP resources into"
}

variable "region" {
  type        = string
  description = "The region to deploy CloudRun"
  default     = "us-east5"
}

variable "name" {
  type        = string
  description = "Cloud Run service name for the Vault server."
  default     = "vault-server"
}

variable "gsa_account_id" {
  type        = string
  description = "Service account id for the Vault runtime. Defaults to a truncated form of name."
  default     = ""
}

variable "init_job_name" {
  type        = string
  description = "Cloud Run job name used to initialize Vault."
  default     = "vault-init"
}

variable "repository" {
  type        = string
  description = "The AR repo to create or push the vault image into"
  default     = "private"
}

variable "image_name" {
  type        = string
  description = "Docker image name to push into Artifact Registry."
  default     = "vault-server"
}

variable "init_image" {
  type    = string
  default = "libops/vault-init:1.0.1"
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

variable "data_bucket_name" {
  type        = string
  description = "Bucket name for Vault data storage. Defaults to a name derived from project and service name."
  default     = ""
}

variable "key_bucket_name" {
  type        = string
  description = "Bucket name for stored Vault init material. Defaults to a name derived from project and service name."
  default     = ""
}

variable "kms_key_ring_name" {
  type        = string
  description = "KMS key ring name used for auto-unseal."
  default     = "vault-server"
}

variable "kms_key_name" {
  type        = string
  description = "KMS crypto key name used for auto-unseal."
  default     = "vault"
}

variable "create_kms" {
  type        = bool
  description = "Whether to create the KMS key ring and crypto key."
  default     = true
}

variable "admin_emails" {
  description = "List of emails (users or service accounts) that are allowed to access non-public routes by passing X-Admin-Token header with a google access token."
  type        = list(string)
  default     = []
}

variable "public_routes" {
  description = "List of Vault API paths that should be accessible without X-Admin-Token header."
  type        = list(string)
  default = [
    "/.well-known/",
    "/v1/identity/oidc/",
    "/v1/auth/oidc/",
    "/v1/auth/userpass/",
  ]
}
