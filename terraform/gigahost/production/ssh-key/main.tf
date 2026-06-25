terraform {
  required_version = ">= 1.5.7"

  required_providers {
    gigahost = {
      source  = "pigeon-as/gigahost"
      version = "~> 0.5"
    }
  }
}

# GIGAHOST_API_TOKEN comes from the repo-root .env sourced by the caller.
provider "gigahost" {}

locals {
  ssh_key_name = "local-id_ed25519"
}

resource "gigahost_ssh_key" "admin" {
  key_name = local.ssh_key_name
  key_data = file(pathexpand("~/.ssh/id_ed25519.pub"))

  lifecycle {
    prevent_destroy = true
  }
}

output "ssh_key_name" {
  value = gigahost_ssh_key.admin.key_name
}

output "ssh_key_id" {
  value = gigahost_ssh_key.admin.key_id
}
