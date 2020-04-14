variable vault_hostname {}
variable consul_hostname {}
variable trusted_external_ips { type = list(string) }

provider azurerm {
  features {}
}

locals {
  vault_proxy_authorized_addresses = jsonencode(concat(["127.0.0.1"], [data.azurerm_subnet.default.address_prefix]))
  consul_retry_join_config = join(" ",
    [
      "provider=azure",
      "tenant_id=${data.azurerm_client_config.current.tenant_id}",
      "subscription_id=${data.azurerm_client_config.current.subscription_id}",
      "resource_group=${data.azurerm_resource_group.default.name}",
      "vm_scale_set=consul"
    ]
  )
}

data azurerm_resource_group default {
  name = "default"
}

data azurerm_virtual_network default {
  name                = "default"
  resource_group_name = data.azurerm_resource_group.default.name
}

data azurerm_subnet default {
  name                 = "default"
  virtual_network_name = data.azurerm_virtual_network.default.name
  resource_group_name  = data.azurerm_resource_group.default.name
}

data azurerm_client_config current {}

data azurerm_image consul {
  name_regex          = "consul-"
  sort_descending     = true
  resource_group_name = data.azurerm_resource_group.default.name
}

data azurerm_image vault {
  name_regex          = "vault-"
  sort_descending     = true
  resource_group_name = data.azurerm_resource_group.default.name
}

resource azurerm_role_definition compute_reader {
  name              = "Compute Reader"
  scope             = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/resourceGroups/${data.azurerm_resource_group.default.name}"
  assignable_scopes = ["/subscriptions/${data.azurerm_client_config.current.subscription_id}/resourceGroups/${data.azurerm_resource_group.default.name}"]

  permissions {
    actions = [
      "Microsoft.Compute/virtualMachineScaleSets/*/read",
      "Microsoft.Compute/virtualMachines/*/read",
      "Microsoft.Network/networkInterfaces/read"
    ]
  }
}

resource azurerm_user_assigned_identity consul {
  name                = "consul"
  resource_group_name = data.azurerm_resource_group.default.name
  location            = data.azurerm_resource_group.default.location
}

resource azurerm_role_assignment consul_compute_reader {
  scope              = data.azurerm_resource_group.default.id
  role_definition_id = azurerm_role_definition.compute_reader.id
  principal_id       = azurerm_user_assigned_identity.consul.principal_id
}

resource azurerm_application_security_group consul {
  name                = "consul"
  resource_group_name = data.azurerm_resource_group.default.name
  location            = data.azurerm_resource_group.default.location
}

resource azurerm_linux_virtual_machine_scale_set consul {
  name                = "consul"
  resource_group_name = data.azurerm_resource_group.default.name
  location            = data.azurerm_resource_group.default.location
  admin_username      = "ubuntu"
  health_probe_id     = azurerm_lb_probe.consul.id
  instances           = 3
  source_image_id     = data.azurerm_image.consul.id
  sku                 = "Standard_B2s"
  upgrade_mode        = "Manual"
  zones               = ["1", "2", "3"]
  zone_balance        = true

  custom_data = base64encode(<<EOF
#!/bin/bash
echo "${local.consul_retry_join_config}" > /etc/consul.d/retry-join-config

if [[ ! -e /etc/consul.d/agent-bootstrap-complete ]]; then
  source /etc/consul.d/agent-bootstrap.sh
fi

systemctl start consul
systemctl enable consul
EOF
  )

  admin_ssh_key {
    public_key = file("~/.ssh/id_rsa.pub")
    username   = "ubuntu"
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.consul.id]
  }

  os_disk {
    caching              = "None"
    storage_account_type = "Standard_LRS"
  }

  network_interface {
    name    = "consul"
    primary = true

    ip_configuration {
      name                                   = "consul"
      primary                                = true
      subnet_id                              = data.azurerm_subnet.default.id
      application_security_group_ids         = [azurerm_application_security_group.consul.id]
      load_balancer_backend_address_pool_ids = [azurerm_lb_backend_address_pool.consul.id]
    }
  }
}

