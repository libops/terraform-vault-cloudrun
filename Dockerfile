FROM debian:bookworm@sha256:b6507e340c43553136f5078284c8c68d86ec8262b1724dde73c325e8d3dcdeba as builder
ARG DEBIAN_FRONTEND=noninteractive
# renovate: datasource=github-releases depName=hashicorp-vault-cli packageName=hashicorp/vault
ARG VAULT_VERSION=1.18.3
RUN apt-get update && apt-get install -y wget unzip
RUN wget -q https://releases.hashicorp.com/vault/${VAULT_VERSION}/vault_${VAULT_VERSION}_linux_amd64.zip
RUN unzip vault_${VAULT_VERSION}_linux_amd64.zip

FROM alpine:latest@sha256:4bcff63911fcb4448bd4fdacec207030997caf25e9bea4045fa6c8c44de311d1 as certs
RUN apk --update add ca-certificates

FROM scratch
COPY --from=certs /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=builder /vault .
COPY vault-server.hcl /etc/vault/config.hcl
ENTRYPOINT ["/vault", "server", "-config", "/etc/vault/config.hcl"]
