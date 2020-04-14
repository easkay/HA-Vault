variable vault_hostname {}
variable consul_hostname {}
variable trusted_external_ips { type = list(string) }
variable credentials {}
variable project {}
variable region {}

provider google {
  credentials = var.credentials
  project     = var.project
  region      = var.region
}

locals {
  vault_proxy_authorized_addresses = jsonencode(concat(["127.0.0.1"], [data.google_compute_subnetwork.default.ip_cidr_range]))
  consul_retry_join_config         = "provider=gce tag_value=consul-${data.google_client_config.current.region}"
}

data google_client_config current {}

data google_compute_network default {
  name = "default"
}

data google_compute_subnetwork default {
  name   = "default"
  region = data.google_client_config.current.region
}

data google_compute_image consul {
  family = "consul"
}

data google_compute_image vault {
  family = "vault"
}

resource google_project_iam_custom_role get_compute_instances {
  role_id = "getComputeInstances"
  title   = "Get Compute Instances"

  permissions = [
    "compute.instanceGroupManagers.get",
    "compute.instanceGroupManagers.list",
    "compute.instanceGroups.get",
    "compute.instanceGroups.list",
    "compute.instances.get",
    "compute.instances.list",
    "compute.zones.list",
    "compute.zones.get"
  ]
}

resource google_project_iam_binding consul_get_compute_instances {
  members = ["serviceAccount:${google_service_account.consul.email}"]
  role    = "projects/${data.google_client_config.current.project}/roles/${google_project_iam_custom_role.get_compute_instances.role_id}"
}

resource google_service_account consul {
  account_id = "consul"
}

resource google_compute_health_check consul_autoheal {
  name               = "consul-autoheal"
  timeout_sec        = 30
  check_interval_sec = 30

  tcp_health_check {
    port = 8501
  }
}

