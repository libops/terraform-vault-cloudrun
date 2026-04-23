terraform {
  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = ">= 3.0.1"
    }
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
  image_name   = format("%s-docker.pkg.dev/%s/%s/%s:latest", var.country, var.project, var.repository, var.image_name)
  vault_proxy  = "libops/vault-proxy:1.0.0"
  account_id   = trimspace(var.gsa_account_id) != "" ? trimspace(var.gsa_account_id) : substr(local.service_name, 0, 30)
  gsa          = "${local.account_id}@${var.project}.iam.gserviceaccount.com"
  vault_image_context_sha = sha1(join("", [
    filesha1("${path.module}/Dockerfile"),
    filesha1("${path.module}/vault-server.hcl.tmpl"),
  ]))
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

## Create AR repo and push the Vault image to there, to be deployed to CloudRun
resource "google_artifact_registry_repository" "private" {
  count         = var.create_repository ? 1 : 0
  project       = var.project
  location      = var.country
  repository_id = var.repository
  format        = "DOCKER"
}

# docker build vault server image
resource "docker_image" "vault" {
  name = local.image_name

  build {
    context    = path.module
    dockerfile = "Dockerfile"
    build_args = {
      KMS_KEY_RING   = var.kms_key_ring_name
      KMS_CRYPTO_KEY = var.kms_key_name
    }
  }

  keep_locally = false

  triggers = {
    dir_sha = local.vault_image_context_sha
    ring    = var.kms_key_ring_name
    key     = var.kms_key_name
  }
}

# docker push to Artifact Registry
resource "docker_registry_image" "vault" {
  name          = docker_image.vault.name
  keep_remotely = true
  depends_on    = [docker_image.vault, google_artifact_registry_repository.private]

  triggers = {
    dir_sha = local.vault_image_context_sha
    ring    = var.kms_key_ring_name
    key     = var.kms_key_name
  }
}

data "docker_registry_image" "vault-proxy" {
  name = local.vault_proxy
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
  source = "git::https://github.com/libops/terraform-cloudrun-v2?ref=0.5.2"

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
      image  = format("%s@%s", local.vault_proxy, data.docker_registry_image.vault-proxy.sha256_digest)
      port   = 8080
      memory = "512Mi"
      cpu    = "500m"
    },
    {
      name   = "vault",
      image  = format("%s@%s", local.image_name, docker_registry_image.vault.sha256_digest)
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
      name  = "GOOGLE_STORAGE_BUCKET"
      value = google_storage_bucket.vault["data"].name
    },
    {
      name  = "VAULT_PROXY_YAML"
      value = local.vault_proxy_yaml
    }
  ])

  depends_on = [google_kms_crypto_key_iam_member.vault, docker_registry_image.vault]
}

resource "google_cloud_run_v2_job" "vault-init" {
  provider = google-beta

  name                  = var.init_job_name
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
