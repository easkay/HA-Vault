variable vault_hostname {}
variable consul_hostname {}
variable trusted_external_ips { type = list(string) }

provider aws {
  region = "eu-west-2"
}

locals {
  vault_proxy_authorized_addresses = jsonencode(concat(["127.0.0.1"], tolist(data.aws_subnet.default.*.cidr_block)))
  consul_retry_join_config         = "provider=aws tag_key=consul_cluster tag_value=eu-west-2"
}

data aws_vpc default {
  default = true
}

data aws_ami consul {
  owners      = ["self"]
  most_recent = true

  filter {
    name   = "tag:system"
    values = ["consul"]
  }

  filter {
    name   = "name"
    values = ["consul-*"]
  }
}

data aws_ami vault {
  owners      = ["self"]
  most_recent = true

  filter {
    name   = "tag:system"
    values = ["vault"]
  }

  filter {
    name   = "name"
    values = ["vault-*"]
  }
}

resource aws_iam_policy describe-instances {
  description = "A policy to permit DescribeInstances, used particularly for Consul cloud auto-join."
  name        = "EC2DescribeInstances"
  policy      = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DescribeAutoScalingGroups",
      "Effect": "Allow",
      "Action": "autoscaling:DescribeAutoScalingGroups",
      "Resource": "*"
    },
    {
      "Sid": "DescribeTags",
      "Effect": "Allow",
      "Action": "ec2:DescribeTags",
      "Resource": "*"
    },
    {
      "Sid": "DescribeInstances",
      "Effect": "Allow",
      "Action": "ec2:DescribeInstances",
      "Resource": "*"
    }
  ]
}
EOF
}

resource aws_iam_role describe-instances {
  name = "EC2DescribeInstances"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

resource aws_iam_role_policy_attachment describe-instances {
  role       = aws_iam_role.describe-instances.name
  policy_arn = aws_iam_policy.describe-instances.arn
}

resource aws_iam_role_policy_attachment ssm {
  role       = aws_iam_role.describe-instances.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource aws_iam_instance_profile describe-instances {
  name = "EC2DescribeInstances"
  role = aws_iam_role.describe-instances.name
}

resource aws_launch_configuration consul {
  depends_on = [aws_iam_role_policy_attachment.describe-instances]

  name_prefix                 = "consul"
  image_id                    = data.aws_ami.consul.image_id
  instance_type               = "t2.medium"
  iam_instance_profile        = aws_iam_instance_profile.describe-instances.name
  security_groups             = [aws_security_group.consul.id]
  associate_public_ip_address = true
  ebs_optimized               = false
  key_name                    = "id_rsa"

  user_data = <<EOF
#!/bin/bash
instanceID=$(curl http://169.254.169.254/latest/meta-data/instance-id)
hostname="consul-$${instanceID#*-}"

hostnamectl set-hostname $hostname
cat << EOL >> /etc/hosts
127.0.0.1 $hostname
EOL

echo "${local.consul_retry_join_config}" > /etc/consul.d/retry-join-config

if [[ ! -e /etc/consul.d/agent-bootstrap-complete ]]; then
  source /etc/consul.d/agent-bootstrap.sh
fi

systemctl start consul
systemctl enable consul
EOF

  root_block_device {
    volume_type           = "standard"
    volume_size           = "16"
    delete_on_termination = true
  }

  lifecycle {
    create_before_destroy = true
  }
}

data aws_subnet_ids default {
  vpc_id = data.aws_vpc.default.id
}

data aws_subnet default {
  count = length(data.aws_subnet_ids.default.ids)
  id    = tolist(data.aws_subnet_ids.default.ids)[count.index]
}

resource aws_autoscaling_group consul {
  name_prefix               = "consul"
  max_size                  = 5
  min_size                  = 3
  desired_capacity          = 3
  default_cooldown          = 120
  launch_configuration      = aws_launch_configuration.consul.name
  vpc_zone_identifier       = data.aws_subnet_ids.default.ids
  target_group_arns         = [aws_lb_target_group.consul.arn]
  termination_policies      = ["OldestLaunchConfiguration", "OldestInstance"]
  wait_for_capacity_timeout = 0

  tag {
    key                 = "consul_cluster"
    value               = "eu-west-2"
    propagate_at_launch = true
  }
}

resource aws_instance vault {
  count                       = 2
  ami                         = data.aws_ami.vault.image_id
  instance_type               = "t2.small"
  iam_instance_profile        = aws_iam_instance_profile.describe-instances.name
  vpc_security_group_ids      = [aws_security_group.consul.id, aws_security_group.vault.id, aws_security_group.haproxy.id]
  associate_public_ip_address = true
  ebs_optimized               = false
  key_name                    = "id_rsa"
  subnet_id                   = element(tolist(data.aws_subnet_ids.default.ids), count.index)

  user_data = <<EOF
#!/bin/bash

hostname="$(fetch-tag Name)"
hostnamectl set-hostname $hostname
cat << EOL >> /etc/hosts
127.0.0.1 $hostname
EOL

current_ip=$(ec2metadata --local-ipv4)
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

  root_block_device {
    volume_type           = "standard"
    volume_size           = "16"
    delete_on_termination = true
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "vault-${count.index}"
  }
}

resource aws_lb vault {
  name                             = "vault"
  internal                         = false
  load_balancer_type               = "network"
  subnets                          = data.aws_subnet_ids.default.ids
  enable_deletion_protection       = false
  enable_cross_zone_load_balancing = true
}

resource aws_lb_listener vault_stats {
  load_balancer_arn = aws_lb.vault.arn
  port              = "80"
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.vault_stats.arn
  }
}

resource aws_lb_listener vault {
  load_balancer_arn = aws_lb.vault.arn
  port              = "443"
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.vault.arn
  }
}

resource aws_lb_listener consul {
  load_balancer_arn = aws_lb.vault.arn
  port              = "8501"
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.consul.arn
  }
}

