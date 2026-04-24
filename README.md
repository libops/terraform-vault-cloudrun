# terraform-vault-cloudrun

Fork of [kelseyhightower/serverless-vault-with-cloud-run](https://github.com/kelseyhightower/serverless-vault-with-cloud-run), reimagined as a terraform module to deploy Vault using Google Cloud Run.


## Usage

In your existing terraform code, add something like what's seen in [the example](./example)

The GCP project needs the following non-standard APIs enabled:

- Artifact Registry API
- Cloud Run API
- Google Cloud KMS API
- Identity and Access Management (IAM) API

## After terraform apply

![Serverless Vault Architecture](serverless-vault.png)

After this module has been ran, the Vault server is up and running and has been initialized. The root token is encrypted in a GCS bucket.

The Vault image now renders its seal config at container startup from the
runtime `KMS_KEY_RING` and `KMS_CRYPTO_KEY` environment variables. That keeps
the KMS binding out of the built image so multiple environments can safely
share the same module code and repository without image-content drift.
The module also forces the Vault image build to `linux/amd64` so Cloud Run
always receives a compatible image even when Terraform runs from Apple Silicon
or another non-amd64 host.

If you list the GCS storage bucket you will see a new set of directories created by Vault:

```
$ gsutil ls gs://${TF_VAR_project}-data

gs://XXXXXX-data/core/
gs://XXXXXX-data/logical/
gs://XXXXXX-data/sys/
```

Vault can be configured using the [Vault UI](https://www.vaultproject.io/docs/configuration/ui) by visiting the `vault-server` service URL in browser:

```
gcloud run services describe vault-server \
  --platform managed \
  --region ${TF_VAR_region} \
  --project ${TF_VAR_project} \
  --format 'value(status.url)'
```

You can also use the `vault` command line tool as described in the next section.

### Retrieve the Vault Server Status Using the Vault Client

[Download](https://www.vaultproject.io/downloads) the Vault binary and add it to your path:

```
$ vault version

Vault v1.12.3 (209b3dd99fe8ca320340d08c70cff5f620261f9b), built 2023-02-02T09:07:27Z
```

Configure the vault CLI to use the `vault-server` Cloud Run service URL by setting the `VAULT_ADDR` environment variable:

```
export VAULT_ADDR=$(gcloud run services describe vault-server \
  --platform managed \
  --region ${TF_VAR_region} \
  --project ${TF_VAR_project} \
  --format 'value(status.url)')
```

We also need to set the `VAULT_TOKEN`

```
gsutil cp gs://${TF_VAR_project}-key/root-token.enc . > /dev/null 2>&1
base64 -d root-token.enc > root-token.dc
gcloud kms decrypt --key=vault --keyring=vault-server --location=global \
  --project=${TF_VAR_project} \
  --ciphertext-file=root-token.dc \
  --plaintext-file=root-token
export VAULT_TOKEN=$(cat root-token)
rm root-token root-token.enc root-token.dc
```

Now you can retrieve the status of the remote Vault server:

```
$ vault status

Key                      Value
---                      -----
Recovery Seal Type       shamir
Initialized              true
Sealed                   false
Total Recovery Shares    1
Threshold                1
Version                  1.12.3
Build Date               2023-02-02T09:07:27Z
Storage Type             gcs
Cluster Name             vault-cluster-XXXXXXXX
Cluster ID               XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX
HA Enabled               false
```

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_docker"></a> [docker](#requirement\_docker) | >= 3.0.1 |
| <a name="requirement_google"></a> [google](#requirement\_google) | >= 7.22.0 |
| <a name="requirement_google-beta"></a> [google-beta](#requirement\_google-beta) | >= 7.22.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_docker"></a> [docker](#provider\_docker) | >= 3.0.1 |
| <a name="provider_google"></a> [google](#provider\_google) | >= 7.22.0 |
| <a name="provider_google-beta"></a> [google-beta](#provider\_google-beta) | >= 7.22.0 |

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_vault"></a> [vault](#module\_vault) | git::https://github.com/libops/terraform-cloudrun-v2 | 0.5.2 |

## Resources

| Name | Type |
|------|------|
| [docker_image.vault](https://registry.terraform.io/providers/kreuzwerker/docker/latest/docs/resources/image) | resource |
| [docker_registry_image.vault](https://registry.terraform.io/providers/kreuzwerker/docker/latest/docs/resources/registry_image) | resource |
| [google-beta_google_cloud_run_v2_job.vault-init](https://registry.terraform.io/providers/hashicorp/google-beta/latest/docs/resources/google_cloud_run_v2_job) | resource |
| [google_artifact_registry_repository.private](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/artifact_registry_repository) | resource |
| [google_kms_crypto_key.key](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/kms_crypto_key) | resource |
| [google_kms_crypto_key_iam_member.vault](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/kms_crypto_key_iam_member) | resource |
| [google_kms_key_ring.vault-server](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/kms_key_ring) | resource |
| [google_service_account.gsa](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account) | resource |
| [google_storage_bucket.vault](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/storage_bucket) | resource |
| [google_storage_bucket_iam_member.member](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/storage_bucket_iam_member) | resource |
| [docker_registry_image.vault-proxy](https://registry.terraform.io/providers/kreuzwerker/docker/latest/docs/data-sources/registry_image) | data source |
| [google_client_openid_userinfo.current](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/client_openid_userinfo) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_project"></a> [project](#input\_project) | The GCP project to create or deploy the GCP resources into | `string` | n/a | yes |
| <a name="input_admin_emails"></a> [admin\_emails](#input\_admin\_emails) | List of emails (users or service accounts) that are allowed to access non-public routes by passing X-Admin-Token header with a google access token. | `list(string)` | `[]` | no |
| <a name="input_country"></a> [country](#input\_country) | n/a | `string` | `"us"` | no |
| <a name="input_create_kms"></a> [create\_kms](#input\_create\_kms) | Whether to create the KMS key ring and crypto key. | `bool` | `true` | no |
| <a name="input_create_repository"></a> [create\_repository](#input\_create\_repository) | Whether or not the AR repo needs to be created by this terraform | `bool` | `true` | no |
| <a name="input_data_bucket_name"></a> [data\_bucket\_name](#input\_data\_bucket\_name) | Bucket name for Vault data storage. Defaults to a name derived from project and service name. | `string` | `""` | no |
| <a name="input_gsa_account_id"></a> [gsa\_account\_id](#input\_gsa\_account\_id) | Service account id for the Vault runtime. Defaults to a truncated form of name. | `string` | `""` | no |
| <a name="input_image_name"></a> [image\_name](#input\_image\_name) | Docker image name to push into Artifact Registry. | `string` | `"vault-server"` | no |
| <a name="input_init_image"></a> [init\_image](#input\_init\_image) | n/a | `string` | `"libops/vault-init:1.0.1"` | no |
| <a name="input_init_job_name"></a> [init\_job\_name](#input\_init\_job\_name) | Cloud Run job name used to initialize Vault. | `string` | `"vault-init"` | no |
| <a name="input_key_bucket_name"></a> [key\_bucket\_name](#input\_key\_bucket\_name) | Bucket name for stored Vault init material. Defaults to a name derived from project and service name. | `string` | `""` | no |
| <a name="input_kms_key_name"></a> [kms\_key\_name](#input\_kms\_key\_name) | KMS crypto key name used for auto-unseal. | `string` | `"vault"` | no |
| <a name="input_kms_key_ring_name"></a> [kms\_key\_ring\_name](#input\_kms\_key\_ring\_name) | KMS key ring name used for auto-unseal. | `string` | `"vault-server"` | no |
| <a name="input_name"></a> [name](#input\_name) | Cloud Run service name for the Vault server. | `string` | `"vault-server"` | no |
| <a name="input_public_routes"></a> [public\_routes](#input\_public\_routes) | List of Vault API paths that should be accessible without X-Admin-Token header. | `list(string)` | <pre>[<br/>  "/.well-known/",<br/>  "/v1/identity/oidc/",<br/>  "/v1/auth/oidc/",<br/>  "/v1/auth/userpass/"<br/>]</pre> | no |
| <a name="input_region"></a> [region](#input\_region) | The region to deploy CloudRun | `string` | `"us-east5"` | no |
| <a name="input_repository"></a> [repository](#input\_repository) | The AR repo to create or push the vault image into | `string` | `"private"` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_gsa"></a> [gsa](#output\_gsa) | The GSA the Vault instance runs as. |
| <a name="output_key_bucket"></a> [key\_bucket](#output\_key\_bucket) | n/a |
| <a name="output_repo"></a> [repo](#output\_repo) | n/a |
| <a name="output_vault-url"></a> [vault-url](#output\_vault-url) | The URL to the Vault instance. |
<!-- END_TF_DOCS -->
