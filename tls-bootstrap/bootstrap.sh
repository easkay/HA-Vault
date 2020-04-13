#!/bin/bash

# Configurables
CERTIFICATE_DOMAIN="vault.example.com" # Change this to match the auto-hostname scheme of your chosen cloud provider
VAULT_PKI_ROLE_NAME="bootstrap"

# Internals

export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_FORMAT=json

rm -f *.crt *.key
vault server -dev > /dev/null 2>&1 &
sleep 2
VAULT_SERVER_PID="$!"

setup_pki_engine_for() {
  TARGET_SYSTEM="$1"
  SECRET_BACKEND_PATH="${TARGET_SYSTEM}-https-root"
  vault secrets enable -path="${SECRET_BACKEND_PATH}" pki > /dev/null 2>&1
  vault secrets tune -max-lease-ttl=876000h -default-lease-ttl=876000h $SECRET_BACKEND_PATH > /dev/null 2>&1 # 100 years
  vault write "${SECRET_BACKEND_PATH}/root/generate/internal" common_name="${SECRET_BACKEND_PATH}BootstrapCA" > /dev/null 2>&1
  vault write "${SECRET_BACKEND_PATH}/roles/${VAULT_PKI_ROLE_NAME}" allow_any_name=true no_store=true > /dev/null 2>&1
}

generate_certificate_for() {
  TARGET_SYSTEM="$1"
  SECRET_BACKEND_PATH="${TARGET_SYSTEM}-https-root"
  CERT_JSON=$(vault write "${SECRET_BACKEND_PATH}/issue/${VAULT_PKI_ROLE_NAME}" common_name="$CERTIFICATE_DOMAIN" alt_names="consul,*.${CERTIFICATE_DOMAIN},*.eu-west-2.consul,localhost" ip_sans="127.0.0.1" ttl=875999h)
  echo "$CERT_JSON" | jq -r '.data.certificate' > "${TARGET_SYSTEM}.crt"
  echo "$CERT_JSON" | jq -r '.data.issuing_ca' > "${TARGET_SYSTEM}-ca.crt"
  echo "$CERT_JSON" | jq -r '.data.private_key' > "${TARGET_SYSTEM}.key"
}

CERTIFICATE_DOMAIN="consul.example.com"
setup_pki_engine_for "consul"
generate_certificate_for "consul"
CERTIFICATE_DOMAIN="vault.example.com"
setup_pki_engine_for "vault"
generate_certificate_for "vault"

kill "$VAULT_SERVER_PID"
