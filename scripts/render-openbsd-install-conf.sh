#!/usr/bin/env bash
# Summary: render a host-specific OpenBSD auto_install.conf from Terraform vars.
# Use this before remastering so the installer gets the right hostname, IPs,
# routes, SSH key, and package-set choices for one target server.
set -euo pipefail

usage() {
  # Print CLI help and use exit code 2 to signal invalid arguments.
  cat <<'EOF'
usage: render-openbsd-install-conf.sh [-v host.vars] [-o host.conf] [-k ~/.ssh/id_ed25519.pub]
EOF
  exit 2
}

VARS=tmp/build/openbsd-canary.mail.privacy.fish-openbsd-dev.vars
OUT=
SSH_PUB=~/.ssh/id_ed25519.pub
OPENBSD_IF=em0
DNS1=9.9.9.9
DNS2=149.112.112.112
OPENBSD_VERSION=7.9

# Parse overrides for the Terraform vars file, output path, SSH key, and NIC.
while getopts 'v:o:k:i:h' opt; do
  case "$opt" in
    v) VARS=$OPTARG ;;
    o) OUT=$OPTARG ;;
    k) SSH_PUB=$OPTARG ;;
    i) OPENBSD_IF=$OPTARG ;;
    h|*) usage ;;
  esac
done

[ -n "$VARS" ] || usage
if [ -z "$OUT" ]; then
  # By default, write host.conf next to the matching host.vars file.
  OUT=${VARS%.vars}.conf
fi
[ -f "$VARS" ] || { echo "vars file not found: $VARS" >&2; exit 1; }
[ -f "$SSH_PUB" ] || { echo "ssh public key not found: $SSH_PUB" >&2; exit 1; }

# Source simple shell assignments emitted by Terraform and require every field
# used by the autoinstall answer file. Parameter expansion keeps failures clear.
# shellcheck disable=SC1090
. "$VARS"
: "${hostname:?missing hostname}"
: "${ipv4:?missing ipv4}"
: "${netmask:?missing netmask}"
: "${gateway:?missing gateway}"
: "${ipv6:?missing ipv6}"
: "${ipv6_prefix:?missing ipv6_prefix}"
: "${ipv6_gateway:?missing ipv6_gateway}"

# OpenBSD's answer file expects the public key on one line.
ssh_key=$(tr -d '\n' < "$SSH_PUB")
mkdir -p "$(dirname -- "$OUT")"

# Render answers in the exact prompt wording that OpenBSD auto_install(8)
# consumes. The values are intentionally static except for host/network data.
cat > "$OUT" <<EOF
System hostname = $hostname
Password for root = *************
Public ssh key for root account = $ssh_key
Allow root ssh login = prohibit-password
Setup a user = no
What timezone are you in = UTC
Change the default console to com0 = yes
Which speed should com0 use = 115200
Network interface to configure = $OPENBSD_IF
IPv4 address for $OPENBSD_IF = $ipv4
Netmask for $OPENBSD_IF = $netmask
Default IPv4 route = $gateway
IPv6 address for $OPENBSD_IF = $ipv6/$ipv6_prefix
IPv6 default router = $ipv6_gateway
DNS domain name = privacy.fish
DNS nameservers = $DNS1 $DNS2
Start sshd = yes
Do you expect to run the X Window System = no
Do you want the X Window System to be started by xenodm = no
Which disk is the root disk = sd0
Encrypt the root disk = no
Use (W)hole disk = whole
Use (A)uto layout = a
Location of sets = http
HTTP proxy URL = none
HTTP Server = cdn.openbsd.org
Server directory = pub/OpenBSD/$OPENBSD_VERSION/amd64
Continue without verification = yes
Set name(s) = -comp*
Set name(s) = -game*
Set name(s) = -x*
Set name(s) = done
EOF
# Print the generated file path for scripts that chain this command.
printf '%s\n' "$OUT"
