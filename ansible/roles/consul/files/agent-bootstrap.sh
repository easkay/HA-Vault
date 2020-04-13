#!/bin/bash

CONSUL_OPTIONS="-ca-file=/etc/consul.d/consul-ca.crt -client-cert=/etc/consul.d/consul.crt -client-key=/etc/consul.d/consul.key -http-addr=https://127.0.0.1:8501 -tls-server-name=consul"

systemctl stop consul
echo > /var/log/consul/consul.log
AGENT_MASTER_TOKEN=$(uuidgen | tr -d '[:space:]')
RETRY_JOIN_CONFIG=$(cat /etc/consul.d/retry-join-config)
rm -f /etc/consul.d/retry-join-config
jq -r --arg agent_master_token "$AGENT_MASTER_TOKEN" '.acl.tokens.agent_master = $agent_master_token' /etc/consul.d/consul.json > /etc/consul.d/consul.json.new
jq -r --arg retry_join_config "$RETRY_JOIN_CONFIG" '.retry_join = [$retry_join_config]' /etc/consul.d/consul.json.new > /etc/consul.d/consul.json
rm -f /etc/consul.d/consul.json.new
systemctl start consul
sleep 15
consul acl set-agent-token $CONSUL_OPTIONS -token=$AGENT_MASTER_TOKEN default "$(cat /etc/consul.d/agent-token)"
consul acl set-agent-token $CONSUL_OPTIONS -token=$AGENT_MASTER_TOKEN agent "$(cat /etc/consul.d/agent-token)"
rm -f /etc/consul.d/agent-token
jq -r 'del(.encrypt) | del(.acl.tokens)' /etc/consul.d/consul.json > /etc/consul.d/consul.json.new
mv /etc/consul.d/consul.json.new /etc/consul.d/consul.json
systemctl restart consul
touch /etc/consul.d/agent-bootstrap-complete