resource google_compute_instance_template consul {
  name_prefix  = "consul"
  machine_type = "n1-standard-1"
  tags         = ["consul-${data.google_client_config.current.region}", "consul"]

  metadata_startup_script = <<EOF
#!/bin/bash
echo "${local.consul_retry_join_config}" > /etc/consul.d/retry-join-config

if [[ ! -e /etc/consul.d/agent-bootstrap-complete ]]; then
  source /etc/consul.d/agent-bootstrap.sh
fi

systemctl start consul
systemctl enable consul
EOF

  disk {
    source_image = data.google_compute_image.consul.self_link
  }

  network_interface {
    subnetwork = data.google_compute_subnetwork.default.self_link

    access_config {
      network_tier = "STANDARD"
    }
  }

  service_account {
    email  = google_service_account.consul.email
    scopes = ["compute-ro"]
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource google_compute_region_instance_group_manager consul {
  base_instance_name = "consul"
  name               = "consul"
  region             = data.google_client_config.current.region
  target_size        = 3
  target_pools       = [google_compute_target_pool.consul.self_link]

  version {
    name              = "consul"
    instance_template = google_compute_instance_template.consul.self_link
  }

  # Needs global health check
  # auto_healing_policies {
  #   health_check      = google_compute_region_health_check.consul_autoheal.self_link
  #   initial_delay_sec = 300
  # }
}

resource google_compute_target_pool consul {
  name = "consul"
}

resource google_compute_forwarding_rule consul {
  name                  = "consul"
  ip_protocol           = "TCP"
  load_balancing_scheme = "EXTERNAL"
  port_range            = "8501"
  target                = google_compute_target_pool.consul.self_link
  network_tier          = "STANDARD"
}

resource google_compute_instance vault {
  count        = 2
  name         = "vault-${count.index}"
  machine_type = "n1-standard-1"
  tags         = ["consul-${data.google_client_config.current.region}", "vault", "haproxy"]
  zone         = "${data.google_client_config.current.region}-a"
  hostname     = "vault-${count.index}.${var.vault_hostname}"

  metadata_startup_script = <<EOF
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

  boot_disk {
    initialize_params {
      image = data.google_compute_image.vault.self_link
    }
  }

  network_interface {
    subnetwork = data.google_compute_subnetwork.default.self_link

    access_config {
      network_tier = "STANDARD"
    }
  }

  service_account {
    email  = google_service_account.consul.email
    scopes = ["compute-ro"]
  }
}

resource google_compute_target_pool vault {
  name          = "vault"
  instances     = google_compute_instance.vault.*.self_link
  health_checks = [google_compute_http_health_check.vault.self_link]
}

resource google_compute_http_health_check vault {
  name         = "vault"
  request_path = "/haproxy-stats"
}

resource google_compute_forwarding_rule haproxy_stats {
  name                  = "haproxy-stats"
  ip_protocol           = "TCP"
  load_balancing_scheme = "EXTERNAL"
  port_range            = "80"
  target                = google_compute_target_pool.vault.self_link
  network_tier          = "STANDARD"
}

resource google_compute_forwarding_rule vault_https {
  name                  = "vault-https"
  ip_protocol           = "TCP"
  load_balancing_scheme = "EXTERNAL"
  port_range            = "443"
  target                = google_compute_target_pool.vault.self_link
  network_tier          = "STANDARD"
}

resource null_resource consul_acl_bootstrap {
  triggers = {
    instance_group_id = google_compute_region_instance_group_manager.consul.self_link
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

resource google_compute_firewall consul_https_external {
  name          = "consul-https-external"
  network       = data.google_compute_network.default.self_link
  priority      = 800
  source_ranges = var.trusted_external_ips
  target_tags   = ["consul"]

  allow {
    protocol = "tcp"
    ports    = ["8501"]
  }
}

resource google_compute_firewall haproxy_http_https_external {
  name          = "haproxy-http-https-external"
  network       = data.google_compute_network.default.self_link
  priority      = 810
  source_ranges = var.trusted_external_ips
  target_tags   = ["haproxy"]

  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }
}

resource google_compute_firewall consul_internal_rpc {
  name        = "consul-internal-rpc"
  network     = data.google_compute_network.default.self_link
  priority    = 820
  source_tags = ["consul"]
  target_tags = ["consul"]

  allow {
    ports    = ["8300"]
    protocol = "tcp"
  }

  allow {
    ports    = ["8300"]
    protocol = "udp"
  }
}

resource google_compute_firewall consul_lan_serf {
  name        = "consul-lan-serf"
  network     = data.google_compute_network.default.self_link
  priority    = 830
  source_tags = ["consul"]
  target_tags = ["consul"]

  allow {
    ports    = ["8301"]
    protocol = "tcp"
  }

  allow {
    ports    = ["8301"]
    protocol = "udp"
  }
}

resource google_compute_firewall consul_https_internal {
  name        = "consul-https-internal"
  network     = data.google_compute_network.default.self_link
  priority    = 840
  source_tags = ["consul"]
  target_tags = ["consul"]

  allow {
    ports    = ["8501"]
    protocol = "tcp"
  }
}

resource google_compute_firewall consul_https_vault {
  name        = "consul-https-vault"
  network     = data.google_compute_network.default.self_link
  priority    = 850
  source_tags = ["vault"]
  target_tags = ["consul"]

  allow {
    ports    = ["8501"]
    protocol = "tcp"
  }
}

resource google_compute_firewall consul_https_haproxy {
  name        = "consul-https-haproxy"
  network     = data.google_compute_network.default.self_link
  priority    = 860
  source_tags = ["haproxy"]
  target_tags = ["consul"]

  allow {
    ports    = ["8501"]
    protocol = "tcp"
  }
}

resource google_compute_firewall vault_https_internal {
  name        = "vault-https-internal"
  network     = data.google_compute_network.default.self_link
  priority    = 870
  source_tags = ["vault"]
  target_tags = ["vault"]

  allow {
    ports    = ["8200"]
    protocol = "tcp"
  }
}

resource google_compute_firewall vault_https_haproxy {
  name        = "vault-https-haproxy"
  network     = data.google_compute_network.default.self_link
  priority    = 880
  source_tags = ["haproxy"]
  target_tags = ["vault"]

  allow {
    ports    = ["8200"]
    protocol = "tcp"
  }
}

resource google_compute_firewall vault_cluster_internal {
  name        = "vault-cluster-internal"
  network     = data.google_compute_network.default.self_link
  priority    = 890
  source_tags = ["vault"]
  target_tags = ["vault"]

  allow {
    ports    = ["8201"]
    protocol = "tcp"
  }
}

resource google_compute_firewall consul_deny_all {
  name        = "consul-deny-all"
  network     = data.google_compute_network.default.self_link
  priority    = 900
  target_tags = ["consul"]

  deny {
    protocol = "all"
  }
}

resource google_compute_firewall vault_deny_all {
  name        = "vault-deny-all"
  network     = data.google_compute_network.default.self_link
  priority    = 910
  target_tags = ["vault"]

  deny {
    protocol = "all"
  }
}

resource google_compute_firewall haproxy_deny_all {
  name        = "haproxy-deny-all"
  network     = data.google_compute_network.default.self_link
  priority    = 920
  target_tags = ["haproxy"]

  deny {
    protocol = "all"
  }
}
