FROM debian:trixie-20260406@sha256:3352c2e13876c8a5c5873ef20870e1939e73cb9a3c1aeba5e3e72172a85ce9ed as builder
ARG DEBIAN_FRONTEND=noninteractive
# renovate: datasource=github-releases depName=hashicorp-vault-cli packageName=hashicorp/vault
ARG VAULT_VERSION=1.21.4
RUN apt-get update && apt-get install -y wget unzip
RUN wget -q https://releases.hashicorp.com/vault/${VAULT_VERSION}/vault_${VAULT_VERSION}_linux_amd64.zip
RUN unzip vault_${VAULT_VERSION}_linux_amd64.zip

FROM alpine:3.23@sha256:5b10f432ef3da1b8d4c7eb6c487f2f5a8f096bc91145e68878dd4a5019afde11 as config
ARG KMS_KEY_RING=vault-server
ARG KMS_CRYPTO_KEY=vault
COPY vault-server.hcl.tmpl /tmp/vault-server.hcl.tmpl
RUN sed \
  -e "s/__KMS_KEY_RING__/${KMS_KEY_RING}/g" \
  -e "s/__KMS_CRYPTO_KEY__/${KMS_CRYPTO_KEY}/g" \
  /tmp/vault-server.hcl.tmpl > /tmp/config.hcl

FROM alpine:3.23@sha256:5b10f432ef3da1b8d4c7eb6c487f2f5a8f096bc91145e68878dd4a5019afde11 as certs
RUN apk --update add ca-certificates

FROM scratch
COPY --from=certs /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=builder /vault .
COPY --from=config /tmp/config.hcl /etc/vault/config.hcl
ENTRYPOINT ["/vault", "server", "-config", "/etc/vault/config.hcl"]
