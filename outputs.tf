output "vault-url" {
  value       = module.vault.urls[var.region]
  description = "The URL to the Vault instance."
}

output "gsa" {
  value       = google_service_account.gsa.email
  description = "The GSA the Vault instance runs as."
}

output "key_bucket" {
  value = local.key_bucket_name
}


output "repo" {
  value = var.repository
}