resource azurerm_application_security_group vault {
  name                = "vault"
  resource_group_name = data.azurerm_resource_group.default.name
  location            = data.azurerm_resource_group.default.location
}

resource azurerm_application_security_group haproxy {
  name                = "haproxy"
  resource_group_name = data.azurerm_resource_group.default.name
  location            = data.azurerm_resource_group.default.location
}

resource azurerm_linux_virtual_machine vault {
  count                 = 2
  name                  = "vault-${count.index}"
  resource_group_name   = data.azurerm_resource_group.default.name
  location              = data.azurerm_resource_group.default.location
  admin_username        = "ubuntu"
  network_interface_ids = [azurerm_network_interface.vault.*.id[count.index]]
  source_image_id       = data.azurerm_image.vault.id
  size                  = "Standard_B2s"
  zone                  = count.index + 1

  custom_data = base64encode(<<EOF
#!/bin/bash

current_ip=$(hostname -I | tr -d '[:space:]')
cluster_addr="https://$${current_ip}:8201"
jq --arg cluster_addr $cluster_addr '.cluster_addr = $cluster_addr' /etc/vault.d/vault.json > /etc/vault.d/vault.json.new
mv /etc/vault.d/vault.json.new /etc/vault.d/vault.json

echo "${local.consul_retry_join_config}" > /etc/consul.d/retry-join-config

if [[ ! -e /etc/consul.d/agent-bootstrap-complete ]]; then
  source /etc/consul.d/agent-bootstrap.sh
fi

if [[ ! -e /etc/vault.d/bootstrap-complete ]]; then
  jq '.listener[0].tcp.proxy_protocol_authorized_addrs = ${local.vault_proxy_authorized_addresses}' /etc/vault.d/vault.json > /etc/vault.d/vault.json.new
  jq '.api_addr = "https://${var.vault_hostname}"' /etc/vault.d/vault.json.new > /etc/vault.d/vault.json
  systemctl restart vault
  touch /etc/vault.d/bootstrap-complete
fi
EOF
  )

  admin_ssh_key {
    public_key = file("~/.ssh/id_rsa.pub")
    username   = "ubuntu"
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.consul.id]
  }

  os_disk {
    caching              = "None"
    storage_account_type = "Standard_LRS"
  }
}

