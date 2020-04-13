# Production-ish Vault installation with a Consul cluster (storage)

_NOTE_: This setup does not ship ready out-of-the-box, there are some tweaks the end user should do.

## Getting started

### Terraform

The Terraform config in this repo uses the local filesystem for state storage instead of remote state.
It is highly recommended to use a remote storage mechanism for Terraform's state.

Additionally, there are no version pins for any of the providers and it's recommended that you set some.

### Network

It's assumed that a network and subnet are available in which to setup the cluster, please adjust the automation accordingly.

### Variables (ansible)

Most variables are already setup with sensible values, but secrets or sensitive variables should be set per installation along with any other installation-specific variables.
Secret values consumed by ansible are protected using ansible-vault, and the vault password is intended to be kept in the root of the ansible repo for use by packer.

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

### Tokens

Consul tokens are required for the consul agent, for consul-template, and for Vault.
The `SecretID` values for each token are set in advance so that the machines can boot and automatically be able to perform their function without extra setup.
These are configured through variables in Ansible, which by default look for the tokens on the filesystem.
You should populate these tokens with your own values, which must be UUIDs, and can be supplied through files or by setting the ansible variables.
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
* `vault_hostname` local in Terraform
* `CERTIFICATE_DOMAIN` variable in `tls-bootstrap/bootstrap.sh`

The automation does _NOT_ create any DNS records, but does expect them to exist and therefore you should add the necessary automation to Terraform or arrange some other means of ensuring that the expected hostname resolves to an address on the load-balancer.

### Backups

There is no provision made to enable backups as the situation of each user is likely to be different.
Since Consul is the backing store for Vault, an automated process that takes a snapshot of Consul and saves ot somewhere would probably be useful.

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
In this situation, the bootstrap process should be reset.

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
The tokens are stored into the machine image and removed if possible after startup.

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
