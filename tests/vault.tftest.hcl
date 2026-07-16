mock_provider "google" {
  override_during = plan

  mock_data "google_service_account" {
    defaults = {
      email = "vault-server@example-project.iam.gserviceaccount.com"
    }
  }
}

mock_provider "google-beta" {
  override_during = plan
}

override_resource {
  target          = google_service_account.runtime
  override_during = plan
  values = {
    email = "vault-server@example-project.iam.gserviceaccount.com"
  }
}

override_resource {
  target          = google_service_account.initializer
  override_during = plan
  values = {
    email = "vault-server-init@example-project.iam.gserviceaccount.com"
  }
}

override_resource {
  target          = google_kms_crypto_key.key[0]
  override_during = plan
  values = {
    id = "projects/example-project/locations/global/keyRings/vault-server/cryptoKeys/vault"
  }
}

override_module {
  target = module.vault
  outputs = {
    urls = {
      "us-central1" = "https://vault-server.example.test"
    }
  }
}

variables {
  project           = "example-project"
  region            = "us-central1"
  admin_emails      = ["vault-admin@example.org"]
  vault_image       = "us-docker.pkg.dev/example-project/public/vault@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  vault_proxy_image = "us-docker.pkg.dev/example-project/public/vault-proxy@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  vault_init_image  = "us-docker.pkg.dev/example-project/public/vault-init@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
}

run "splits_runtime_and_initializer_privileges" {
  command = plan

  assert {
    condition = (
      google_service_account.runtime.account_id != google_service_account.initializer.account_id &&
      length(google_storage_bucket_iam_member.member) == 1 &&
      alltrue([
        for binding in google_storage_bucket_iam_member.member :
        binding.bucket == google_storage_bucket.vault["data"].name &&
        binding.role == "roles/storage.objectAdmin" &&
        binding.member == "serviceAccount:${google_service_account.runtime.email}"
      ])
    )
    error_message = "The runtime identity must be distinct and limited to objectAdmin on the data bucket."
  }

  assert {
    condition = alltrue([
      for binding in google_storage_bucket_iam_member.initializer_recovery :
      binding.bucket == google_storage_bucket.vault["key"].name &&
      binding.member == "serviceAccount:${google_service_account.initializer.email}"
    ])
    error_message = "The initializer recovery bindings must target only the recovery bucket and initializer identity."
  }

  assert {
    condition = toset([
      for binding in google_storage_bucket_iam_member.initializer_recovery :
      binding.role
      ]) == toset([
      "roles/storage.objectCreator",
      "roles/storage.objectViewer",
    ])
    error_message = "The initializer must be able to create and view recovery objects without objectAdmin."
  }

  assert {
    condition = (
      toset([
        for binding in google_kms_crypto_key_iam_member.vault :
        binding.role
        ]) == toset([
        "roles/cloudkms.cryptoKeyEncrypterDecrypter",
        "roles/cloudkms.viewer",
      ]) &&
      alltrue([
        for binding in google_kms_crypto_key_iam_member.vault :
        binding.member == "serviceAccount:${google_service_account.runtime.email}"
      ]) &&
      google_kms_crypto_key_iam_member.initializer.role == "roles/cloudkms.cryptoKeyEncrypterDecrypter" &&
      google_kms_crypto_key_iam_member.initializer.member == "serviceAccount:${google_service_account.initializer.email}"
    )
    error_message = "Vault runtime must receive KMS get plus encrypt/decrypt, while the initializer receives only encrypt/decrypt."
  }
}

