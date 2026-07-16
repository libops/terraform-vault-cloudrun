terraform {
  required_version = ">= 1.7.0, < 2.0.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.22"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 7.22"
    }
  }
}

locals {
  # Keep this contract value in sync with the exact module source below so a
  # shared service-template implementation change re-runs verification.
  cloud_run_module_revision = "4b1c2551369ec6f31372edb33721c80daeeeab62"
  service_name              = trimspace(var.name)
  runtime_account_id_candidate = replace(
    substr(local.service_name, 0, 30),
    "/-+$/",
    "",
  )
  runtime_account_id = (
    trimspace(var.gsa_account_id) != ""
    ? trimspace(var.gsa_account_id)
    : (
      length(local.runtime_account_id_candidate) >= 6
      ? local.runtime_account_id_candidate
      : "${substr(local.service_name, 0, 5)}0"
    )
  )
  initializer_account_id = (
    trimspace(var.initializer_gsa_account_id) != ""
    ? trimspace(var.initializer_gsa_account_id)
    : "${substr(local.service_name, 0, 25)}-init"
  )
  runtime_service_account_email     = google_service_account.runtime.email
  initializer_service_account_email = google_service_account.initializer.email
  data_bucket_name = trimspace(var.data_bucket_name) != "" ? trimspace(var.data_bucket_name) : lower(
    replace(replace(replace("${var.project}-${local.service_name}-data", "_", "-"), ".", "-"), " ", "-")
  )
  recovery_bucket_name = trimspace(var.key_bucket_name) != "" ? trimspace(var.key_bucket_name) : lower(
    replace(replace(replace("${var.project}-${local.service_name}-key", "_", "-"), ".", "-"), " ", "-")
  )

  kms_key_id = var.create_kms ? google_kms_crypto_key.key[0].id : format(
    "projects/%s/locations/global/keyRings/%s/cryptoKeys/%s",
    var.project,
    var.kms_key_ring_name,
    var.kms_key_name,
  )

  # Vault Proxy v2 accepts only canonical explicit route patterns. The
  # initializer identity is the only workload identity that bypasses the
  # public-route allowlist; the Vault runtime identity is intentionally absent.
  vault_proxy_config = {
    vault_addr = "http://127.0.0.1:8200"
    port       = 8080
    admin_emails = distinct([
      for email in concat(var.admin_emails, [local.initializer_service_account_email]) :
      lower(email)
    ])
    public_routes = distinct(concat(var.public_routes, ["/v1/sys/health"]))
  }
  vault_proxy_yaml = yamlencode(local.vault_proxy_config)

  proxy_startup_probe = {
    path                  = "/healthz"
    port                  = 8080
    initial_delay_seconds = 0
    timeout_seconds       = 2
    period_seconds        = 5
    failure_threshold     = 24
  }
  vault_startup_probe = {
    path                  = "/v1/sys/health?uninitcode=200"
    port                  = 8200
    initial_delay_seconds = 0
    timeout_seconds       = 2
    period_seconds        = 5
    failure_threshold     = 48
  }
  vault_containers = [
    {
      name                 = "vault"
      image                = var.vault_image
      depends_on           = []
      port                 = 0
      memory               = "2Gi"
      cpu                  = "2000m"
      liveness_probe       = ""
      startup_probe_config = local.vault_startup_probe
    },
    {
      name                 = "proxy"
      image                = var.vault_proxy_image
      depends_on           = ["vault"]
      port                 = 8080
      memory               = "512Mi"
      cpu                  = "500m"
      liveness_probe       = "/healthz"
      startup_probe_config = local.proxy_startup_probe
    },
  ]
  vault_environment = tolist([
    {
      name  = "GOOGLE_PROJECT"
      value = var.project
    },
    {
      name  = "KMS_KEY_RING"
      value = var.kms_key_ring_name
    },
    {
      name  = "KMS_CRYPTO_KEY"
      value = var.kms_key_name
    },
    {
      name  = "GOOGLE_STORAGE_BUCKET"
      value = google_storage_bucket.vault["data"].name
    },
    {
      name  = "VAULT_PROXY_YAML"
      value = local.vault_proxy_yaml
    },
  ])
  initializer_environment = {
    CHECK_INTERVAL         = "0s"
    GCS_BUCKET_NAME        = google_storage_bucket.vault["key"].name
    GOOGLE_PROJECT         = var.project
    KMS_KEY_ID             = local.kms_key_id
    VAULT_ADDR             = module.vault.urls[var.region]
    VAULT_SECRET_SHARES    = "0"
    VAULT_SECRET_THRESHOLD = "0"
  }
  initializer_job_settings = {
    task_count      = 1
    parallelism     = 1
    max_retries     = 3
    timeout         = "600s"
    execution_nonce = var.initializer_execution_nonce
  }
  initializer_execution_contract = {
    images = {
      vault       = var.vault_image
      vault_init  = var.vault_init_image
      vault_proxy = var.vault_proxy_image
    }
    service = {
      name                              = local.service_name
      project                           = var.project
      region                            = var.region
      runtime_service_account_email     = local.runtime_service_account_email
      initializer_service_account_email = local.initializer_service_account_email
      data_bucket_name                  = local.data_bucket_name
      recovery_bucket_name              = local.recovery_bucket_name
      kms_key_id = format(
        "projects/%s/locations/global/keyRings/%s/cryptoKeys/%s",
        var.project,
        var.kms_key_ring_name,
        var.kms_key_name,
      )
      max_instances             = "1"
      deletion_protection       = var.deletion_protection
      direct_vpc_egress         = "OFF"
      containers                = local.vault_containers
      cloud_run_module_revision = local.cloud_run_module_revision
    }
    proxy = local.vault_proxy_config
    initializer = {
      job_name                 = var.init_job_name
      service_account_email    = local.initializer_service_account_email
      environment              = local.initializer_environment
      task_count               = local.initializer_job_settings.task_count
      parallelism              = local.initializer_job_settings.parallelism
      max_retries              = local.initializer_job_settings.max_retries
      timeout                  = local.initializer_job_settings.timeout
      operator_execution_nonce = local.initializer_job_settings.execution_nonce
    }
  }
  initializer_run_execution_token = substr(
    sha256(jsonencode(local.initializer_execution_contract)),
    0,
    31,
  )

  # This module deliberately does not attach Vault to a VPC. Callers that need
  # private egress should compose that concern outside this security boundary.
  vault_vpc_direct_egress = "OFF"
  vault_min_instances     = "0"
  vault_max_instances     = "1"
}

