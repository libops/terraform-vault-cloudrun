output "vault_url" {
  value       = module.vault.urls[var.region]
  description = "URL of the Vault Cloud Run service."
}

output "runtime_service_account_email" {
  value       = google_service_account.runtime.email
  description = "Service account used by the long-running Vault service."
}

output "initializer_service_account_email" {
  value       = google_service_account.initializer.email
  description = "Service account used by the one-shot Vault initializer job."
}

output "data_bucket_name" {
  value       = google_storage_bucket.vault["data"].name
  description = "Bucket containing the Vault GCS storage backend."
}

output "recovery_bucket_name" {
  value       = google_storage_bucket.vault["key"].name
  description = "Bucket containing encrypted Vault recovery material."
}

output "kms_key_id" {
  value       = local.kms_key_id
  description = "Full resource ID of the KMS key used by Vault and the initializer."
}

output "initializer_job_name" {
  value       = google_cloud_run_v2_job.vault-init.name
  description = "Name of the one-shot Vault initializer Cloud Run job."
}

output "initializer_execution_token" {
  value       = local.initializer_run_execution_token
  description = "Deterministic 31-character run-to-completion token derived from the initializer-relevant deployment contract."
}

# Compatibility aliases retained for existing callers. Prefer the descriptive
# underscore-separated outputs above in new configurations.
output "vault-url" {
  value       = module.vault.urls[var.region]
  description = "Deprecated compatibility alias for vault_url."
}

output "gsa" {
  value       = google_service_account.runtime.email
  description = "Deprecated compatibility alias for runtime_service_account_email."
}

output "key_bucket" {
  value       = google_storage_bucket.vault["key"].name
  description = "Deprecated compatibility alias for recovery_bucket_name."
}