run "configures_vault_proxy_v2_boundary" {
  command = plan

  assert {
    condition = (
      length(local.vault_proxy_config.admin_emails) == 2 &&
      contains(local.vault_proxy_config.admin_emails, "vault-admin@example.org") &&
      contains(local.vault_proxy_config.admin_emails, local.initializer_service_account_email) &&
      !contains(local.vault_proxy_config.admin_emails, local.runtime_service_account_email)
    )
    error_message = "Only explicit administrators and the initializer may access protected proxy routes."
  }

  assert {
    condition = (
      contains(local.vault_proxy_config.public_routes, "/v1/auth/userpass/login/**") &&
      contains(local.vault_proxy_config.public_routes, "/v1/sys/health") &&
      alltrue([
        for route in local.vault_proxy_config.public_routes :
        !endswith(route, "/")
      ])
    )
    error_message = "Proxy routes must use canonical v2 patterns rather than legacy prefixes."
  }

  assert {
    condition = (
      local.vault_containers[0].name == "vault" &&
      local.vault_containers[0].image == var.vault_image &&
      local.vault_containers[0].startup_probe_config.port == 8200 &&
      local.vault_containers[0].startup_probe_config.path == "/v1/sys/health?uninitcode=200" &&
      local.vault_containers[0].startup_probe_config.failure_threshold *
      local.vault_containers[0].startup_probe_config.period_seconds == 240 &&
      local.vault_containers[1].name == "proxy" &&
      local.vault_containers[1].image == var.vault_proxy_image &&
      local.vault_containers[1].depends_on == ["vault"] &&
      local.vault_containers[1].startup_probe_config.path == "/healthz" &&
      local.vault_containers[1].startup_probe_config.port == 8080 &&
      local.vault_containers[1].liveness_probe == "/healthz" &&
      local.vault_vpc_direct_egress == "OFF" &&
      local.vault_max_instances == "1" &&
      local.initializer_execution_contract.service.cloud_run_module_revision == "4b1c2551369ec6f31372edb33721c80daeeeab62" &&
      var.deletion_protection
    )
    error_message = "Vault must become reachable on port 8200 before the pinned proxy starts, and Direct VPC must remain off."
  }
}

run "configures_bounded_one_shot_initializer" {
  command = plan

  assert {
    condition = (
      google_cloud_run_v2_job.vault-init.deletion_protection &&
      google_cloud_run_v2_job.vault-init.run_execution_token == local.initializer_run_execution_token &&
      google_cloud_run_v2_job.vault-init.start_execution_token == null &&
      length(local.initializer_run_execution_token) == 31 &&
      local.initializer_run_execution_token == substr(sha256(jsonencode(local.initializer_execution_contract)), 0, 31) &&
      google_cloud_run_v2_job.vault-init.template[0].task_count == 1 &&
      google_cloud_run_v2_job.vault-init.template[0].parallelism == 1 &&
      google_cloud_run_v2_job.vault-init.template[0].template[0].max_retries == 3 &&
      google_cloud_run_v2_job.vault-init.template[0].template[0].timeout == "600s" &&
      google_cloud_run_v2_job.vault-init.template[0].template[0].service_account == google_service_account.initializer.email
    )
    error_message = "The initializer must be deletion-protected, serialized, retry-bounded, and use its isolated identity."
  }

  assert {
    condition = (
      google_cloud_run_v2_job.vault-init.template[0].template[0].containers[0].image == var.vault_init_image &&
      local.initializer_environment.CHECK_INTERVAL == "0s"
    )
    error_message = "The initializer must use its pinned image and one-shot check interval."
  }
}

run "changed_initializer_image_changes_execution_token" {
  command = plan

  variables {
    vault_init_image = "us-docker.pkg.dev/example-project/public/vault-init@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
  }

  assert {
    condition     = output.initializer_execution_token != run.configures_bounded_one_shot_initializer.initializer_execution_token
    error_message = "Changing the initializer image digest must change the deterministic execution token."
  }
}

run "operator_nonce_changes_execution_token" {
  command = plan

  variables {
    initializer_execution_nonce = "verify-after-incident-1"
  }

  assert {
    condition     = output.initializer_execution_token != run.configures_bounded_one_shot_initializer.initializer_execution_token
    error_message = "Changing the operator nonce must change the deterministic execution token."
  }
}

run "preserves_compatibility_outputs" {
  command = plan

  assert {
    condition = (
      output.vault-url == output.vault_url &&
      output.gsa == output.runtime_service_account_email &&
      output.key_bucket == output.recovery_bucket_name
    )
    error_message = "Legacy output aliases must resolve to the new descriptive outputs."
  }
}

