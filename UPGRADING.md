# Upgrading to v1

Version 1 intentionally changes the module's security boundary. Back up and
verify access to the current Vault recovery material before applying an
upgrade.

## Required configuration changes

1. Supply all three GAR images by digest:

   ```hcl
   vault_image       = "us-docker.pkg.dev/PROJECT/REPOSITORY/vault@sha256:DIGEST"
   vault_proxy_image = "us-docker.pkg.dev/PROJECT/REPOSITORY/vault-proxy@sha256:DIGEST"
   vault_init_image  = "us-docker.pkg.dev/PROJECT/REPOSITORY/vault-init@sha256:DIGEST"
   ```

   The old mutable `init_image` default and hard-coded proxy image are removed.

2. Set `admin_emails` explicitly. Terraform no longer adds the credentials
   running `terraform apply`, and the Vault runtime identity is no longer a
   proxy administrator. The new initializer identity is added automatically.

3. Replace legacy trailing-slash `public_routes` with Vault Proxy v2 canonical
   patterns. For example, replace `/v1/auth/userpass/` with the narrower
   `/v1/auth/userpass/login/**`.

4. Ensure the selected Vault Init image is compatible with Vault Proxy v2 and
   requests a Google metadata access token containing the `userinfo.email`
   scope.

5. Keep `init_job_name` at 30 characters or fewer. This reserves room for the
   31-character deterministic execution suffix. A longer custom pre-v1 job
   name must be replaced with a shorter one.

## State and IAM changes

The module includes this state migration:

```hcl
moved {
  from = google_service_account.gsa
  to   = google_service_account.runtime
}
```

The existing service account therefore remains the Vault runtime identity. A
new initializer service account is created. If `gsa_account_id` was set
previously, keep the same value so Terraform preserves the existing identity.
Use `initializer_gsa_account_id` only when the derived initializer ID conflicts
with another account.

The upgrade removes runtime access to the recovery bucket and grants the new
initializer only Object Creator and Object Viewer there. The runtime keeps
Object Admin on the data bucket. The runtime receives KMS Viewer plus
Encrypt/Decrypt for Vault auto-unseal; the initializer receives only KMS
Encrypt/Decrypt. Review the plan for those exact removals and additions before
approval.

The old `gsa`, `key_bucket`, and `vault-url` outputs remain as deprecated
aliases. New callers should use `runtime_service_account_email`,
`recovery_bucket_name`, and `vault_url`.

## Cloud Run changes

- The service is capped at one instance.
- Service and initializer deletion protection default to enabled.
- Vault starts first and must pass a port-specific health probe on `8200`.
  Cloud Run then starts the dependent proxy, which must pass `/healthz` on
  `8080`.
- The initializer runs one task at parallelism one, retries at most three
  times, and has a ten-minute task timeout.
- `CHECK_INTERVAL=0s` makes the initializer one-shot.
- The initializer run-to-completion token is a deterministic 31-character hash prefix
  over the reviewed deployment contract. Relevant image, service, storage,
  KMS, proxy-policy, or job-setting changes automatically request another
  idempotent verification. Change `initializer_execution_nonce` to request one
  explicitly without otherwise changing the deployment.
- Direct VPC egress remains off. Version 1 does not add a VPC attachment.

The v1 execution token differs from the pre-v1 value, so the first v1 apply
runs one initializer execution after the new IAM and service revision are
ready, and does not succeed until that execution completes. Its provider
timeouts cover all bounded retries. Use only the hardened, idempotent Vault Init
image for this upgrade.

The initializer job is the module's only `google-beta` resource because
`run_execution_token` remains absent from the stable provider. All other
resources use the stable `google` provider.

Cloud Run assigns the runtime service account to both co-located containers, so
Vault Proxy inherits the runtime GCS and KMS credentials even though it does
not use them. Review and promote the proxy and Vault images together.

This remains a single-serving-instance deployment rather than an HA failover
topology. The service-level maximum is one, and the GCS HA lock fences the brief
revision overlap Cloud Run can still create. Vault clustering remains disabled,
so quiesce clients and use a maintenance window for proxy, environment,
identity, probe, sidecar, or other revision-producing changes.

If the existing resources need to be destroyed, first set
`deletion_protection = false`, apply, and then run the destroy operation.

## Recommended rollout

1. Verify current Vault health and a recent recovery procedure.
2. Record the existing runtime service account, bucket names, and KMS key ID.
3. Promote and record reviewed GAR digests for all three images.
4. Run `terraform plan` and confirm the runtime service account is moved, not
   replaced.
5. Confirm the data bucket remains intact and `force_destroy` remains false.
6. Apply in a maintenance window.
7. Confirm `/healthz`, `/v1/sys/health`, an administrator route, and a normal
   client authentication flow.
8. Confirm both encrypted recovery objects are readable by the initializer
   identity; Terraform has already required the initializer job to complete.
