output "vault-url" {
  value       = google_cloud_run_v2_service.vault.uri
  description = "The URL to the Vault instance."
}

output "gsa" {
  value       = google_service_account.gsa.email
  description = "The GSA the Vault instance runs as."
}

output "key_bucket" {
  value = google_storage_bucket.vault["key"].name
}


output "repo" {
  value = google_artifact_registry_repository.private
}
