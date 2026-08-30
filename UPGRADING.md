# Upgrading to v1

Version 1 intentionally changes the module's security boundary. Back up and
verify access to the current Vault recovery material before applying an
upgrade.

## Required configuration changes

1. Supply all three managed GAR image tags:

   ```hcl
   vault_image       = "us-docker.pkg.dev/libops-images/public/vault-server:main"
   vault_proxy_image = "us-docker.pkg.dev/libops-images/public/vault-proxy:main"
   vault_init_image  = "us-docker.pkg.dev/libops-images/public/vault-init:main"
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

6. Supply one or more explicit least-privilege audit viewers and existing
   Monitoring notification channels:

   ```hcl
   audit_log_viewer_members = [
     "group:vault-audit-reviewers@example.org",
   ]
   audit_log_location = "us-central1"
   audit_alert_notification_channels = [
     "projects/example-project/notificationChannels/vault-audit-oncall",
   ]
   ```

   Select `audit_log_location` from supported Cloud Logging locations only
   after confirming the customer and legal data-location requirement. Review
   inherited project, folder, and organization Logging roles as a separate
   access surface. The module does not create a notification channel because
   its destination and responders are an operator decision.

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
Use `initializer_gsa_account_id` or `proxy_gsa_account_id` only when a derived
ID conflicts with another account.

The upgrade removes runtime access to the recovery bucket and grants the new
initializer only Object Creator and Object Viewer there. The runtime keeps
Object Admin on the data bucket. The runtime receives KMS Viewer plus
Encrypt/Decrypt for Vault auto-unseal; the initializer receives only KMS
Encrypt/Decrypt. A new proxy identity receives only Cloud Run Invoker on the
Vault runtime and no bucket/KMS role. Review the plan for those exact removals
and additions before approval.

The old `gsa`, `key_bucket`, and `vault-url` outputs remain as deprecated
aliases. New callers should use `runtime_service_account_email`,
`recovery_bucket_name`, and `vault_url`.

The upgrade also creates a dedicated, explicitly located Vault audit Logging bucket, an
exact Vault-runtime audit sink, a least-privilege log view, and a critical
sink-error alert. Retention defaults to 365 days and Terraform prevents deletion
of the bucket, sink, view, and alert. Leave `audit_log_bucket_locked=false`
until the exact retention obligation has named business and Legal approval;
locking a Logging bucket retention policy is irreversible.

## Cloud Run changes

- The service is capped at one instance.
- Service and initializer deletion protection default to enabled.
- Vault remains at the existing service address but becomes IAM-protected and
  contains only the Vault container. A separately named public proxy service
  receives traffic, authenticates to Vault with a short-lived metadata ID
  token, and exposes `/healthz` on `8080`.
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

The public `vault_url` and deprecated `vault-url` output now point to the new
proxy service; `vault_runtime_url` identifies the IAM-protected runtime. Update
DNS and callers only after validating the proxy path. Review and promote the
proxy and Vault images together even though their identities are isolated.

Fresh deployments no longer retain an initial root token and use a five-share,
three-threshold recovery quorum. An existing v1 recovery bucket contains both a
live or historically live `root-token.enc` and a full initialization response
whose JSON also contains that token. Before the new initializer can succeed,
named custodians must perform the documented restricted migration: verify and
revoke the old root token, decrypt and re-encrypt the recovery bundle without
`root_token`, remove the legacy object, enable and verify the `cloudrun/` stdout
audit device, and write the completion marker. Back up the original encrypted
objects before mutation, retain an audit record, and never expose plaintext in
Terraform, CI, tickets, chat, or shell arguments. The initializer intentionally
fails closed instead of automating this destructive custody transition.

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
8. Confirm the root-token-free encrypted recovery bundle and non-secret
   completion marker are readable, `root-token.enc` is absent, `cloudrun/`
   audit entries reach the approved Cloud Logging sink, and the initializer job
   completed.
