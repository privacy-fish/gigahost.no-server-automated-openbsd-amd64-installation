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

provider "gigahost" {}

variable "gigahost_ssh_key_id" {
  description = "Existing Gigahost SSH key id for rescue-system access."
  type        = string
  default     = "2491"
}

variable "suffix" {
  description = "Hostname suffix for dev canary."
  type        = string
  default     = "openbsd-dev"
}

locals {
  region_name  = "Sandefjord"
  product_name = "Intro - Intel Core i3 4GB"

  servers = {
    a = { name = "openbsd-canary-a.mail.privacy.fish" }
  }
}

resource "gigahost_server" "openbsd_canary" {
  for_each = local.servers

  product_name = local.product_name
  region_name  = local.region_name

  rescue = true

  hostname = "${each.value.name}-${var.suffix}"
  srv_name = "${each.value.name}-${var.suffix}"

  ssh_keys = [var.gigahost_ssh_key_id]

  timeouts = {
    create = "5m"
  }
}

locals {
  hosts = {
    for role, s in gigahost_server.openbsd_canary :
    role => {
      hostname  = s.srv_name
      server_id = s.srv_id
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
}

resource "local_file" "openbsd_install_vars" {
  for_each = local.hosts

  filename             = "${path.module}/../../../../tmp/build/${each.value.hostname}.vars"
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

output "server_ids" {
  value = { for role, h in local.hosts : role => h.server_id }
}

output "hostnames" {
  value = { for role, h in local.hosts : role => h.hostname }
}

output "ipv4_addresses" {
  value = { for role, h in local.hosts : role => h.ipv4.ip_address }
}

output "install_vars_paths" {
  value = { for role, f in local_file.openbsd_install_vars : role => f.filename }
}
