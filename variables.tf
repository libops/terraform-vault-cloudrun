variable "project" {
  type        = string
  description = "GCP project in which to deploy Vault."

  validation {
    condition     = trimspace(var.project) != "" && trimspace(var.project) == var.project
    error_message = "project must not be empty or contain leading or trailing whitespace."
  }
}

variable "region" {
  type        = string
  description = "GCP region in which to deploy the Cloud Run service and initializer job."
  default     = "us-east5"

  validation {
    condition     = can(regex("^[a-z]+(?:-[a-z0-9]+)+[0-9]$", var.region))
    error_message = "region must be a valid GCP region name."
  }
}

variable "name" {
  type        = string
  description = "Cloud Run service name for the Vault server."
  default     = "vault-server"

  validation {
    condition = (
      length(var.name) >= 6 &&
      length(var.name) <= 49 &&
      can(regex("^[a-z]([a-z0-9-]*[a-z0-9])?$", var.name))
    )
    error_message = "name must be a 6-49 character lowercase Cloud Run service name."
  }
}

variable "gsa_account_id" {
  type        = string
  description = "Service account ID for the Vault runtime. Defaults to a truncated form of name."
  default     = ""

  validation {
    condition = (
      trimspace(var.gsa_account_id) == "" ||
      can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", trimspace(var.gsa_account_id)))
    )
    error_message = "gsa_account_id must be empty or a valid 6-30 character GCP service account ID."
  }
}

variable "initializer_gsa_account_id" {
  type        = string
  description = "Service account ID for the one-shot Vault initializer. Defaults to the service name plus -init."
  default     = ""

  validation {
    condition = (
      trimspace(var.initializer_gsa_account_id) == "" ||
      can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", trimspace(var.initializer_gsa_account_id)))
    )
    error_message = "initializer_gsa_account_id must be empty or a valid 6-30 character GCP service account ID."
  }
}

variable "proxy_gsa_account_id" {
  type        = string
  description = "Service account ID for the public Vault proxy. Defaults to the service name plus -proxy."
  default     = ""

  validation {
    condition = (
      trimspace(var.proxy_gsa_account_id) == "" ||
      can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", trimspace(var.proxy_gsa_account_id)))
    )
    error_message = "proxy_gsa_account_id must be empty or a valid 6-30 character GCP service account ID."
  }
}

variable "init_job_name" {
  type        = string
  description = "Cloud Run job name used to initialize Vault."
  default     = "vault-init"

  validation {
    condition = (
      length(var.init_job_name) >= 1 &&
      length(var.init_job_name) <= 30 &&
      can(regex("^[a-z]([a-z0-9-]*[a-z0-9])?$", var.init_job_name))
    )
    error_message = "init_job_name must be a valid 1-30 character lowercase Cloud Run job name so its execution suffix remains within Cloud Run's limit."
  }
}

variable "initializer_execution_nonce" {
  type        = string
  description = "Optional operator-controlled nonce included in the initializer execution-contract hash. Change it to deliberately request another idempotent verification."
  default     = ""

  validation {
    condition = (
      length(var.initializer_execution_nonce) <= 128 &&
      trimspace(var.initializer_execution_nonce) == var.initializer_execution_nonce
    )
    error_message = "initializer_execution_nonce must be at most 128 characters with no leading or trailing whitespace."
  }
}

variable "recovery_pgp_keys" {
  type        = list(string)
  description = "Optional set of five distinct base64-encoded binary PGP public keys for independent recovery-share custodians. When omitted, Vault returns the shares to the initializer for KMS encryption and create-only GCS storage."
  default     = []

  validation {
    condition = (
      length(var.recovery_pgp_keys) == 0 || (
        length(var.recovery_pgp_keys) == 5 &&
        length(distinct(var.recovery_pgp_keys)) == 5 &&
        alltrue([
          for key in var.recovery_pgp_keys :
          length(key) >= 44 &&
          length(key) <= 87384 &&
          length(key) % 4 == 0 &&
          can(regex("^[A-Za-z0-9+/]+={0,2}$", key))
      ]))
    )
    error_message = "recovery_pgp_keys must be empty or contain exactly five distinct strict-base64 PGP public keys; keep private custodian keys outside Terraform."
  }
}

variable "vault_image" {
  type        = string
  description = "Tagged GAR image reference for the Vault server container."

  validation {
    condition = (
      trimspace(var.vault_image) == var.vault_image &&
      can(regex(
        "^[a-z0-9-]+-docker\\.pkg\\.dev/[^/@[:space:]]+/[^/@[:space:]]+/[^/@:[:space:]]+:[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$",
        var.vault_image,
      ))
    )
    error_message = "vault_image must be a tagged GAR image reference."
  }
}

variable "vault_proxy_image" {
  type        = string
  description = "Tagged GAR image reference for the Vault Proxy v2 container."

  validation {
    condition = (
      trimspace(var.vault_proxy_image) == var.vault_proxy_image &&
      can(regex(
        "^[a-z0-9-]+-docker\\.pkg\\.dev/[^/@[:space:]]+/[^/@[:space:]]+/[^/@:[:space:]]+:[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$",
        var.vault_proxy_image,
      ))
    )
    error_message = "vault_proxy_image must be a tagged GAR image reference."
  }
}

