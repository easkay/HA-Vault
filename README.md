# Production-ish Vault installation with a Consul cluster (storage)

_NOTE_: This setup does not ship ready out-of-the-box, there are some tweaks the end user should do.

## Super-quick getting started (try it out)

This repo assumes you're running on Linux or macOS.

Ensure you have Terraform 0.12, Packer 1.5, Vault 1.4, and ansible 2.8 (min) installed.
This repo assumes some prior knowledge and experience with Vault, Terraform, Packer, and at least one of the cloud providers mentioned.

### Common setup

1. Replace any instances of `example.com` in the `tls-bootstrap/bootstrap.sh` with a domain that you control.
1. Replace any instances of `example.com` in the `ansible/group_vars/example.yml` file with the same domain as the previous step.
1. `cd` into the `ansible` folder and run the following to create Consul tokens for the necessary use cases:
    ```
    uuidgen | tr '[:upper:]' '[:lower:]' > roles/consul/files/tokens/agent
    uuidgen | tr '[:upper:]' '[:lower:]' > roles/consul/files/tokens/haproxy
    uuidgen | tr '[:upper:]' '[:lower:]' > roles/consul/files/tokens/vault
    ```
1. `cd` into the `tls-bootstrap` folder, run `./bootstrap.sh`.

Pick a cloud provider - AWS, GCP, or Azure and setup the infrastructure as follows.
It's recommended to have a console for your chosen provider open and available, having logged in.

### AWS

1. Ensure you have a default VPC that has a minimum of 2 subnets and outbound internet access.
    If you don't have one or don't want one, adjust the Packer templates and Terraform to use a different pre-configured VPC.
1. Adjust the Packer and Terrafom variables.
    1. Check the `aws/packer/example.vars` file and supply credentials and a region.
    1. Check the `aws/terraform/example.tfvars` file and adjust the hostnames and trusted external IPs to fit your setup. It's recommended to add the outbound IP of your machine to this list. _NOTE_: AWS requires that these addresses be in CIDR format.
1. Build the images with Packer.
    1. `cd` into the `aws/packer` folder, run
        ```
        packer build --var-file example.vars consul.json
        packer build --var-file example.vars vault.json
        ```
1. Run the Terraform.
    1. `cd` into the `aws/terraform` folder, run `terraform init ; terraform apply --var-file example.tfvars` and if the plan looks good, approve it.
    1. **While Terraform is running**, setup the domain configured in `aws/terraform/example.tfvars` to point at the AWS ELB. This can be done with a CNAME record in your DNS zone, or by resolving the DNS record (`dig <hostname>`) and editing the hosts file as follows. If the `dig` command doesn't produce IPs for the ELB, ensure it's finished provisioning and retry.
        ```
        <ip_1> vault-0.vault.example.com vault-1.vault.example.com vault.example.com consul.example.com
        <ip_2> vault-0.vault.example.com vault-1.vault.example.com vault.example.com consul.example.com
        <ip_3> vault-0.vault.example.com vault-1.vault.example.com vault.example.com consul.example.com
        ```
    1. If the Terraform apply step hangs on provisioning `null_resource.consul_acl_bootstrap`, check that Consul is responding at `consul.<your_domain>:8501`.
    1. If you receive an error similar to `Failed to create new policy: Unexpected response code: 500 (<specific error message>)`, the situation can be recovered by locating the `null_resource consul_acl_bootstrap` resource and commenting all lines of the `command` _except_ those which start with `consul acl policy` or `consul acl token`. Terraform should then be re-run.

### GCP

1. Ensure you have a default VPC (named 'default') with a subnet (named 'default') that has outbound internet access.
    If you don't have one or don't want one, adjust the Packer templates and Terraform to look for a different pre-configured VPC.
1. Adjust the Packer and Terrafom variables.
    1. Check the `gcp/packer/example.vars` file and supply credentials and a project ID.
    1. Check the `gcp/terraform/example.tfvars` file and supply credentials and adjust the hostnames and trusted external IPs to fit your setup. It's recommended to add the outbound IP of your machine to this list.
1. Build the images with Packer.
    1. `cd` into the `gcp/packer` folder, run
        ```
        packer build --var-file example.vars consul.json
        packer build --var-file example.vars vault.json
        ```
