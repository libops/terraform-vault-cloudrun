#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
dockerfile="$repo_root/Dockerfile"
entrypoint="$repo_root/docker-entrypoint.sh"
workflow="$repo_root/.github/workflows/vault-image.yml"
ci_workflow="$repo_root/.github/workflows/lint-test.yml"
release_workflow="$repo_root/.github/workflows/release.yml"
shared_publisher_sha="8e27d95846671a9e319f1900e86a488a1d4f39b3"

fail() {
  printf 'Vault image contract: %s\n' "$*" >&2
  exit 1
}

for required_file in \
  "$dockerfile" \
  "$entrypoint" \
  "$workflow" \
  "$ci_workflow" \
  "$release_workflow"; do
  [[ -f "$required_file" ]] || fail "required file is missing: $required_file"
done

mapfile -t vault_versions < <(
  sed -n 's/^ARG VAULT_VERSION=\([^[:space:]]\+\)$/\1/p' "$dockerfile" |
    sort -u
)
[[ "${#vault_versions[@]}" -eq 1 ]] ||
  fail "builder and runtime stages must use one exact VAULT_VERSION"
vault_version="${vault_versions[0]}"
[[ "$vault_version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] ||
  fail "VAULT_VERSION must be exact SemVer"

image_revision="$(
  sed -n 's/^ARG IMAGE_REVISION=\([1-9][0-9]*\)$/\1/p' "$dockerfile"
)"
[[ -n "$image_revision" ]] ||
  fail "IMAGE_REVISION must be a positive integer"

vault_commit="$(
  sed -n 's/^ARG VAULT_COMMIT=\([0-9a-f]\{40\}\)$/\1/p' "$dockerfile"
)"
[[ -n "$vault_commit" ]] ||
  fail "VAULT_COMMIT must be an exact upstream source commit"
grep -Fq 'golang:1.26.5-bookworm@sha256:' "$dockerfile" ||
  fail "Vault must be rebuilt with the pinned patched Go toolchain"
grep -Fq 'git fetch --depth=1 origin "${VAULT_COMMIT}"' "$dockerfile" ||
  fail "Dockerfile does not fetch the exact upstream Vault commit"
grep -Fq 'test "$(git rev-parse HEAD)" = "${VAULT_COMMIT}"' "$dockerfile" ||
  fail "Dockerfile does not verify the upstream Vault checkout"
grep -Fq 'GOFLAGS=-buildvcs=false CGO_ENABLED=0 GOOS=linux GOARCH="${TARGETARCH}" BUILD_TAGS=ui ./scripts/build.sh' "$dockerfile" ||
  fail "Dockerfile does not build the official UI-enabled Vault target without scanner-confusing automatic VCS metadata"
grep -Fq 'COPY --from=builder --chown=0:0 --chmod=0444 /src/LICENSE /licenses/Vault-LICENSE' "$dockerfile" ||
  fail "Vault source license is not preserved in the runtime image"
grep -Fq 'USER 65532:65532' "$dockerfile" ||
  fail "Vault runtime must use the dedicated non-root numeric identity"
grep -Fq "apk add --no-cache 'ca-certificates=20260611-r0'" "$dockerfile" ||
  fail "runtime packages must be version-pinned"
grep -Fq 'chmod 0755 /etc/vault' "$dockerfile" ||
  fail "root-owned Vault configuration directory must remain traversable"
grep -Fq 'COPY --from=builder --chown=0:0 --chmod=0555 /out/vault /usr/local/bin/vault' "$dockerfile" ||
  fail "Vault binary permissions or ownership are not locked down"
grep -Fq 'COPY --chown=0:0 --chmod=0444 vault-server.hcl.tmpl /etc/vault/config.hcl.tmpl' "$dockerfile" ||
  fail "Vault template must remain root-owned and read-only"
grep -Fq 'disable_clustering           = true' "$repo_root/vault-server.hcl.tmpl" ||
  fail "the Cloud Run image must not advertise an unreachable cluster listener"
grep -Fq 'ha_enabled = "true"' "$repo_root/vault-server.hcl.tmpl" ||
  fail "the GCS storage backend must fence overlapping revisions with its HA lock"
grep -Fq 'exec /usr/local/bin/vault server -config "$config_path"' "$entrypoint" ||
  fail "entrypoint does not execute the verified runtime binary"
grep -Fq 'if [ "$#" -gt 0 ]; then' "$entrypoint" ||
  fail "entrypoint does not expose its config-render smoke path"
grep -Fq 'KMS_KEY_RING must be a Google Cloud KMS resource name' "$entrypoint" ||
  fail "entrypoint does not validate the KMS key-ring name"
grep -Fq 'KMS_CRYPTO_KEY must be a Google Cloud KMS resource name' "$entrypoint" ||
  fail "entrypoint does not validate the KMS crypto-key name"
grep -Fq 'KMS_KEY_RING must be at most 63 characters' "$entrypoint" ||
  fail "entrypoint does not enforce the KMS key-ring length limit"
grep -Fq 'KMS_CRYPTO_KEY must be at most 63 characters' "$entrypoint" ||
  fail "entrypoint does not enforce the KMS crypto-key length limit"
grep -Fq 'umask 077' "$entrypoint" ||
  fail "rendered Vault configuration is not owner-only"

grep -Fq 'workflow_run:' "$workflow" ||
  fail "publication is not gated on the repository CI workflow"
grep -Fq '      - edited' "$workflow" ||
  fail "editing an image pull request title does not rerun release separation"
