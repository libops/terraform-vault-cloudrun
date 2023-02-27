#!/bin/bash

set -euo pipefail

# need to pass the GCP project ID as the first argument to this script
export TF_VAR_project=$1

# To solve the bootstrapping problem of creating Vault
# Then being able to apply policies to the Vault instance
# We first run a targeted apply to just the module that creates the Vault server
terraform init
terraform apply -target=module.vault

# Then we fetch the token from KMS and store it in VAULT_TOKEN
gsutil cp gs://${TF_VAR_project}-key/root-token.enc . > /dev/null 2>&1
base64 -d root-token.enc > root-token.dc
gcloud kms decrypt --key=vault --keyring=vault-server --location=global \
  --project=${TF_VAR_project} \
  --ciphertext-file=root-token.dc \
  --plaintext-file=root-token
export VAULT_TOKEN=$(cat root-token)
rm root-token root-token.enc root-token.dc

# Now we can apply all of the terraform with a valid Vault token
terraform apply