resource aws_lb_target_group vault_stats {
  name                 = "vault-stats"
  port                 = 80
  protocol             = "TCP"
  target_type          = "instance"
  vpc_id               = data.aws_vpc.default.id
  deregistration_delay = 15
  proxy_protocol_v2    = true

  stickiness {
    enabled = false
    type    = "lb_cookie"
  }

  health_check {
    protocol = "TCP"
  }
}

resource aws_lb_target_group_attachment vault_stats {
  count            = length(aws_instance.vault.*.id)
  target_group_arn = aws_lb_target_group.vault_stats.arn
  target_id        = aws_instance.vault.*.id[count.index]
}

resource aws_lb_target_group vault {
  name                 = "vault"
  port                 = 443
  protocol             = "TCP"
  target_type          = "instance"
  vpc_id               = data.aws_vpc.default.id
  deregistration_delay = 15
  proxy_protocol_v2    = true

  health_check {
    protocol = "TCP"
  }
}

resource aws_lb_target_group_attachment vault {
  count            = length(aws_instance.vault.*.id)
  target_group_arn = aws_lb_target_group.vault.arn
  target_id        = aws_instance.vault.*.id[count.index]
}

resource aws_lb_target_group consul {
  name                 = "consul"
  port                 = 8501
  protocol             = "TCP"
  target_type          = "instance"
  vpc_id               = data.aws_vpc.default.id
  deregistration_delay = 15
  proxy_protocol_v2    = false

  stickiness {
    enabled = false
    type    = "lb_cookie"
  }

  health_check {
    protocol = "TCP"
  }
}

resource aws_security_group consul {
  name        = "consul"
  description = "Consul security rules."
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "Consul internal RPC (TCP)"
    from_port   = 8300
    to_port     = 8300
    protocol    = "tcp"
    self        = true
  }

  ingress {
    description = "Consul internal RPC (UDP)"
    from_port   = 8300
    to_port     = 8300
    protocol    = "udp"
    self        = true
  }

  ingress {
    description = "Consul LAN SERF (TCP)"
    from_port   = 8301
    to_port     = 8301
    protocol    = "tcp"
    self        = true
  }

  ingress {
    description = "Consul LAN SERF (UDP)"
    from_port   = 8301
    to_port     = 8301
    protocol    = "udp"
    self        = true
  }

  ingress {
    description = "Consul HTTPS (external)"
    from_port   = 8501
    to_port     = 8501
    protocol    = "tcp"
    cidr_blocks = var.trusted_external_ips
  }

  ingress {
    description = "Consul HTTPS (internal)"
    from_port   = 8501
    to_port     = 8501
    protocol    = "tcp"
    self        = true
  }

  ingress {
    description     = "Consul HTTPS (Vault)"
    from_port       = 8501
    to_port         = 8501
    protocol        = "tcp"
    security_groups = [aws_security_group.vault.id]
  }

  ingress {
    description     = "Consul HTTPS (HAProxy)"
    from_port       = 8501
    to_port         = 8501
    protocol        = "tcp"
    security_groups = [aws_security_group.haproxy.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "consul"
  }
}

resource aws_security_group vault {
  name        = "vault"
  description = "Vault security rules."
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "Vault HTTPS (internal)"
    from_port   = 8200
    to_port     = 8200
    protocol    = "tcp"
    self        = true
  }

  ingress {
    description     = "Vault HTTPS (HAProxy)"
    from_port       = 8200
    to_port         = 8200
    protocol        = "tcp"
    security_groups = [aws_security_group.haproxy.id]
  }

  ingress {
    description = "Vault Cluster (internal)"
    from_port   = 8201
    to_port     = 8201
    protocol    = "tcp"
    self        = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "vault"
  }
}

resource aws_security_group haproxy {
  name        = "haproxy"
  description = "HAProxy security rules."
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "HAProxy stats HTTP (external)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = var.trusted_external_ips
  }

  ingress {
    description = "HAProxy Vault HTTPS (external)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.trusted_external_ips
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "haproxy"
  }
}

resource null_resource consul_acl_bootstrap {
  triggers = {
    asg_id = aws_autoscaling_group.consul.id
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      CONSUL_CACERT      = abspath("${path.module}/../../ansible/consul-ca.crt")
      CONSUL_CLIENT_CERT = abspath("${path.module}/../../ansible/consul.crt")
      CONSUL_CLIENT_KEY  = abspath("${path.module}/../../ansible/consul.key")
      CONSUL_HTTP_ADDR   = "https://${var.consul_hostname}:8501"
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
