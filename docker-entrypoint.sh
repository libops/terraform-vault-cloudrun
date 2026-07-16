#!/bin/sh

set -eu

: "${KMS_KEY_RING:?KMS_KEY_RING is required}"
: "${KMS_CRYPTO_KEY:?KMS_CRYPTO_KEY is required}"

case "$KMS_KEY_RING" in
  *[!A-Za-z0-9_-]*)
    printf 'KMS_KEY_RING must be a Google Cloud KMS resource name\n' >&2
    exit 1
    ;;
esac
if [ "${#KMS_KEY_RING}" -gt 63 ]; then
  printf 'KMS_KEY_RING must be at most 63 characters\n' >&2
  exit 1
fi
case "$KMS_CRYPTO_KEY" in
  *[!A-Za-z0-9_-]*)
    printf 'KMS_CRYPTO_KEY must be a Google Cloud KMS resource name\n' >&2
    exit 1
    ;;
esac
if [ "${#KMS_CRYPTO_KEY}" -gt 63 ]; then
  printf 'KMS_CRYPTO_KEY must be at most 63 characters\n' >&2
  exit 1
fi

umask 077

escape_sed_replacement() {
  printf '%s' "$1" | sed 's/[&|]/\\&/g'
}

config_path="${VAULT_CONFIG_PATH:-/tmp/vault-config.hcl}"

sed \
  -e "s|__KMS_KEY_RING__|$(escape_sed_replacement "$KMS_KEY_RING")|g" \
  -e "s|__KMS_CRYPTO_KEY__|$(escape_sed_replacement "$KMS_CRYPTO_KEY")|g" \
  /etc/vault/config.hcl.tmpl > "$config_path"

if [ "$#" -gt 0 ]; then
  exec "$@"
fi

exec /usr/local/bin/vault server -config "$config_path"
