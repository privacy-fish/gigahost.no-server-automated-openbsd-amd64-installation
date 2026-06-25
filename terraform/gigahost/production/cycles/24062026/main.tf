terraform {
  required_version = ">= 1.5.7"

  required_providers {
    gigahost = {
      source  = "pigeon-as/gigahost"
      version = "~> 0.5"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

# GIGAHOST_API_TOKEN comes from the repo-root .env sourced by the caller.
provider "gigahost" {}

variable "gigahost_ssh_key_id" {
  description = "Existing Gigahost SSH key id for rescue-system access. When null, Terraform looks up ssh_key_name via the account SSH-key API."
  type        = string
  default     = null
}

locals {
  suffix       = "24062026"
  region_name  = "Sandefjord"
  product_name = "Intro - Intel Core i3 4GB"
  ssh_key_name = "local-id_ed25519"

  servers = {
    in         = { name = "in.mail.privacy.fish" }
    spam_in    = { name = "spam-in.mail.privacy.fish" }
    fetch      = { name = "fetch.mail.privacy.fish" }
    out        = { name = "out.mail.privacy.fish" }
    spam_out   = { name = "spam-out.mail.privacy.fish" }
    keys       = { name = "keys.mail.privacy.fish" }
    backup     = { name = "backup.mail.privacy.fish" }
    monitoring = { name = "monitoring.mail.privacy.fish" }
    web        = { name = "web.privacy.fish" }
  }

  ssh_key_matches = var.gigahost_ssh_key_id != null ? [] : [
    for key in data.gigahost_ssh_keys.all[0].ssh_keys : key.key_id
    if key.key_name == local.ssh_key_name
  ]

  admin_ssh_key_id = var.gigahost_ssh_key_id != null ? var.gigahost_ssh_key_id : one(local.ssh_key_matches)
}

data "gigahost_ssh_keys" "all" {
  count = var.gigahost_ssh_key_id == null ? 1 : 0
}

resource "gigahost_server" "node" {
  for_each = local.servers

  product_name = local.product_name
  region_name  = local.region_name

  # Gigahost rescue-system install path. Do not set os_name or os_dist here.
  rescue = true

  hostname = "${each.value.name}-${local.suffix}"
  srv_name = "${each.value.name}-${local.suffix}"

  # Rescue-system SSH access; key is managed in ../../ssh-key.
  ssh_keys = [local.admin_ssh_key_id]

  # Gigahost bare-metal deploys should either complete quickly or fail fast.
  timeouts = {
    create = "5m"
  }
}

locals {
  hosts = {
    for role, s in gigahost_server.node :
    role => {
      hostname     = s.srv_name
      display_name = local.servers[role].name
      server_id    = s.srv_id
      ipv4 = one([
        for ip in s.ips : ip
        if ip.ip_v4v6 == "ipv4" && ip.ip_type == "primary"
      ])
      ipv6 = one([
        for ip in s.ips : ip
        if ip.ip_v4v6 == "ipv6" && ip.ip_type == "primary"
      ])
    }
  }

  hosts_for_inventory = {
    for role, h in local.hosts :
    role => {
      name = h.display_name
      ipv4 = h.ipv4.ip_address
    }
  }
}

resource "local_file" "openbsd_install_vars" {
  for_each = local.hosts

  filename             = "${path.module}/../../../../../tmp/build/${each.value.hostname}.vars"
  file_permission      = "0640"
  directory_permission = "0750"

  content = <<-EOT
    hostname=${each.value.hostname}
    ipv4=${each.value.ipv4.ip_address}
    netmask=${each.value.ipv4.ip_netmask}
    gateway=${each.value.ipv4.ip_gateway}
    ipv6=${each.value.ipv6.ip_address}
    ipv6_prefix=${trimprefix(each.value.ipv6.ip_netmask, "/")}
    ipv6_gateway=${each.value.ipv6.ip_gateway}
  EOT
}

resource "local_file" "ansible_inventory_yaml" {
  filename             = "${path.module}/../../../../../inventory/hosts"
  content              = templatefile("${path.module}/inventory.yml.tftpl", { hosts = local.hosts_for_inventory })
  file_permission      = "0640"
  directory_permission = "0750"
}

output "admin_ipv4_addresses" {
  value = { for role, h in local.hosts : role => h.ipv4.ip_address }
}

output "server_ids" {
  value = { for role, h in local.hosts : role => h.server_id }
}

output "install_vars_paths" {
  value = { for role, f in local_file.openbsd_install_vars : role => f.filename }
}

output "ansible_inventory_path" {
  value = local_file.ansible_inventory_yaml.filename
}