# Preserve the existing runtime identity and its state address during the v1
# split. The initializer receives a new, separately privileged identity.
moved {
  from = google_service_account.gsa
  to   = google_service_account.runtime
}

resource "google_service_account" "runtime" {
  project      = var.project
  account_id   = local.runtime_account_id
  display_name = "Vault runtime"
}

resource "google_service_account" "initializer" {
  project      = var.project
  account_id   = local.initializer_account_id
  display_name = "Vault initializer"

  lifecycle {
    precondition {
      condition     = local.runtime_account_id != local.initializer_account_id
      error_message = "The Vault runtime and initializer must use distinct service account IDs."
    }
    precondition {
      condition = !contains(
        [for email in var.admin_emails : lower(email)],
        lower(local.runtime_service_account_email),
      )
      error_message = "The Vault runtime service account must not be listed as a proxy administrator."
    }
  }
}

resource "google_storage_bucket" "vault" {
  for_each = {
    data = local.data_bucket_name
    key  = local.recovery_bucket_name
  }

  project                     = var.project
  name                        = each.value
  location                    = var.country
  force_destroy               = false
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
}

# The long-running Vault server can modify only its data backend.
resource "google_storage_bucket_iam_member" "member" {
  for_each = toset([google_storage_bucket.vault["data"].name])

  bucket = each.value
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.runtime.email}"
}

# The one-shot initializer can create and read recovery objects but cannot
# delete or overwrite them.
resource "google_storage_bucket_iam_member" "initializer_recovery" {
  for_each = toset([
    "roles/storage.objectCreator",
    "roles/storage.objectViewer",
  ])

  bucket = google_storage_bucket.vault["key"].name
  role   = each.value
  member = "serviceAccount:${google_service_account.initializer.email}"
}

resource "google_kms_key_ring" "vault-server" {
  count    = var.create_kms ? 1 : 0
  project  = var.project
  name     = var.kms_key_ring_name
  location = "global"
}

resource "google_kms_crypto_key" "key" {
  count    = var.create_kms ? 1 : 0
  name     = var.kms_key_name
  key_ring = google_kms_key_ring.vault-server[0].id

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_kms_crypto_key_iam_member" "vault" {
  for_each = toset([
    "roles/cloudkms.cryptoKeyEncrypterDecrypter",
    "roles/cloudkms.viewer",
  ])

  crypto_key_id = local.kms_key_id
  role          = each.value
  member        = "serviceAccount:${google_service_account.runtime.email}"
}

resource "google_kms_crypto_key_iam_member" "initializer" {
  crypto_key_id = local.kms_key_id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${google_service_account.initializer.email}"
}

module "vault" {
  source = "https://github.com/libops/terraform-cloudrun-v2/archive/4b1c2551369ec6f31372edb33721c80daeeeab62.zip//terraform-cloudrun-v2-4b1c2551369ec6f31372edb33721c80daeeeab62"

  name                = local.service_name
  project             = var.project
  regions             = [var.region]
  skipNeg             = true
  gsa                 = google_service_account.runtime.email
  min_instances       = local.vault_min_instances
  max_instances       = local.vault_max_instances
  deletion_protection = var.deletion_protection
  invokers            = ["allUsers"]
  containers          = local.vault_containers
  addl_env_vars       = local.vault_environment
  vpc_direct_egress   = local.vault_vpc_direct_egress

  depends_on = [
    google_kms_crypto_key_iam_member.vault,
    google_storage_bucket_iam_member.member,
  ]
}

resource "google_cloud_run_v2_job" "vault-init" {
  provider = google-beta

  name                = var.init_job_name
  project             = var.project
  location            = var.region
  deletion_protection = var.deletion_protection
  run_execution_token = local.initializer_run_execution_token

  # run_execution_token blocks until the execution succeeds. Four possible
  # ten-minute attempts plus scheduling overhead must fit inside provider CRUD
  # timeouts so a failed initializer makes terraform apply fail.
  timeouts {
    create = "60m"
    update = "60m"
  }

  template {
    task_count  = local.initializer_job_settings.task_count
    parallelism = local.initializer_job_settings.parallelism

    template {
      service_account = google_service_account.initializer.email
      max_retries     = local.initializer_job_settings.max_retries
      timeout         = local.initializer_job_settings.timeout

      containers {
        name  = "vault-init"
        image = var.vault_init_image

        dynamic "env" {
          for_each = local.initializer_environment
          content {
            name  = env.key
            value = env.value
          }
        }
      }
    }
  }

  depends_on = [
    module.vault,
    google_kms_crypto_key_iam_member.initializer,
    google_storage_bucket_iam_member.initializer_recovery,
  ]
}
