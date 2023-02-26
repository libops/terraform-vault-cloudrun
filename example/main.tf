terraform {
  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "= 3.0.1"
    }
    google = {
      source  = "hashicorp/google"
      version = "= 4.54.0"
    }
    vault = {
      source  = "hashicorp/vault"
      version = "= 3.13.0"
    }
  }

# TODO: uncomment and configure so state is not saved only on your local machine
#  terraform {
#    backend "gcs" {
#      bucket  = "CHANGE-ME-TO-YOUR-TF-STATE-BUCKET"
#      prefix  = "CHANGE-TO-YOUR-PREFIX"
#    }
#  }
}

variable "project" {
  type        = string
  description = "The GCP project to create Vault inside of"
}

variable "region" {
  type        = string
  description = "The GCP region to create Vault in"
}

provider "google" {
  project = var.project
}

provider "docker" {
  registry_auth {
    address     = "us-docker.pkg.dev"
    config_file = pathexpand("~/.docker/config.json")
  }
}

module "vault" {
  source = "git::https://github.com/joecorall/serverless-vault-with-cloud-run"
  providers = {
    docker = docker
    google = google
  }
  project = var.project
  region  = var.region
}

# create GSA that can CRUD objects in a new bucket we create
resource "google_service_account" "ba" {
  account_id = "bucket-admin"
}

resource "google_storage_bucket" "bucket" {
  name          = format("%s-bucket", var.project)
  location      = "US"
  force_destroy = false

  uniform_bucket_level_access = true
}
resource "google_storage_bucket_iam_member" "member" {
  bucket = google_storage_bucket.bucket.name
  role   = "roles/storage.objectAdmin"
  member = format("serviceAccount:%s", google_service_account.ba.email)
}

# needed to allow Vault to issue a key for the GSA
resource "google_service_account_iam_member" "project" {
  for_each = toset([
    "roles/iam.serviceAccountAdmin",
    "roles/iam.serviceAccountKeyAdmin"
  ])

  service_account_id = google_service_account.ba.name
  role               = each.value
  member             = format("serviceAccount:%s", module.vault.gsa)
}

# Add the GCP secret to Vault
provider "vault" {
  address = module.vault.vault-url
}

resource "vault_gcp_secret_backend" "gcp" {
  default_lease_ttl_seconds = 300 # 5m
  max_lease_ttl_seconds     = 86400*30 # 30d
}

resource "vault_gcp_secret_static_account" "bucket-admin" {
  backend        = vault_gcp_secret_backend.gcp.path
  static_account = "bucket-admin"
  secret_type    = "service_account_key"
  token_scopes   = ["https://www.googleapis.com/auth/cloud-platform"]

  service_account_email = google_service_account.ba.email
}
