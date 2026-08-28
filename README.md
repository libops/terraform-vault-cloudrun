# terraform-vault-cloudrun

This Terraform module deploys a single-instance Vault runtime on Google Cloud
Run, a separately identified public Vault Proxy v2 service, and a one-shot
initializer job. It is a
fork of
[kelseyhightower/serverless-vault-with-cloud-run](https://github.com/kelseyhightower/serverless-vault-with-cloud-run)
with explicit workload identities, immutable image inputs, and recovery
material isolated from the long-running Vault process.

## Security model

The module creates three service accounts with separate responsibilities:

- The Vault runtime can administer objects only in the Vault data bucket and
  view, encrypt, or decrypt with the configured KMS key. Vault's `gcpckms`
  auto-unseal integration needs `cryptoKeys.get` in addition to cryptographic
  operations.
- The initializer can create and view objects only in the recovery bucket and
  encrypt or decrypt with the same KMS key. It cannot delete or overwrite
  recovery objects.
- The public proxy has no GCS or KMS role. It can invoke only the IAM-protected
  Vault runtime service and authenticates upstream with a short-lived metadata
  ID token in `X-Serverless-Authorization`, preserving the client's separate
  Vault authorization header.

Cloud Run assigns one service identity to a revision, so Vault and the public
proxy intentionally run as separate services. The Vault runtime is not publicly
invokable; only the proxy service account receives `roles/run.invoker`. The
proxy remains publicly invokable because it is the application-layer boundary.

Vault Proxy v2 permits unauthenticated access only to canonical route patterns
in `public_routes`. Every other route requires an `X-Admin-Token` Google access
token whose verified email is either explicitly listed in `admin_emails` or is
the initializer service account. The Vault runtime service account is not a
proxy administrator. Email comparisons and duplicate checks are
case-insensitive to match Vault Proxy's identity normalization.

Vault still enforces its own tokens and policies after the proxy check.

The Vault runtime must pass its port-specific health probe on `8200`. Terraform
then creates the public proxy, which must pass `/healthz` on `8080`, before the
initializer runs. The Vault health probe treats an uninitialized server as
ready so the initializer job can complete the first deployment.

## Prerequisites

Enable these APIs in the target project before using the module:

- Cloud Run API
- Cloud Key Management Service API
- Cloud Storage API
- Identity and Access Management API

Because Terraform creates and immediately executes the initializer, the
applying identity also needs permission to run that Cloud Run job in addition
to its resource-management permissions.

The caller must supply three
[Artifact Registry](https://cloud.google.com/artifact-registry/docs/docker/names)
image references pinned by manifest digest:

- Vault server
- Vault Proxy v2
- Vault initializer

The module intentionally has no mutable image defaults. Review and promote the
three GAR digests together before changing a deployment.

The initializer job uses the `google-beta` provider only because Cloud Run's
Terraform `run_execution_token` remains absent from the stable provider. Every
other resource uses the stable `google` provider. This keeps initialization
Terraform-managed and makes `terraform apply` wait for successful completion,
without introducing a credentialed `local-exec` or manual deployment step.

## Usage

```hcl
module "vault" {
  source = "git::https://github.com/libops/terraform-vault-cloudrun.git?ref=1.0.0"

  project = "example-project"
  region  = "us-central1"

  vault_image = "us-docker.pkg.dev/example-project/public/vault@sha256:REVIEWED_DIGEST"
  vault_proxy_image = "us-docker.pkg.dev/example-project/public/vault-proxy@sha256:REVIEWED_DIGEST"
  vault_init_image  = "us-docker.pkg.dev/example-project/public/vault-init@sha256:REVIEWED_DIGEST"

  # This module is intentionally blocked by default from being mistaken for
  # an HA production topology.
  single_instance_preview_acknowledged = true

  admin_emails = [
    "vault-admin@example.org",
  ]
}
```

`deletion_protection` defaults to `true` for both the service and initializer
job. Set it to `false` and apply that change before intentionally destroying
the deployment.

## Initialization behavior

The initializer has one task, parallelism one, three retries, and a ten-minute
task timeout. `CHECK_INTERVAL=0s` makes every task a bounded one-shot attempt.
Its 31-character `run_execution_token` is a deterministic SHA-256 prefix over
the three image digests, service and identity settings, bucket and KMS IDs,
proxy policy, startup contract, and initializer job settings. A relevant
deployment change therefore runs the idempotent initializer verification
again and keeps the apply open until that execution succeeds. Provider create
and update timeouts allow all bounded retries to finish. Change
`initializer_execution_nonce` when an operator needs to request the same
verification without otherwise changing the deployment.

`init_job_name` is limited to 30 characters so the job name, separator, and
31-character execution suffix remain inside Cloud Run's execution-name limit.

Vault Init authenticates protected health and initialization routes as the
initializer service account. The selected Vault Init image must request a
Google metadata access token containing the `userinfo.email` scope expected by
Vault Proxy v2.

Root-token-free encrypted recovery material is stored in
`recovery_bucket_name`. Fresh initialization requests five recovery shares with
a threshold of three, enables the `cloudrun/` JSON audit device on Vault stdout,
revokes and verifies the initial root token, and records a non-secret completion
marker. Treat access to the bucket, KMS key, recovery shares, and Cloud Logging
as privileged disaster-recovery/audit access. Assign recovery shares to
independent custodians; bucket/KMS access alone is not a custody quorum. Do not
copy decrypted material into Terraform, CI, logs, tickets, chat, or command
arguments.

By default Vault returns five recovery shares to the initializer, which removes
the initial root token, encrypts the recovery bundle with Google KMS, and stores
only ciphertext in the create-only recovery object in GCS. Set
`recovery_pgp_keys` to five distinct base64-encoded binary PGP public keys only
when independent human custody is required; Vault then encrypts one share to
each key before the KMS/GCS protection layer. Private keys and decrypted
recovery shares must not enter Terraform, CI, logs, tickets, or chat.

## Public route policy

The defaults expose the minimum OIDC discovery, OIDC callback, and userpass
login paths used by common clients. `/v1/sys/health` is always added even when
`public_routes` is empty. Vault Proxy v2 path patterns are explicit:

- A literal path matches exactly.
- `*` matches one path segment.
- A final `/**` matches a subtree.

Legacy trailing-slash prefixes such as `/v1/auth/userpass/` are rejected. Add a
secret-engine subtree only when Vault policy is intentionally the sole
authorization boundary for that path.

## Networking

Direct VPC egress is deliberately `OFF` and is not exposed as a module input.
This deployment uses Google APIs and the public Cloud Run service URL, so it
does not need a Serverless VPC Access connector or Direct VPC attachment.
Keeping networking outside this module also avoids silently expanding the
Vault trust boundary. A platform that requires private egress should compose
and review that network path separately rather than enabling it implicitly
here.

## Availability and revisions

This remains a single-serving-instance Vault deployment, not an HA failover
topology. The pinned Cloud Run module applies a service-level maximum of one
across traffic-serving revisions. Because Cloud Run can still briefly exceed a
configured maximum during rollout, the GCS backend enables its HA lock to fence
overlapping revisions so only one Vault server becomes active. Clustering stays
disabled because Cloud Run services cannot address individual instance cluster
listeners. Revision changes can therefore cause transient request failures;
quiesce clients and use a maintenance window. The separate proxy may scale
independently but does not make the Vault storage runtime HA. Production
availability claims remain blocked until an explicitly selected HA topology
and a hosted failover and recovery drill are promoted.

## Local development image

The repository Dockerfile is a development-only way to exercise the included
Vault configuration template. Terraform never builds it and it is not a
default image source. Production callers must supply a reviewed,
digest-pinned GAR image through `vault_image`.

## Upgrade

Version 1 changes identities, IAM, image inputs, proxy routes, and initialization
behavior. Read [UPGRADING.md](UPGRADING.md) and review the full Terraform plan
before applying it to an existing Vault deployment.

## Vault server image publication

Terraform never builds or pushes images. The repository Dockerfile is the
reviewed source for the independently released, multi-platform `vault-server`
image. It checks out the exact upstream Vault 2.0.3 commit, rebuilds the
UI-enabled target with a digest-pinned patched Go toolchain, and copies only the
binary and license into a numeric non-root runtime. The entrypoint renders the
seal configuration from `KMS_KEY_RING` and `KMS_CRYPTO_KEY` at startup.

Image pull requests build and scan both native architectures without publisher
credentials. After the exact commit passes protected `main` CI, the shared
LibOps workflow publishes, scans, signs, and verifies the same multi-platform
manifest in GHCR and `us-docker.pkg.dev/libops-images/public`. Its unique tag
records the upstream version, LibOps packaging revision, source commit, and
workflow run. Deployments must still resolve and use the verified GAR digest.

Image payload pull requests and image-trust-only pull requests must retain
`[skip-release]` in the title so they cannot cut a Terraform module release. A
pull request that changes both module payload and image trust must carry an
explicit release marker. The release workflow independently suppresses
unmarked image/trust-only changes as a second guard. Keep the `Terraform CI`
workflow name, path, protected-main trigger, and image-contract validation
synchronized with the Vault image workflow and shared WIF allowlist.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.7.0, < 2.0.0 |
| <a name="requirement_google"></a> [google](#requirement\_google) | ~> 7.22 |
| <a name="requirement_google-beta"></a> [google-beta](#requirement\_google-beta) | ~> 7.22 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_google"></a> [google](#provider\_google) | ~> 7.22 |
| <a name="provider_google-beta"></a> [google-beta](#provider\_google-beta) | ~> 7.22 |

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_vault"></a> [vault](#module\_vault) | https://github.com/libops/terraform-cloudrun-v2/archive/4b1c2551369ec6f31372edb33721c80daeeeab62.zip//terraform-cloudrun-v2-4b1c2551369ec6f31372edb33721c80daeeeab62 | n/a |
| <a name="module_vault_proxy"></a> [vault\_proxy](#module\_vault\_proxy) | https://github.com/libops/terraform-cloudrun-v2/archive/4b1c2551369ec6f31372edb33721c80daeeeab62.zip//terraform-cloudrun-v2-4b1c2551369ec6f31372edb33721c80daeeeab62 | n/a |

## Resources

| Name | Type |
|------|------|
| [google-beta_google_cloud_run_v2_job.vault-init](https://registry.terraform.io/providers/hashicorp/google-beta/latest/docs/resources/google_cloud_run_v2_job) | resource |
| [google_kms_crypto_key.key](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/kms_crypto_key) | resource |
| [google_kms_crypto_key_iam_member.initializer](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/kms_crypto_key_iam_member) | resource |
| [google_kms_crypto_key_iam_member.vault](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/kms_crypto_key_iam_member) | resource |
| [google_kms_key_ring.vault-server](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/kms_key_ring) | resource |
| [google_service_account.initializer](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account) | resource |
| [google_service_account.proxy](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account) | resource |
| [google_service_account.runtime](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account) | resource |
| [google_storage_bucket.vault](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/storage_bucket) | resource |
| [google_storage_bucket_iam_member.initializer_recovery](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/storage_bucket_iam_member) | resource |
| [google_storage_bucket_iam_member.member](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/storage_bucket_iam_member) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_admin_emails"></a> [admin\_emails](#input\_admin\_emails) | Explicit human or automation emails allowed to access protected Vault routes. The initializer service account is added automatically. | `list(string)` | n/a | yes |
| <a name="input_country"></a> [country](#input\_country) | GCS location for the Vault data and recovery buckets. | `string` | `"us"` | no |
| <a name="input_create_kms"></a> [create\_kms](#input\_create\_kms) | Whether to create the KMS key ring and crypto key. | `bool` | `true` | no |
| <a name="input_data_bucket_name"></a> [data\_bucket\_name](#input\_data\_bucket\_name) | Bucket name for Vault data storage. Defaults to a name derived from project and service name. | `string` | `""` | no |
| <a name="input_deletion_protection"></a> [deletion\_protection](#input\_deletion\_protection) | Protect both the Vault Cloud Run service and initializer job from accidental deletion. | `bool` | `true` | no |
| <a name="input_gsa_account_id"></a> [gsa\_account\_id](#input\_gsa\_account\_id) | Service account ID for the Vault runtime. Defaults to a truncated form of name. | `string` | `""` | no |
| <a name="input_init_job_name"></a> [init\_job\_name](#input\_init\_job\_name) | Cloud Run job name used to initialize Vault. | `string` | `"vault-init"` | no |
| <a name="input_initializer_execution_nonce"></a> [initializer\_execution\_nonce](#input\_initializer\_execution\_nonce) | Optional operator-controlled nonce included in the initializer execution-contract hash. Change it to deliberately request another idempotent verification. | `string` | `""` | no |
| <a name="input_initializer_gsa_account_id"></a> [initializer\_gsa\_account\_id](#input\_initializer\_gsa\_account\_id) | Service account ID for the one-shot Vault initializer. Defaults to the service name plus -init. | `string` | `""` | no |
| <a name="input_key_bucket_name"></a> [key\_bucket\_name](#input\_key\_bucket\_name) | Bucket name for encrypted Vault recovery material. Defaults to a name derived from project and service name. | `string` | `""` | no |
| <a name="input_kms_key_name"></a> [kms\_key\_name](#input\_kms\_key\_name) | KMS crypto key name used for auto-unseal and recovery-material encryption. | `string` | `"vault"` | no |
| <a name="input_kms_key_ring_name"></a> [kms\_key\_ring\_name](#input\_kms\_key\_ring\_name) | KMS key ring name used for auto-unseal. | `string` | `"vault-server"` | no |
| <a name="input_name"></a> [name](#input\_name) | Cloud Run service name for the Vault server. | `string` | `"vault-server"` | no |
| <a name="input_project"></a> [project](#input\_project) | GCP project in which to deploy Vault. | `string` | n/a | yes |
| <a name="input_proxy_gsa_account_id"></a> [proxy\_gsa\_account\_id](#input\_proxy\_gsa\_account\_id) | Service account ID for the public Vault proxy. Defaults to the service name plus -proxy. | `string` | `""` | no |
| <a name="input_public_routes"></a> [public\_routes](#input\_public\_routes) | Optional canonical Vault Proxy v2 path patterns accessible without X-Admin-Token. /v1/sys/health is always added. | `list(string)` | <pre>[<br/>  "/.well-known/**",<br/>  "/v1/identity/oidc/provider/*/.well-known/**",<br/>  "/v1/identity/oidc/provider/*/authorize",<br/>  "/v1/identity/oidc/provider/*/token",<br/>  "/v1/identity/oidc/provider/*/userinfo",<br/>  "/ui/vault/identity/oidc/provider/*/authorize",<br/>  "/v1/auth/oidc/oidc/auth_url",<br/>  "/v1/auth/oidc/oidc/callback",<br/>  "/ui/vault/auth/*/oidc/callback",<br/>  "/v1/auth/userpass/login/**"<br/>]</pre> | no |
| <a name="input_recovery_pgp_keys"></a> [recovery\_pgp\_keys](#input\_recovery\_pgp\_keys) | Optional set of five distinct base64-encoded binary PGP public keys for independent recovery-share custodians. When omitted, Vault returns the shares to the initializer for KMS encryption and create-only GCS storage. | `list(string)` | `[]` | no |
| <a name="input_region"></a> [region](#input\_region) | GCP region in which to deploy the Cloud Run service and initializer job. | `string` | `"us-east5"` | no |
| <a name="input_single_instance_preview_acknowledged"></a> [single\_instance\_preview\_acknowledged](#input\_single\_instance\_preview\_acknowledged) | Required explicit acknowledgement that this module is a single-serving-instance preview, not an HA Vault topology. Set true only for an approved limited deployment; this is not risk acceptance or production evidence. | `bool` | n/a | yes |
| <a name="input_vault_image"></a> [vault\_image](#input\_vault\_image) | Digest-pinned GAR image reference for the Vault server container. | `string` | n/a | yes |
| <a name="input_vault_init_image"></a> [vault\_init\_image](#input\_vault\_init\_image) | Digest-pinned GAR image reference for the Vault initializer container. | `string` | n/a | yes |
| <a name="input_vault_proxy_image"></a> [vault\_proxy\_image](#input\_vault\_proxy\_image) | Digest-pinned GAR image reference for the Vault Proxy v2 container. | `string` | n/a | yes |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_data_bucket_name"></a> [data\_bucket\_name](#output\_data\_bucket\_name) | Bucket containing the Vault GCS storage backend. |
| <a name="output_gsa"></a> [gsa](#output\_gsa) | Deprecated compatibility alias for runtime\_service\_account\_email. |
| <a name="output_initializer_execution_token"></a> [initializer\_execution\_token](#output\_initializer\_execution\_token) | Deterministic 31-character run-to-completion token derived from the initializer-relevant deployment contract. |
| <a name="output_initializer_job_name"></a> [initializer\_job\_name](#output\_initializer\_job\_name) | Name of the one-shot Vault initializer Cloud Run job. |
| <a name="output_initializer_service_account_email"></a> [initializer\_service\_account\_email](#output\_initializer\_service\_account\_email) | Service account used by the one-shot Vault initializer job. |
| <a name="output_key_bucket"></a> [key\_bucket](#output\_key\_bucket) | Deprecated compatibility alias for recovery\_bucket\_name. |
| <a name="output_kms_key_id"></a> [kms\_key\_id](#output\_kms\_key\_id) | Full resource ID of the KMS key used by Vault and the initializer. |
| <a name="output_proxy_service_account_email"></a> [proxy\_service\_account\_email](#output\_proxy\_service\_account\_email) | Least-privileged service account used by the public Vault proxy. |
| <a name="output_recovery_bucket_name"></a> [recovery\_bucket\_name](#output\_recovery\_bucket\_name) | Bucket containing encrypted Vault recovery material. |
| <a name="output_runtime_service_account_email"></a> [runtime\_service\_account\_email](#output\_runtime\_service\_account\_email) | Service account used by the long-running Vault service. |
| <a name="output_vault-url"></a> [vault-url](#output\_vault-url) | Deprecated compatibility alias for vault\_url. |
| <a name="output_vault_runtime_url"></a> [vault\_runtime\_url](#output\_vault\_runtime\_url) | IAM-protected URL of the Vault runtime Cloud Run service. |
| <a name="output_vault_url"></a> [vault\_url](#output\_vault\_url) | Public URL of the Vault proxy Cloud Run service. |
<!-- END_TF_DOCS -->