grep -Fq '      - .github/workflows/lint-test.yml' "$workflow" ||
  fail "changes to the image CI trust anchor do not run the image checks"
grep -Fq '      - .github/workflows/release.yml' "$workflow" ||
  fail "changes to the release-separation trust anchor do not run the image checks"
grep -Fq '[[ "$PR_TITLE" == *"[skip-release]"* ]]' "$workflow" ||
  fail "image changes can release the Terraform module"
grep -Fq 'image_payload_changed=false' "$workflow" ||
  fail "image and module changes are not classified separately"
grep -Fq 'image_trust_changed=false' "$workflow" ||
  fail "image trust changes are not classified separately"
grep -Fq 'module_payload_changed=false' "$workflow" ||
  fail "module payload changes are not classified separately"
grep -Fq 'if [[ "$image_payload_changed" == true ||' "$workflow" ||
  fail "image release separation is not limited to image payload changes"
grep -Fq 'Mixed image-trust and module changes require an explicit release marker' "$workflow" ||
  fail "mixed trust and module changes do not require explicit release intent"
for eligibility_condition in \
  '"$CI_CONCLUSION" == success' \
  '"$CI_EVENT" == push' \
  '"$CI_HEAD_BRANCH" == main' \
  '"$CI_HEAD_REPOSITORY" == "$GITHUB_REPOSITORY"' \
  '"$CI_WORKFLOW_PATH" == .github/workflows/lint-test.yml'; do
  grep -Fq "$eligibility_condition" "$workflow" ||
    fail "workflow-run eligibility is missing: $eligibility_condition"
done
grep -Fq "libops/.github/.github/workflows/build-push.yaml@${shared_publisher_sha}" "$workflow" ||
  fail "publication does not use the reviewed immutable shared publisher"
grep -Fq 'additional-gar-registry: us-docker.pkg.dev/libops-images/public' "$workflow" ||
  fail "Cloud Run image is not published to the shared public GAR"
grep -Fq 'GCLOUD_OIDC_POOL: ${{ secrets.GCLOUD_OIDC_POOL }}' "$workflow" ||
  fail "publication does not use the shared WIF provider secret"
grep -Fq 'GSA: ${{ secrets.GSA }}' "$workflow" ||
  fail "publication does not use the shared publisher service account"
grep -Fq 'expected-main-sha: ${{ github.event.workflow_run.head_sha }}' "$workflow" ||
  fail "shared publication is not guarded by the exact current main commit"
grep -Fq "eligible: \${{ steps.eligibility.outputs.eligible }}" "$workflow" ||
  fail "workflow-run eligibility is not exposed to publication and result gating"
grep -Fq "if: needs.authorize.outputs.eligible == 'true'" "$workflow" ||
  fail "publication is not restricted to an eligible main push"
grep -Fq 'if [[ "$ELIGIBLE_WORKFLOW_RUN" == true ]]; then' "$workflow" ||
  fail "ineligible workflow completions are not handled as intentional no-ops"
grep -Fq 'attempt-${GITHUB_RUN_ATTEMPT}' "$workflow" ||
  fail "image publication tag can be overwritten by a workflow rerun"
grep -Fq 'scan: true' "$workflow" ||
  fail "published image scanning is disabled"
grep -Fq 'sign: true' "$workflow" ||
  fail "published image signing is disabled"

if grep -Fq 'build-push.yaml@main' "$workflow" ||
  grep -Fq 'secrets: inherit' "$workflow"; then
  fail "workflow uses a mutable publisher or over-broad secret forwarding"
fi

grep -Fxq 'name: Terraform CI' "$ci_workflow" ||
  fail "the triggering workflow name no longer matches the image workflow"
ci_push_trigger="$(
  awk '
    /^  push:$/ {
      in_push = 1
      print
      next
    }
    in_push && /^  [[:alnum:]_-]+:/ {
      exit
    }
    in_push {
      print
    }
  ' "$ci_workflow"
)"
grep -Fq '  push:' <<< "$ci_push_trigger" ||
  fail "the triggering workflow no longer runs on pushes"
grep -Fq '    branches:' <<< "$ci_push_trigger" ||
  fail "the triggering workflow push is not branch-restricted"
grep -Fq '      - main' <<< "$ci_push_trigger" ||
  fail "the triggering workflow no longer runs on main"
grep -Fq 'run: bash scripts/check-vault-image-contract.sh' "$ci_workflow" ||
  fail "the triggering workflow no longer validates the image contract"

for release_contract in \
  'name: Classify merged change' \
  'changed_files="$(' \
  'gh api --paginate \' \
  '.previous_filename // empty' \
  'elif [[ "$PR_TITLE" != *"[major]"* &&' \
  'image_or_trust_changed=false' \
  'Dockerfile|docker-entrypoint.sh|vault-server.hcl.tmpl|scripts/check-vault-image-contract.sh|.github/workflows/lint-test.yml|.github/workflows/release.yml|.github/workflows/vault-image.yml)' \
  'if [[ "$image_or_trust_changed" == true && "$other_changed" == false ]]; then' \
  'if: needs.classify.outputs.release-module == '\''true'\'''; do
  grep -Fq "$release_contract" "$release_workflow" ||
    fail "the module release workflow no longer classifies image-only changes: $release_contract"
done

if [[ "${1:-}" == "--print-tag" ]]; then
  printf '%s-libops.%s\n' "$vault_version" "$image_revision"
elif [[ "$#" -ne 0 ]]; then
  fail "unsupported argument: $1"
fi
