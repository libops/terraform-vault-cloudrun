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

# e.g. https://github.com/libops/vault-proxy/blob/main/config.example.yaml
variable "vault_proxy_yaml" {
  type      = string
  sensitive = true
  default   = <<EOT
vault_addr: http://127.0.0.1:8200
port: 8080
admin_emails:
  - joe@libops.io
  - github@__GCLOUD_PROJECT__.iam.gserviceaccount.com
  - vault-server@__GCLOUD_PROJECT__.iam.gserviceaccount.com
public_routes:
  - /.well-known/
  - /v1/identity/oidc/
  - /v1/auth/oidc/
  - /v1/auth/userpass/
  # this should always be set, as the docker healthcheck relies on it
  # the healthcheck checks both the proxy is working and vault is unsealed
  - /v1/sys/health
EOT
}
