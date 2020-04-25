#!/bin/bash

CONSUL_DATACENTRE="example-dc"
VAULT_PKI_ROLE_NAME="bootstrap"

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
  CA_JSON="$(vault write "${SECRET_BACKEND_PATH}/root/generate/internal" common_name="${SECRET_BACKEND_PATH}BootstrapCA")"
  vault write "${SECRET_BACKEND_PATH}/roles/${VAULT_PKI_ROLE_NAME}" allow_any_name=true no_store=true > /dev/null 2>&1
  echo "$CA_JSON" | jq -r '.data.certificate' > "${TARGET_SYSTEM}-ca.crt"
}

generate_certificate_for() {
  TARGET_SYSTEM="$1"
  SECRET_BACKEND_PATH="${TARGET_SYSTEM}-https-root"
  if [[ ! -z "$2" ]]; then
    SECRET_BACKEND_PATH="${2}-https-root"
  fi
  CERT_JSON=$(vault write "${SECRET_BACKEND_PATH}/issue/${VAULT_PKI_ROLE_NAME}" common_name="$CERTIFICATE_DOMAIN" alt_names="${ALT_NAMES}" ip_sans="127.0.0.1" ttl=875999h)
  echo "$CERT_JSON" | jq -r '.data.certificate' > "${TARGET_SYSTEM}.crt"
  echo "$CERT_JSON" | jq -r '.data.private_key' > "${TARGET_SYSTEM}.key"
}

# Change the CERTIFICATE_DOMAIN variable to match your domain, keep the 'consul.' at the start
CERTIFICATE_DOMAIN="consul.example.com"
setup_pki_engine_for "consul"

ALT_NAMES="*.${CERTIFICATE_DOMAIN},server.${CONSUL_DATACENTRE}.consul,localhost"
generate_certificate_for "consul-servers" "consul"

ALT_NAMES="*.${CERTIFICATE_DOMAIN},localhost"
generate_certificate_for "consul-agents" "consul"

cp consul* ../ansible/

# Change the CERTIFICATE_DOMAIN variable to match your domain, keep the 'vault.' at the start
CERTIFICATE_DOMAIN="vault.example.com"
ALT_NAMES="*.${CERTIFICATE_DOMAIN},localhost"
setup_pki_engine_for "vault"
generate_certificate_for "vault"
cp vault* ../ansible/

kill "$VAULT_SERVER_PID"
