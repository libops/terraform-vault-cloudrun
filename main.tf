terraform {
  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = ">= 3.0.1"
    }
    google = {
      source  = "hashicorp/google"
      version = "6.42.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "6.42.0"
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

## Finally, create the Vault server
resource "google_cloud_run_v2_service" "vault" {
  name     = "vault-server"
  location = var.region
  ingress  = "INGRESS_TRAFFIC_ALL"

  template {
    scaling {
      min_instance_count = 0
      max_instance_count = 1
    }
    timeout                          = "300s"
    max_instance_request_concurrency = 50
    execution_environment            = "EXECUTION_ENVIRONMENT_GEN2"
    service_account                  = google_service_account.gsa.email
    containers {
      name  = "vault-server"
      image   = format("%s@%s", local.image_name, docker_registry_image.vault.sha256_digest)
      ports {
        name           = "http1"
        container_port = 8200
      }
      env {
        name  = "GOOGLE_PROJECT"
        value = var.project
      }
      env {
        name  = "GOOGLE_STORAGE_BUCKET"
        value = google_storage_bucket.vault["data"].name
      }

      resources {
        limits = {
          cpu    = "2"
          memory = "2Gi"
        }
      }
    }
  }

  depends_on = [google_kms_crypto_key_iam_member.vault, docker_registry_image.vault]
}

resource "google_cloud_run_v2_service_iam_member" "member" {
  project  = google_cloud_run_v2_service.vault.project
  location = google_cloud_run_v2_service.vault.location
  name     = google_cloud_run_v2_service.vault.name
  role     = "roles/run.invoker"
  member   = "allUsers"
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
          value = google_cloud_run_v2_service.vault.uri
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