resource azurerm_network_interface vault {
  count               = 2
  name                = "vault-${count.index}"
  resource_group_name = data.azurerm_resource_group.default.name
  location            = data.azurerm_resource_group.default.location

  ip_configuration {
    name                          = "config1"
    subnet_id                     = data.azurerm_subnet.default.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource azurerm_network_interface_application_security_group_association vault_consul {
  count                         = 2
  network_interface_id          = azurerm_network_interface.vault.*.id[count.index]
  application_security_group_id = azurerm_application_security_group.consul.id
}

resource azurerm_network_interface_application_security_group_association vault_vault {
  count                         = 2
  network_interface_id          = azurerm_network_interface.vault.*.id[count.index]
  application_security_group_id = azurerm_application_security_group.vault.id
}

resource azurerm_network_interface_application_security_group_association vault_haproxy {
  count                         = 2
  network_interface_id          = azurerm_network_interface.vault.*.id[count.index]
  application_security_group_id = azurerm_application_security_group.haproxy.id
}

resource azurerm_network_interface_backend_address_pool_association vault {
  count                   = 2
  network_interface_id    = azurerm_network_interface.vault.*.id[count.index]
  ip_configuration_name   = "config1"
  backend_address_pool_id = azurerm_lb_backend_address_pool.vault.id
}

resource azurerm_lb vault {
  name                = "vault"
  resource_group_name = data.azurerm_resource_group.default.name
  location            = data.azurerm_resource_group.default.location
  sku                 = "Standard"

  frontend_ip_configuration {
    name                 = "vault"
    public_ip_address_id = azurerm_public_ip.vault.id
  }
}

resource azurerm_public_ip vault {
  name                = "vault"
  resource_group_name = data.azurerm_resource_group.default.name
  location            = data.azurerm_resource_group.default.location
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource azurerm_lb_backend_address_pool consul {
  name                = "consul"
  resource_group_name = data.azurerm_resource_group.default.name
  loadbalancer_id     = azurerm_lb.vault.id
}

resource azurerm_lb_backend_address_pool vault {
  name                = "vault"
  resource_group_name = data.azurerm_resource_group.default.name
  loadbalancer_id     = azurerm_lb.vault.id
}

resource azurerm_lb_rule consul {
  name                           = "consul"
  resource_group_name            = data.azurerm_resource_group.default.name
  loadbalancer_id                = azurerm_lb.vault.id
  frontend_ip_configuration_name = "vault"
  protocol                       = "Tcp"
  frontend_port                  = "8501"
  backend_port                   = "8501"
  backend_address_pool_id        = azurerm_lb_backend_address_pool.consul.id
  probe_id                       = azurerm_lb_probe.consul.id
}

resource azurerm_lb_rule haproxy_stats {
  name                           = "haproxy-stats"
  resource_group_name            = data.azurerm_resource_group.default.name
  loadbalancer_id                = azurerm_lb.vault.id
  frontend_ip_configuration_name = "vault"
  protocol                       = "Tcp"
  frontend_port                  = "80"
  backend_port                   = "80"
  backend_address_pool_id        = azurerm_lb_backend_address_pool.vault.id
  probe_id                       = azurerm_lb_probe.haproxy_stats.id
}

resource azurerm_lb_rule vault {
  name                           = "vault"
  resource_group_name            = data.azurerm_resource_group.default.name
  loadbalancer_id                = azurerm_lb.vault.id
  frontend_ip_configuration_name = "vault"
  protocol                       = "Tcp"
  frontend_port                  = "443"
  backend_port                   = "443"
  backend_address_pool_id        = azurerm_lb_backend_address_pool.vault.id
  probe_id                       = azurerm_lb_probe.vault.id
}

resource azurerm_lb_probe consul {
  name                = "consul"
  resource_group_name = data.azurerm_resource_group.default.name
  loadbalancer_id     = azurerm_lb.vault.id
  protocol            = "Tcp"
  port                = "8501"
}

resource azurerm_lb_probe haproxy_stats {
  name                = "haproxy-stats"
  resource_group_name = data.azurerm_resource_group.default.name
  loadbalancer_id     = azurerm_lb.vault.id
  protocol            = "Tcp"
  port                = "80"
}

resource azurerm_lb_probe vault {
  name                = "vault"
  resource_group_name = data.azurerm_resource_group.default.name
  loadbalancer_id     = azurerm_lb.vault.id
  protocol            = "Tcp"
  port                = "443"
}

resource azurerm_network_security_rule consul_lb_https {
  name                                       = "consul-lb-https"
  resource_group_name                        = data.azurerm_resource_group.default.name
  network_security_group_name                = "default"
  protocol                                   = "Tcp"
  source_port_range                          = "*"
  destination_port_range                     = "8501"
  source_address_prefix                      = "AzureLoadBalancer"
  destination_application_security_group_ids = [azurerm_application_security_group.consul.id]
  access                                     = "Allow"
  priority                                   = "200"
  direction                                  = "Inbound"
}

resource azurerm_network_security_rule haproxy_lb_http {
  name                                       = "haproxy-lb-http"
  resource_group_name                        = data.azurerm_resource_group.default.name
  network_security_group_name                = "default"
  protocol                                   = "Tcp"
  source_port_range                          = "*"
  destination_port_range                     = "80"
  source_address_prefix                      = "AzureLoadBalancer"
  destination_application_security_group_ids = [azurerm_application_security_group.haproxy.id]
  access                                     = "Allow"
  priority                                   = "210"
  direction                                  = "Inbound"
}

resource azurerm_network_security_rule haproxy_lb_https {
  name                                       = "haproxy-lb-https"
  resource_group_name                        = data.azurerm_resource_group.default.name
  network_security_group_name                = "default"
  protocol                                   = "Tcp"
  source_port_range                          = "*"
  destination_port_range                     = "443"
  source_address_prefix                      = "AzureLoadBalancer"
  destination_application_security_group_ids = [azurerm_application_security_group.haproxy.id]
  access                                     = "Allow"
  priority                                   = "220"
  direction                                  = "Inbound"
}

resource azurerm_network_security_rule consul_external_https {
  name                                       = "consul-external-https"
  resource_group_name                        = data.azurerm_resource_group.default.name
  network_security_group_name                = "default"
  protocol                                   = "Tcp"
  source_port_range                          = "*"
  destination_port_range                     = "8501"
  source_address_prefixes                    = var.trusted_external_ips
  destination_application_security_group_ids = [azurerm_application_security_group.consul.id]
  access                                     = "Allow"
  priority                                   = "230"
  direction                                  = "Inbound"
}

resource azurerm_network_security_rule haproxy_external_http {
  name                                       = "haproxy-external-http"
  resource_group_name                        = data.azurerm_resource_group.default.name
  network_security_group_name                = "default"
  protocol                                   = "Tcp"
  source_port_range                          = "*"
  destination_port_range                     = "80"
  source_address_prefixes                    = var.trusted_external_ips
  destination_application_security_group_ids = [azurerm_application_security_group.haproxy.id]
  access                                     = "Allow"
  priority                                   = "240"
  direction                                  = "Inbound"
}

resource azurerm_network_security_rule haproxy_external_https {
  name                                       = "haproxy-external-https"
  resource_group_name                        = data.azurerm_resource_group.default.name
  network_security_group_name                = "default"
  protocol                                   = "Tcp"
  source_port_range                          = "*"
  destination_port_range                     = "443"
  source_address_prefixes                    = var.trusted_external_ips
  destination_application_security_group_ids = [azurerm_application_security_group.haproxy.id]
  access                                     = "Allow"
  priority                                   = "250"
  direction                                  = "Inbound"
}

resource azurerm_network_security_rule consul_internal_rpc {
  name                                       = "consul-internal-rpc"
  resource_group_name                        = data.azurerm_resource_group.default.name
  network_security_group_name                = "default"
  protocol                                   = "Tcp"
  source_port_range                          = "*"
  destination_port_range                     = "8300"
  source_application_security_group_ids      = [azurerm_application_security_group.consul.id]
  destination_application_security_group_ids = [azurerm_application_security_group.consul.id]
  access                                     = "Allow"
  priority                                   = "260"
  direction                                  = "Inbound"
}

resource azurerm_network_security_rule consul_internal_raft {
  name                                       = "consul-internal-raft"
  resource_group_name                        = data.azurerm_resource_group.default.name
  network_security_group_name                = "default"
  protocol                                   = "*"
  source_port_range                          = "*"
  destination_port_range                     = "8301"
  source_application_security_group_ids      = [azurerm_application_security_group.consul.id]
  destination_application_security_group_ids = [azurerm_application_security_group.consul.id]
  access                                     = "Allow"
  priority                                   = "270"
  direction                                  = "Inbound"
}

resource azurerm_network_security_rule consul_internal_https {
  name                                       = "consul-internal-https"
  resource_group_name                        = data.azurerm_resource_group.default.name
  network_security_group_name                = "default"
  protocol                                   = "Tcp"
  source_port_range                          = "*"
  destination_port_range                     = "8501"
  source_application_security_group_ids      = [azurerm_application_security_group.consul.id]
  destination_application_security_group_ids = [azurerm_application_security_group.consul.id]
  access                                     = "Allow"
  priority                                   = "280"
  direction                                  = "Inbound"
}

resource azurerm_network_security_rule vault_external_https {
  name                                       = "vault-external-https"
  resource_group_name                        = data.azurerm_resource_group.default.name
  network_security_group_name                = "default"
  protocol                                   = "Tcp"
  source_port_range                          = "*"
  destination_port_range                     = "8200"
  source_application_security_group_ids      = [azurerm_application_security_group.vault.id]
  destination_application_security_group_ids = [azurerm_application_security_group.vault.id]
  access                                     = "Allow"
  priority                                   = "290"
  direction                                  = "Inbound"
}

resource azurerm_network_security_rule vault_internal_https {
  name                                       = "vault-internal-https"
  resource_group_name                        = data.azurerm_resource_group.default.name
  network_security_group_name                = "default"
  protocol                                   = "Tcp"
  source_port_range                          = "*"
  destination_port_range                     = "8201"
  source_application_security_group_ids      = [azurerm_application_security_group.vault.id]
  destination_application_security_group_ids = [azurerm_application_security_group.vault.id]
  access                                     = "Allow"
  priority                                   = "300"
  direction                                  = "Inbound"
}

resource azurerm_network_security_rule deny_all_consul {
  name                                       = "deny-all-consul"
  resource_group_name                        = data.azurerm_resource_group.default.name
  network_security_group_name                = "default"
  protocol                                   = "*"
  source_port_range                          = "*"
  destination_port_range                     = "*"
  source_address_prefix                      = "*"
  destination_application_security_group_ids = [azurerm_application_security_group.consul.id]
  access                                     = "Deny"
  priority                                   = "310"
  direction                                  = "Inbound"
}

resource azurerm_network_security_rule deny_all_vault {
  name                                       = "deny-all-vault"
  resource_group_name                        = data.azurerm_resource_group.default.name
  network_security_group_name                = "default"
  protocol                                   = "*"
  source_port_range                          = "*"
  destination_port_range                     = "*"
  source_address_prefix                      = "*"
  destination_application_security_group_ids = [azurerm_application_security_group.vault.id]
  access                                     = "Deny"
  priority                                   = "320"
  direction                                  = "Inbound"
}

resource azurerm_network_security_rule deny_all_haproxy {
  name                                       = "deny-all-haproxy"
  resource_group_name                        = data.azurerm_resource_group.default.name
  network_security_group_name                = "default"
  protocol                                   = "*"
  source_port_range                          = "*"
  destination_port_range                     = "*"
  source_address_prefix                      = "*"
  destination_application_security_group_ids = [azurerm_application_security_group.haproxy.id]
  access                                     = "Deny"
  priority                                   = "330"
  direction                                  = "Inbound"
}

resource null_resource consul_acl_bootstrap {
  triggers = {
    scale_set_id = azurerm_linux_virtual_machine_scale_set.consul.id
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      CONSUL_CACERT          = abspath("${path.module}/../../ansible/consul-ca.crt")
      CONSUL_CLIENT_CERT     = abspath("${path.module}/../../ansible/consul.crt")
      CONSUL_CLIENT_KEY      = abspath("${path.module}/../../ansible/consul.key")
      CONSUL_HTTP_ADDR       = "https://${var.consul_hostname}:8501"
      CONSUL_TLS_SERVER_NAME = "consul"
    }

    command = <<EOF
success="1"
consul_bootstrap_output=""
while [[ "$success" -gt "0" ]]; do
  consul_bootstrap_output="$(consul acl bootstrap)"
  success="$?"
  sleep 5
done
echo "Bootstrap successful."
echo -e "$consul_bootstrap_output" | grep -i 'SecretID' | awk '{ print $2 }' > master-token
consul acl policy create -token-file master-token -name "agent" -rules @${abspath("${path.module}/../../ansible/roles/consul/files/policies/agent.hcl")} > /dev/null
consul acl token create -token-file master-token -policy-name "agent" -secret $(cat ${abspath("${path.module}/../../ansible/roles/consul/files/tokens/agent")}) > /dev/null
consul acl policy create -token-file master-token -name "haproxy" -rules @${abspath("${path.module}/../../ansible/roles/consul/files/policies/haproxy.hcl")} > /dev/null
consul acl token create -token-file master-token -policy-name "haproxy" -secret $(cat ${abspath("${path.module}/../../ansible/roles/consul/files/tokens/haproxy")}) > /dev/null
consul acl policy create -token-file master-token -name "vault" -rules @${abspath("${path.module}/../../ansible/roles/consul/files/policies/vault.hcl")} > /dev/null
consul acl token create -token-file master-token -policy-name "vault" -secret $(cat ${abspath("${path.module}/../../ansible/roles/consul/files/tokens/vault")}) > /dev/null
EOF
  }
}
