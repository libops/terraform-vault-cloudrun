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

variable "init_image" {
  type    = string
  default = "joecorall/vault-init:0.4.0"
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