1. Run the Terraform.
    1. `cd` into the `gcp/terraform` folder, run `terraform init ; terraform apply --var-file example.tfvars` and if the plan looks good, approve it.
    1. **While Terraform is running**, setup the domain configured in `gcp/terraform/example.tfvars` to point at the Load Balancer frontends. This can be done with A records in your DNS zone, or by editing the hosts file:
        ```
        <consul_ip> consul.example.com
        <vault_ip> vault-0.vault.example.com vault-1.vault.example.com vault.example.com
        ```
    1. If the Terraform apply step hangs on provisioning `null_resource.consul_acl_bootstrap`, check that Consul is responding at `consul.<your_domain>:8501`.
    1. If you receive an error similar to `Failed to create new policy: Unexpected response code: 500 (<specific error message>)`, the situation can be recovered by locating the `null_resource consul_acl_bootstrap` resource and commenting all lines of the `command` _except_ those which start with `consul acl policy` or `consul acl token`. Terraform should then be re-run.

### Azure

1. Ensure you have a virtual network setup that has outbound internet access with a Network Security Group named 'default' attached to the relevant subnet.
    1. Create a new resource group, called 'default'.
    1. Create a new virtual network, called 'default' with whatever IP space fits your needs.
    1. Create a new network security group, called 'default' and associate it with the subnet in the virtual network.
1. Adjust the Packer and Terrafom variables.
    1. Check the `azure/packer/example.vars` file and supply a subscription ID, a resource group name, and a region.
    1. Check the `azure/terraform/example.tfvars` file and adjust the hostnames and trusted external IPs to fit your setup.
