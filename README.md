# terraform-vault-cloudrun

Fork of [kelseyhightower/serverless-vault-with-cloud-run](https://github.com/kelseyhightower/serverless-vault-with-cloud-run), reimagined as a terraform module to deploy Vault using Google Cloud Run.


## Usage

In your existing terraform code, add something like what's seen in [the example](./example)

## After terraform apply

![Serverless Vault Architecture](serverless-vault.png)

After this module has been ran, the Vault server is up and running and has been initialized. The root token is encrypted in a GCS bucket.

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
gcloud kms decrypt --key=key --keyring=vault-server --location=global \
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