run "rejects_empty_admin_allowlist" {
  command = plan

  variables {
    admin_emails = []
  }

  expect_failures = [var.admin_emails]
}

run "rejects_legacy_proxy_route_prefixes" {
  command = plan

  variables {
    public_routes = ["/v1/auth/userpass/"]
  }

  expect_failures = [var.public_routes]
}

run "always_exposes_required_vault_health" {
  command = plan

  variables {
    public_routes = []
  }

  assert {
    condition = (
      length(local.vault_proxy_config.public_routes) == 1 &&
      contains(local.vault_proxy_config.public_routes, "/v1/sys/health")
    )
    error_message = "Vault health must remain public even when optional public routes are empty."
  }
}

run "rejects_nonfinal_recursive_wildcard" {
  command = plan

  variables {
    public_routes = ["/v1/**/config/**"]
  }

  expect_failures = [var.public_routes]
}

run "rejects_non_gar_vault_image" {
  command = plan

  variables {
    vault_image = "ghcr.io/libops/vault@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  }

  expect_failures = [var.vault_image]
}

run "rejects_whitespace_around_image" {
  command = plan

  variables {
    vault_image = " us-docker.pkg.dev/example-project/public/vault@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  }

  expect_failures = [var.vault_image]
}

run "rejects_unpinned_proxy_image" {
  command = plan

  variables {
    vault_proxy_image = "us-docker.pkg.dev/example-project/public/vault-proxy:2.0.0"
  }

  expect_failures = [var.vault_proxy_image]
}

run "rejects_unpinned_initializer_image" {
  command = plan

  variables {
    vault_init_image = "us-docker.pkg.dev/example-project/public/vault-init:1.0.2"
  }

  expect_failures = [var.vault_init_image]
}

run "rejects_shared_service_account_id" {
  command = plan

  variables {
    gsa_account_id             = "shared-vault"
    initializer_gsa_account_id = "shared-vault"
  }

  expect_failures = [google_service_account.initializer]
}

run "rejects_runtime_identity_as_explicit_admin" {
  command = plan

  variables {
    admin_emails = ["vault-server@example-project.iam.gserviceaccount.com"]
  }

  expect_failures = [google_service_account.initializer]
}

run "rejects_mixed_case_runtime_identity_as_explicit_admin" {
  command = plan

  variables {
    admin_emails = ["VAULT-SERVER@EXAMPLE-PROJECT.IAM.GSERVICEACCOUNT.COM"]
  }

  expect_failures = [google_service_account.initializer]
}

run "rejects_case_insensitive_duplicate_admins" {
  command = plan

  variables {
    admin_emails = [
      "vault-admin@example.org",
      "VAULT-ADMIN@EXAMPLE.ORG",
    ]
  }

  expect_failures = [var.admin_emails]
}

run "rejects_invalid_kms_key_ring_name" {
  command = plan

  variables {
    kms_key_ring_name = "invalid/ring"
  }

  expect_failures = [var.kms_key_ring_name]
}

run "rejects_oversized_kms_key_name" {
  command = plan

  variables {
    kms_key_name = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  }

  expect_failures = [var.kms_key_name]
}

run "derives_valid_runtime_identity_from_hyphenated_name" {
  command = plan

  variables {
    name = "a------------------------------b"
  }

  assert {
    condition     = google_service_account.runtime.account_id == "a----0"
    error_message = "The derived runtime service account ID must remain valid after trimming a long trailing hyphen run."
  }
}

run "rejects_whitespace_around_initializer_nonce" {
  command = plan

  variables {
    initializer_execution_nonce = " rerun"
  }

  expect_failures = [var.initializer_execution_nonce]
}

run "rejects_initializer_job_name_over_thirty_characters" {
  command = plan

  variables {
    init_job_name = "vault-initializer-job-name-is-too-long"
  }

  expect_failures = [var.init_job_name]
}
