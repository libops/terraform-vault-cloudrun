terraform {
  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = ">= 3.0.1"
    }
    google = {
      source  = "hashicorp/google"
      version = "7.11.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "7.11.0"
    }
  }
}

locals {
  image_name = format("%s-docker.pkg.dev/%s/%s/vault-server:latest", var.country, var.project, var.repository)
  kms_key    = "vault"
}

## Create the GSA the Vault CloudRun deployment will run as
resource "google_service_account" "gsa" {
  account_id = "vault-server"
}

## Create buckets to store the Vault backend (data) and root token (key)
resource "google_storage_bucket" "vault" {
  for_each                    = toset(["data", "key"])
  name                        = format("%s-%s", var.project, each.value)
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
  location      = var.country
  repository_id = var.repository
  format        = "DOCKER"
}

data "google_artifact_registry_repository" "my-repo" {
  location      = var.country
  repository_id = var.repository
}

# docker build vault server image
resource "docker_image" "vault" {
  name = local.image_name
  build {
    context = path.module
  }
  triggers = {
    dir_sha1 = sha1(join("", [for f in toset(["${path.module}/Dockerfile", "${path.module}/vault-server.hcl"]) : filesha1(f)]))
  }
}

# docker push to Artifact Registry
resource "docker_registry_image" "vault" {
  name       = local.image_name
  depends_on = [docker_image.vault, google_artifact_registry_repository.private]
  triggers = {
    rebuild = docker_image.vault.image_id
  }
}

## Create KMS keys
resource "google_kms_key_ring" "vault-server" {
  name     = "vault-server"
  location = "global"
}

resource "google_kms_crypto_key" "key" {
  name     = local.kms_key
  key_ring = google_kms_key_ring.vault-server.id

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_kms_crypto_key_iam_member" "vault" {
  for_each = toset([
    "roles/cloudkms.viewer",
    "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  ])

  crypto_key_id = google_kms_crypto_key.key.id
  role          = each.value
  member        = format("serviceAccount:%s", google_service_account.gsa.email)
}

module "vault" {
  source = "git::https://github.com/libops/terraform-cloudrun-v2?ref=0.3.4"

  name          = "vault-server"
  project       = var.project
  regions       = [var.region]
  skipNeg       = true
  gsa           = google_service_account.gsa.email
  min_instances = 0
  max_instances = 1
  containers = tolist([
    {
      name   = "vault",
      image  = format("%s@%s", local.image_name, docker_registry_image.vault.sha256_digest)
      port   = 8200
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
    }
  ])


  depends_on = [google_kms_crypto_key_iam_member.vault, docker_registry_image.vault]
}

resource "google_cloud_run_v2_job" "vault-init" {
  provider = google-beta

  name                  = "vault-init"
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
          value = google_kms_crypto_key.key.id
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
}

