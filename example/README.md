# Full example

This example

- Creates a Vault server in a GCP project, deployed using Cloud Run
- Creates a GCS bucket with a GSA in the same GCP project that can CRUD objects on the bucket
- Configures the [GCP secret engine](https://developer.hashicorp.com/vault/docs/secrets/gcp) on the Vault server
- Configures Vault so it can create service account keys for the GSA. The GSA keys have a [default ttl of 5m, and max ttl of 30d](https://github.com/joecorall/serverless-vault-with-cloud-run/blob/23e0bb6a0d378eb1612cdf8452137ce75f5fb6e6/example/main.tf#L93-L94). After their TTL they will be deleted from Google by Vault

In order to both create the vault server and then apply policies to it, we need to run the terraform in two stages:

1. Create Vault server
2. Apply policies on the Vault server

In between those two stages we need to define an environment variable `VAULT_TOKEN` so terraform can authenticate to our new Vault server in order to be able to create the policies.

This can be accomplished by running [tf.sh](./tf.sh)

```
git clone https://github.com/joecorall/serverless-vault-with-cloud-run.git
cd serverless-vault-with-cloud-run/example
export TF_VAR_project=YOUR-GCP-PROJECT-ID
export TF_VAR_region=us-east5
./tf.sh ${TF_VAR_project}
```