1. Login to the azure CLI if not already, and select the appropriate subscription with `az account set -s <subscription name or ID>`.
1. Build the images with Packer.
    1. `cd` into the `azure/packer` folder, run
        ```
        packer build --var-file example.vars consul.json
        packer build --var-file example.vars vault.json
        ```
    1. If you run into issues authenticating with AzureAD, service principal authentication can be used instead. See [the packer docs](https://packer.io/docs/builders/azure-arm.html#service-principal).
1. Run the Terraform.
    1. `cd` into the `azure/terraform` folder, run `terraform init ; terraform apply --var-file example.tfvars` and if the plan looks good, approve it.
    1. **While Terraform is running**, setup the domain configured in `azure/terraform/example.tfvars` to point at the Load Balancer public IP. This can be done with an A record in your DNS zone, or by editing the hosts file:
        ```
        <public_ip> vault-0.vault.example.com vault-1.vault.example.com vault.example.com consul.example.com
        ```
    1. You may receive an error relating to HealthProbes when creating the scale set for Consul, in this case, re-attempt the running of Terraform.
    1. If you receive an error similar to `Failed to create new policy: Unexpected response code: 500 (<specific error message>)`, the situation can be recovered by locating the `null_resource consul_acl_bootstrap` resource and commenting all lines of the `command` _except_ those which start with `consul acl policy` or `consul acl token`. Terraform should then be re-run.

### Testing and Usage

1. Prepare a client certificate for use with Consul.
    1. `cd` into the `ansible` folder, run `openssl pkcs12 -export -in consul.crt -inkey consul.key -out consul.p12` and enter a password when prompted.
    1. Import this certificate into your browser of choice.
1. Try to access Consul by browsing to `https://consul.<your_domain>:8501/ui`, select the certificate when prompted.
1. Click on the `ACL` navbar item.
1. Find the master token created during bootstrap and supply it to the UI, it should be in a file at `<cloud_provider>/terraform/master-token`.
1. Try to access the HAProxy stats page for vault by visiting `http://vault.<your_domain>/haproxy-stats` or `http://<stats_ip>/haproxy-stats` if running on GCP.
1. Initialise Vault and unseal if you wish to experiment further.
    1. `cd` into the `ansible` folder, and setup some useful environment variables.
        ```
        export VAULT_ADDR=https://vault-0.vault.<your_domain>
        export VAULT_CACERT="$(pwd)/vault-ca.crt"
        ```
    1. Run `vault operator init`.
    1. Copy the unseal keys and root token from the output and paste them into a text editor.
    1. Unseal the specific Vault node by running the following `vault operator unseal` and supplying an unseal key when prompted. Repeat this process until the node is unsealed.
    1. Once enough keys have been entered (3 by default), refresh the HAProxy stats page and look for the server that was just unsealed (vault-0) - it should be green at the bottom.

## Getting started (more in-depth)

### Terraform

The Terraform config in this repo uses the local filesystem for state storage instead of remote state.
It is highly recommended to use a remote storage mechanism for Terraform's state.

Additionally, there are no version pins for any of the providers and it's recommended that you set some.


### Network

It's assumed that a network and subnet are available in which to setup the cluster, please adjust the automation accordingly.


### Variables (ansible)

Most variables are already setup with sensible values, but secrets or sensitive variables should be set per installation along with any other installation-specific variables.
The `example.yml` group variables are not stored securely for the purposes of enabling easy experimentation with this setup.
Of course for a proper deployment, these secrets should be appropriately protected using something such as ansible-vault or by not committing them at all.

_NOTE_: Special remarks about Consul tokens are made further on, though they can be configured through variables.

#### Consul role

```
consul_user_password_hash - The password hash to set for the Consul system user

consul_gossip_encryption_key - The encryption key used to secure Gossip traffic between Consul nodes, generated with `consul keygen`
```

#### HAProxy-consul-template role

```
consul_template_user_password_hash - The password hash to set for the consul-template system user

vault_lb_hostname - The external hostname used to access the load-balanced Vault endpoint.
```

#### Vault role

```
vault_user_password_hash - The password hash to set for the Vault system user
```

### Variables (terraform)

There is only a handful of variables needed by Terraform, each of which should be tweaked for your needs:
```
vault_hostname - The hostname which will be used to access Vault's load-balanced endpoint.

consul_hostname - The hostname which will be used to access Consul's load-balanced endpoint.

trusted_external_ips - The external IPs to whitelist when configuring external access to Vault and Consul.

consul_retry_join_config - This should not require adjustment unless the cloud auto-join tag or value is changed.
```

Some variables are provider-specific, such as GCP:

```
credentials - The path on disk of a credentials file for Terraform to use.

project - The ID of the project to provision resources in.

region - The region in which to provision resources.
```

### Tokens

Consul tokens are required for the Consul agent, for consul-template, and for Vault.
The `SecretID` values for each token are set in advance so that the machines can boot and automatically be able to perform their function without extra setup.
These are configured through variables in Ansible, which by default look for the tokens on the filesystem using the `lookup` plugin.
You should populate these tokens with your own values, which must be UUIDs, and can be supplied through files or by setting the ansible variables explicitly.
_NOTE_: If you choose to use ansible variables instead of files, the ACL bootstrap process in Terraform will need to be adjusted to remove the creation of Consul tokens.

The relevant ansible variables are as follows:
```
consul_agent_acl_token - The token for the Consul agent to use, expects a corresponding file in `ansible/roles/consul/files/tokens/agent`

consul_default_acl_token - The default token used by the Consul agent, expects a corresponding file in `ansible/roles/consul/files/tokens/agent`

consul_template_consul_token - The token used by consul-template to obtain node data about vault, expects a corresponding file in `ansible/roles/consul/files/tokens/haproxy`

vault_consul_acl_token - The token used by Vault to access Consul's KV store, expects a corresponding file in `ansible/roles/consul/files/tokens/vault`
```

### Certificates

Certificates are used to secure traffic from Consul and Vault (TLS server certificates) as well as to Consul (TLS client certificates).
You should generate your own keys and certificates signed by a CA you trust.
Specific recommendations about TLS are in the Design section and a script is provided in `tls-bootstrap` to get things started.
_NOTE_: Some values (particularly CNs and SANs) will need to be adjusted depending on hostnames in use.
Particular attention should be paid to the hostnames on the certificate to ensure that communication isn't blocked.
Consul expects a name of `consul` to be present within the Consul server and client certificates by default.

Ansible and Terraform expect the following files to be available at the root of the `ansible` folder:

* consul.crt - The certificate file (optionally containing the issuing CA's certificate) to use for Consul server and client authentication.
* consul-ca.crt - The certificate file of the CA that signs the certificate in `consul.crt`.
* consul.key - The private key file to use for Consul server and client authentication.
* vault.crt - The certificate file (optionally containing the issuing CA's certificate) to use for Vault server authentication.
* vault-ca.crt - The certificate file of the CA that signs the certificate in `vault.crt`.
* vault.key - The private key file to use for Vault server authentication.

### DNS

Hostnames are only needed in a few places, and should be adjusted before provisioning.
See
* `haproxy-consul-template` ansible role, defaults
* `vault_hostname` variable in Terraform
* `consul_hostname` variable in Terraform
* `CERTIFICATE_DOMAIN` variable in `tls-bootstrap/bootstrap.sh`

The automation does _NOT_ create any DNS records, but does expect them to exist and therefore you should add the necessary automation to Terraform or arrange some other means of ensuring that the expected hostname resolves to an address on the load-balancer.

### Backups

There is no provision made to enable backups as the situation of each user is likely to be different.
Since Consul is the backing store for Vault, an automated process that takes a snapshot of Consul and saves it somewhere would probably be useful.

## Design

### External access

All external access is IP whitelisted within security groups configured through Terraform.
HTTPS communication to Consul is exposed via a load-balancer on port 8501 and traffic is sent to the autoscaling group.
HTTPS communication to Vault is exposed via a load-balancer on port 443 and traffic is sent to HAProxy on the Vault nodes.
Depending on the hostname supplied, traffic is routed either to any available Vault node or directly to a specific node.

This is done so that individual Vault nodes can be unsealed externally and so as to enable initialisation of Vault.

### DNS

Consul and Vault are exposed through a load-balancer and are expected to be available at `vault.<domain>` and `consul.<domain>`.
Individual Vault server nodes are available at `<instance name>.vault.<domain>` where `<instance name>` is the name of the VM within the cloud provider.
By default this is something like `vault-0`.

Various systems need to be aware of the hostnames used for access, as well as requiring certificates with appropriate CNs and SANs.
In particular these are:
* HAProxy (via the `haproxy-consul-template` ansible role)
* Terraform (via the `vault_hostname` and `consul_hostname` locals)

### TLS

Private CAs are created to secure traffic to Consul and Vault, and the script in `tls-bootstrap` is designed to achieve this.
You can use whatever certificates you'd like, including Let's Encrypt but be aware of the following:

* The certificates and keys are baked into the machine images
* Ansible expects the certificate and key files to be available to it, so they should be placed in the `ansible` folder or within the `files` folder of the relevant role
* If using a public CA, ensure that the `.crt` file contains the certificate of the issuing CA and any intermediates, and that the `-ca.crt` file contains the certificate of the root CA.
* The CA used to secure outgoing communication (TLS server certs) from Consul must be the same as the one used to secure incoming communication (TLS client certs), so a private CA is recommended.

Certificates are needed at various points in the provisioning process, chiefly by ansible and Terraform.
Ansible bakes the certificate and key files into the machine image, and Terraform uses the Consul certificate files in the ACL bootstrapping process.

_NOTE_: The CNs and SANs used on certificates are critical and must match various expected names.
Of course for external access, the certificates should have `consul.<domain>`, `vault.<domain>`, and `*.vault.<domain>` names.
In addition, to enable Consul to communicate securely with itself, it expects a given name to be present in the certificate, by default this is `consul`.
If you wish to adjust this, be sure to update the Consul configuration to expect the newly assigned value.

### Consul

An autoscaling group is created for Consul, but with no scaling rules as this is a very installation-specific concern.
The Consul nodes are designed to be able to join a cluster with minimal fuss and use the cloud auto-join mechanism to do so.
The agent goes through a bootstrap process on startup to configure the cloud auto-join settings as well as setting the agent ACL.
The cloud auto-join settings are configured in Terraform.

#### ACLs

The ACL system is bootstrapped using the bootstrap process and currently is achieved using a null resource in Terraform to call the relevant APIs from the machine running Terraform.
The master token is captured and output to the filesystem for the operator to do with as they please.
Some essential policies and tokens are also created at this point to enable Vault and consul-template to function.
The bootstrap process will retry indefinitely until it succeeds, which can lead to an infinite provisioning loop if the bootstrap operation is successful but subsequent operations fail.
In this situation, the bootstrap process should be reset, or the relevant lines should be commented allowing Terraform to re-run.

Having Consul tokens within machine images has been avoided as much as possible, however a certain amount of it is necessary.
For the purposes of configuring the Consul agent with the necessary permissions to do node updates, a file is placed in `/etc/consul.d` for use in the agent bootstrap process.
Once the agent has been configured to use the token with the agent ACL API, the token file is deleted as token persistence within Consul is enabled.

### HAProxy and consul-template

HAProxy is installed on the Vault nodes to be able to direct traffic as necessary and achieve the direct-to-node or load-balanced access as previously described.
To achieve this, there are two types/groups of backends - a backend per node for the direct-to-node access, containing only that specific node, and a single backend containing all nodes for the load-balanced access.
HAProxy is deliberately unaware of the content of any HTTP requests going through it (except stats), and uses the SNI conversation as a judgement for where to send traffic.
The HAProxy frontends can optionally accept the proxy protocol (defaults to on) from the fronting load-balancer.
All backends within HAProxy (individual nodes and load-balanced pool) have health checks enabled.
The load-balanced backend uses an HTTPS check to Vault's health endpoint and the individual node backends use HTTPS health checks to Vault's health endpoint, permitting most error conditions.
In addition, all backends send the proxy protocol to Vault.

Consul-tempmlate is used to query Consul for Vault node information and populates HAProxy's configuration accordingly for the individual node backends as well as the load-balanced backend.

### Vault

Vault is setup to receive the proxy protocol and is configured such that any IP in the subnet is allowed to send the proxy protocol to Vault.
This enables multiple Vault nodes to load-balance one another (with HAProxy) without needing to authorise specific IPs or needing to dynamically configure Vault according to what nodes are available.

It's expected that the `file` audit method will be used and so logrotate has been configured accordingly, especting an audit log file to be placed in `/var/log/vault/` with an extension of `.log`.

It should be noted that auto-unsealing is not in use in this installation and the initialisation of Vault is left as an exercise for the operator.

## Considerations of automation and setup

### TLS certificates

It is hypothetically possible to create one or more PKI backends within Vault and have them serve as the CAs for securing Consul and Vault communication.
This could give you such benefits as not needing to create machine images that contain certificates and keys, instead having the nodes generate keys and obtain signed certificates from Vault upon startup.

The reason this hasn't been done is that it makes the overall setup more complicated and requires more initial configuration during the setup of the system, as it creates a cyclical dependency on the cluster itself.
You may of course pursue such a setup should you wish, just bear in mind the differences between automating 'the first' setup and 'the ongoing' setup.
If the cluster needed to be rebuilt, it's likely that you would need to revert to storing certificates and keys within the image until the cluster can be brought up from scratch again.
One way to achieve the self-certificating setup would be to use consul-template to request certificates from Vault, and restarting Consul or triggering a config reload when the files changed.
It would be best to use the Vault agent as well to maintain a Vault token and have the agent make requests to Vault on behalf of consul-template.
You would also need to change the explicit CA cert file in Consul's config, with a directory to permit the change in CA to take place as new agents are rolled out to the autoscaling group.

Incidentally the commentary mentions Consul as a target of automated certificates, but the approach for Vault would be very similar.

It would also be possible to use a secret storage mechanism on a cloud provider to store the certificates and keys and have the machines pull them out of storage on startup.
This hasn't been done in order to simplify the setup and to avoid introducing further dependencies outwith those already in use.
Depending on your situation, you may wish to avoid trusting such a tool, or you may consider that acceptable.

If you wanted to pull certificates in on startup, it would be reasonably trivial to do and the userdata field could be used fairly effectively.

### ACL tokens

In this setup, Consul tokens are created with known secret values already provisioned within components such as consul-template and Vault.
The tokens are stored in the machine image and removed if possible after startup (Consul only).

It would be possible to instead store these tokens within Vault or even a cloud provider's secrets storage facility and have the nodes retrieve them on startup.
This hasn't been done for similar reasons to those discussed in the previous section - to avoid introducing unnecessary dependencies, to limit the reach of trust, and also to avoid complexity in the setup.

Once again, such a setup is fairly trivial to achieve, and the recommendation is to use userdata to trigger the behaviour.

### ACL bootstrapping

It's possible to use the Consul provider for Terraform to create ACL policies and tokens within Consul.

In this setup, policies and tokens are instead created by calling the APIs via the Consul binary.
The reason for this is, again to avoid introducing complexity into the initial setup.
When managing resources via Terraform, layered and explicitly-ordered dependencies within the same configuration don't always work well.
The CLI-based approach allows for plenty of retries and a more robust experience than attempting to wire the Consul provider up to a cluster that doesn't yet exist or is still being provisioned.

Again, you could bootstrap the cluster and then go on to manage the ACL policies and tokens within Terraform, including importing the master and default tokens and this has been left as an exercise for the operator.
It would also be possible to use Vault to create and distribute tokens for use with Consul, and much like the previous sections, this has been left out so as to not introduce complexity.

