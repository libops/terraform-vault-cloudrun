# Allow GitHub actions to get a GSA key from Vault

locals {
  github_org = "joecorall"
  github_vault_project = "serverless-vault-with-cloud-run"
}

resource "vault_policy" "bucket-writer" {
  name = "bucket-writer"

  policy = <<EOT
path "gcp/static-account/bucket-admin/key" {
  capabilities = ["read"]
}
EOT
}

resource "vault_jwt_auth_backend" "github-jwt" {
  path = "github-jwt"
  oidc_discovery_url = "https://token.actions.githubusercontent.com"
}

resource "vault_jwt_auth_backend_role" "github-admin" {
  backend         = vault_jwt_auth_backend.github-jwt.path
  role_name       = "github"
  token_policies  = ["bucket-writer"]

  bound_audiences = [format("https://github.com/%s", local.github_org)]
  bound_claims = {
    # TODO: set the claim to whatever you like. This restricts only myself from being able to create GitHub commits/PRs that can kick off this action
    actor = "joecorall"
  }
  user_claim      = "repository"
  role_type       = "jwt"
}
