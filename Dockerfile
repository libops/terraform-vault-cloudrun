FROM golang:1.26.6-bookworm@sha256:116d58cbd88c1297624acc6e967a060012422bacf9930927e23fb719189c6f36 AS builder

ARG TARGETARCH
ARG VAULT_VERSION=2.0.4
ARG VAULT_COMMIT=c9e9d1d4ddd4b55aae79a8949adffa9e96338720

WORKDIR /src
RUN set -eux; \
    git init; \
    git remote add origin https://github.com/hashicorp/vault.git; \
    git fetch --depth=1 origin "${VAULT_COMMIT}"; \
    git checkout --detach FETCH_HEAD; \
    test "$(git rev-parse HEAD)" = "${VAULT_COMMIT}"; \
    test "$(cat version/VERSION)" = "${VAULT_VERSION}"

RUN set -eux; \
    case "${TARGETARCH}" in amd64|arm64) ;; *) exit 1 ;; esac; \
    GOFLAGS=-buildvcs=false CGO_ENABLED=0 GOOS=linux GOARCH="${TARGETARCH}" BUILD_TAGS=ui ./scripts/build.sh; \
    install -D -m 0555 bin/vault /out/vault; \
    /out/vault version | grep -F "Vault v${VAULT_VERSION}"

FROM alpine:3.23@sha256:fd791d74b68913cbb027c6546007b3f0d3bc45125f797758156952bc2d6daf40

ARG VAULT_VERSION=2.0.4
ARG IMAGE_REVISION=1

LABEL org.opencontainers.image.title="LibOps Vault server" \
      org.opencontainers.image.description="Vault ${VAULT_VERSION} for the LibOps Cloud Run module" \
      org.opencontainers.image.source="https://github.com/libops/terraform-vault-cloudrun" \
      org.opencontainers.image.licenses="BUSL-1.1" \
      org.opencontainers.image.version="${VAULT_VERSION}-libops.${IMAGE_REVISION}"

RUN apk add --no-cache \
        'ca-certificates=20260611-r0' \
        'libcrypto3=3.5.8-r0' \
        'libssl3=3.5.8-r0' && \
    mkdir -p /etc/vault && \
    chown 0:0 /etc/vault && \
    chmod 0755 /etc/vault

COPY --from=builder --chown=0:0 --chmod=0555 /out/vault /usr/local/bin/vault
COPY --from=builder --chown=0:0 --chmod=0444 /src/LICENSE /licenses/Vault-LICENSE
COPY --chown=0:0 --chmod=0444 vault-server.hcl.tmpl /etc/vault/config.hcl.tmpl
COPY --chown=0:0 --chmod=0555 docker-entrypoint.sh /docker-entrypoint.sh

USER 65532:65532

EXPOSE 8200

ENTRYPOINT ["/docker-entrypoint.sh"]
