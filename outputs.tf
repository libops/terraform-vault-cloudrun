output "vault-url" {
  value       = google_cloud_run_v2_service.vault.uri
  description = "The URL to the Vault instance."
}

output "gsa" {
  value       = google_service_account.gsa.email
  description = "The GSA the Vault instance runs as."
}
