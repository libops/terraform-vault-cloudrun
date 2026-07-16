terraform {
  required_version = ">= 1.7.0, < 2.0.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 7.22.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = ">= 7.22.0"
    }
  }
}

data "google_client_openid_userinfo" "current" {}

locals {
  service_name = trimspace(var.name)
  account_id   = trimspace(var.gsa_account_id) != "" ? trimspace(var.gsa_account_id) : substr(local.service_name, 0, 30)
  gsa          = "${local.account_id}@${var.project}.iam.gserviceaccount.com"
  data_bucket_name = trimspace(var.data_bucket_name) != "" ? trimspace(var.data_bucket_name) : lower(
    replace(replace(replace("${var.project}-${local.service_name}-data", "_", "-"), ".", "-"), " ", "-")
  )
  key_bucket_name = trimspace(var.key_bucket_name) != "" ? trimspace(var.key_bucket_name) : lower(
    replace(replace(replace("${var.project}-${local.service_name}-key", "_", "-"), ".", "-"), " ", "-")
  )

  # see https://github.com/libops/vault-proxy/blob/main/config.example.yaml
  vault_proxy_config = {
    vault_addr = "http://127.0.0.1:8200"
    port       = 8080
    admin_emails = concat(
      var.admin_emails,
      [
        data.google_client_openid_userinfo.current.email,
        local.gsa,
      ]
    )
    public_routes = concat(
      var.public_routes,
      ["/v1/sys/health"] # Essential for health checks
    )
  }
  vault_proxy_yaml = yamlencode(local.vault_proxy_config)
}

## Create the GSA the Vault CloudRun deployment will run as
resource "google_service_account" "gsa" {
  project    = var.project
  account_id = local.account_id
}

## Create buckets to store the Vault backend (data) and root token (key)
resource "google_storage_bucket" "vault" {
  for_each = {
    data = local.data_bucket_name
    key  = local.key_bucket_name
  }
  project                     = var.project
  name                        = each.value
  location                    = var.country
  force_destroy               = false
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
}

resource "google_storage_bucket_iam_member" "member" {
  for_each = toset([
    google_storage_bucket.vault["data"].name,
    google_storage_bucket.vault["key"].name
  ])
  bucket = each.value
  role   = "roles/storage.objectAdmin"
  member = format("serviceAccount:%s", google_service_account.gsa.email)
}

## Create KMS keys
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

locals {
  kms_key_id = var.create_kms ? google_kms_crypto_key.key[0].id : format(
    "projects/%s/locations/global/keyRings/%s/cryptoKeys/%s",
    var.project,
    var.kms_key_ring_name,
    var.kms_key_name,
  )
}

resource "google_kms_crypto_key_iam_member" "vault" {
  for_each = toset([
    "roles/cloudkms.viewer",
    "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  ])

  crypto_key_id = local.kms_key_id
  role          = each.value
  member        = format("serviceAccount:%s", google_service_account.gsa.email)
}

module "vault" {
  source = "https://github.com/libops/terraform-cloudrun-v2/archive/refs/tags/0.5.2.zip//terraform-cloudrun-v2-0.5.2"

  name          = local.service_name
  project       = var.project
  regions       = [var.region]
  skipNeg       = true
  gsa           = google_service_account.gsa.email
  min_instances = 0
  max_instances = 1
  containers = tolist([
    {
      name   = "proxy",
      image  = "libops/vault-proxy:1.0.1@sha256:515910b8208d82376b8973c6ae26d14ce6f56f8935547f69057dd82d2fa50c2f"
      port   = 8080
      memory = "512Mi"
      cpu    = "500m"
    },
    {
      name   = "vault",
      image  = var.vault_image
      memory = "2Gi"
      cpu    = "2000m"
    }
  ])

  addl_env_vars = tolist([
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
    }
  ])

  depends_on = [google_kms_crypto_key_iam_member.vault]
}

resource "google_cloud_run_v2_job" "vault-init" {
  provider = google-beta

  name                  = var.init_job_name
  project               = var.project
  location              = var.region
  deletion_protection   = false
  start_execution_token = "start-once-created"
  template {
    template {
      service_account = google_service_account.gsa.email
      containers {
        name  = "vault-init"
        image = var.init_image

        env {
          name  = "GOOGLE_PROJECT"
          value = var.project
        }
        env {
          name  = "GCS_BUCKET_NAME"
          value = google_storage_bucket.vault["key"].name
        }
        env {
          name  = "CHECK_INTERVAL"
          value = "-1"
        }
        env {
          name  = "KMS_KEY_ID"
          value = local.kms_key_id
        }
        env {
          name  = "VAULT_ADDR"
          value = module.vault.urls[var.region]
        }
        env {
          name  = "VAULT_SECRET_SHARES"
          value = 0
        }
        env {
          name  = "VAULT_SECRET_THRESHOLD"
          value = 0
        }
      }
    }
  }
  depends_on = [module.vault]
}
