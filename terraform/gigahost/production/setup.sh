#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../../.." && pwd)

# OpenBSD /bin/ksh documents `. file` as the portable way to source a file.
# The repo-root .env should contain: export GIGAHOST_API_TOKEN=...
. "$ROOT/.env"

# Create/update the account-level SSH key used for rescue-system access.
(
  cd "$ROOT/terraform/gigahost/production/ssh-key"
  terraform init
  terraform apply
)

# Create today's Gigahost rescue-system cycle.
(
  cd "$ROOT/terraform/gigahost/production/cycles/24062026"
  terraform init
  terraform apply
)