variable "vault_init_image" {
  type        = string
  description = "Tagged GAR image reference for the Vault initializer container."

  validation {
    condition = (
      trimspace(var.vault_init_image) == var.vault_init_image &&
      can(regex(
        "^[a-z0-9-]+-docker\\.pkg\\.dev/[^/@[:space:]]+/[^/@[:space:]]+/[^/@:[:space:]]+:[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$",
        var.vault_init_image,
      ))
    )
    error_message = "vault_init_image must be a tagged GAR image reference."
  }
}

variable "country" {
  type        = string
  description = "GCS location for the Vault data and recovery buckets."
  default     = "us"

  validation {
    condition     = trimspace(var.country) != "" && trimspace(var.country) == var.country
    error_message = "country must not be empty or contain leading or trailing whitespace."
  }
}

variable "data_bucket_name" {
  type        = string
  description = "Bucket name for Vault data storage. Defaults to a name derived from project and service name."
  default     = ""
}

variable "key_bucket_name" {
  type        = string
  description = "Bucket name for encrypted Vault recovery material. Defaults to a name derived from project and service name."
  default     = ""
}

variable "kms_key_ring_name" {
  type        = string
  description = "KMS key ring name used for auto-unseal."
  default     = "vault-server"

  validation {
    condition     = can(regex("^[A-Za-z0-9_-]{1,63}$", var.kms_key_ring_name))
    error_message = "kms_key_ring_name must contain 1-63 ASCII letters, digits, underscores, or hyphens."
  }
}

variable "kms_key_name" {
  type        = string
  description = "KMS crypto key name used for auto-unseal and recovery-material encryption."
  default     = "vault"

  validation {
    condition     = can(regex("^[A-Za-z0-9_-]{1,63}$", var.kms_key_name))
    error_message = "kms_key_name must contain 1-63 ASCII letters, digits, underscores, or hyphens."
  }
}

variable "create_kms" {
  type        = bool
  description = "Whether to create the KMS key ring and crypto key."
  default     = true
}

variable "deletion_protection" {
  type        = bool
  description = "Protect both the Vault Cloud Run service and initializer job from accidental deletion."
  default     = true
}

variable "single_instance_preview_acknowledged" {
  type        = bool
  description = "Required explicit acknowledgement that this module is a single-serving-instance preview, not an HA Vault topology. Set true only for an approved limited deployment; this is not risk acceptance or production evidence."
}

variable "admin_emails" {
  type        = list(string)
  description = "Explicit human or automation emails allowed to access protected Vault routes. The initializer service account is added automatically."

  validation {
    condition = (
      length(var.admin_emails) > 0 &&
      length(distinct([for email in var.admin_emails : lower(email)])) == length(var.admin_emails) &&
      alltrue([
        for email in var.admin_emails :
        trimspace(email) == email &&
        can(regex("^[^@[:space:]]+@[^@[:space:]]+$", email))
      ])
    )
    error_message = "admin_emails must contain at least one case-insensitively unique, valid email address."
  }
}

variable "public_routes" {
  type        = list(string)
  description = "Optional canonical Vault Proxy v2 path patterns accessible without X-Admin-Token. /v1/sys/health is always added."
  default = [
    "/.well-known/**",
    "/v1/identity/oidc/provider/*/.well-known/**",
    "/v1/identity/oidc/provider/*/authorize",
    "/v1/identity/oidc/provider/*/token",
    "/v1/identity/oidc/provider/*/userinfo",
    "/ui/vault/identity/oidc/provider/*/authorize",
    "/v1/auth/oidc/oidc/auth_url",
    "/v1/auth/oidc/oidc/callback",
    "/ui/vault/auth/*/oidc/callback",
    "/v1/auth/userpass/login/**",
  ]

  validation {
    condition = (
      length(distinct(var.public_routes)) == length(var.public_routes) &&
      alltrue([
        for route in var.public_routes : (
          trimspace(route) == route &&
          startswith(route, "/") &&
          !endswith(route, "/") &&
          !strcontains(route, "//") &&
          route != "/**" &&
          !strcontains(route, "?") &&
          !strcontains(route, "[") &&
          !strcontains(route, "]") &&
          !strcontains(route, "\\") &&
          !strcontains(route, "/./") &&
          !strcontains(route, "/../") &&
          !endswith(route, "/.") &&
          !endswith(route, "/..") &&
          length([
            for segment in split("/", trimprefix(route, "/")) :
            segment if segment == "**"
          ]) <= 1 &&
          alltrue([
            for segment in split("/", trimprefix(route, "/")) :
            segment != "" &&
            (
              segment == "*" ||
              segment == "**" ||
              !strcontains(segment, "*")
            )
          ]) &&
          (
            !strcontains(route, "**") ||
            endswith(route, "/**")
          )
        )
      ])
    )
    error_message = "public_routes must contain unique canonical Vault Proxy v2 absolute path patterns; legacy trailing-slash prefixes are invalid."
  }
}
