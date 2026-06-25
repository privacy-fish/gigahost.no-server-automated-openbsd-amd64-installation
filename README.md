# Gigahost OpenBSD autoinstall

Fully automatic OpenBSD install on gigahost.no hardware servers without IPMI.

Flow:

1. Terraform creates Gigahost hardware servers that boot into Gigahost rescue mode.
2. Terraform writes one host vars file per server with hostname, IPv4, IPv6, netmask, and gateways.
3. Scripts render `auto_install.conf`, embed it into `bsd.rd`, upload the compressed installer image to rescue RAM, write it to `/dev/sda`, and reboot.
4. OpenBSD autoinstalls itself and comes up on SSH.

This works from either:

- a Debian admin laptop, including Debian inside a VM such as a Xen VM on Qubes OS
- an OpenBSD admin laptop

This runbook was written and tested from a Debian VM on Qubes OS.

Generated downloads, images, vars, and logs live under `tmp/`. The repo keeps only `tmp/.gitkeep`; everything else under `tmp/` is local scratch data. Use `tmp/log/` for command logs.

## Requirements

Run examples from the repo root.

Create `.env` and edit it to add your Gigahost API key:

```sh
cp .env.example .env
```

You also need an ed25519 SSH key at `~/.ssh/id_ed25519` with the matching public key at `~/.ssh/id_ed25519.pub`. Generate one if needed:

```sh
ssh-keygen -t ed25519 -o -a 100
```

Use exactly one of these two setup sections first:

- `Debian admin laptop setup`
- `OpenBSD admin laptop setup`

Then both paths continue at `Shared steps for both Debian and OpenBSD admin laptops`.

## Debian admin laptop setup

Use this section only if your admin machine is Debian/Linux.

Load `.env`:

```sh
source .env
```

Install tools:

```sh
sudo apt install terraform qemu-system-x86 qemu-utils python3-pexpect curl gzip openssh-client
```

Download the OpenBSD miniroot image. The script writes to `tmp/cache/openbsd/7.9/amd64` by default:

```sh
./scripts/download-openbsd-install-img.sh -v 7.9
```

Create the local OpenBSD builder image once. It boots the miniroot in QEMU, installs sets over the network, and writes the default builder path:

```sh
# This script took us 13m 06s to run from a Qubes OS Debian VM.
./scripts/create-openbsd-builder-img.py
```

The builder image path is:

```text
tmp/cache/openbsd-builder-7.9-amd64.raw
```

This builder image is only a local QEMU build environment so Debian can use OpenBSD-native tools to edit `bsd.rd`. It is installed from the small miniroot image and downloads only the needed OpenBSD sets during builder creation. The simple local builder login is `root:${OPENBSD_BUILDER_PASSWORD}` from `.env` (`secret` in `.env.example`). It does not need open ports or SSH.

## OpenBSD admin laptop setup

Use this section only if your admin machine is OpenBSD.

Load `.env`:

```sh
. .env
```

Install tools:

```sh
doas pkg_add terraform curl bash python py3-pexpect
```

Download the OpenBSD installer image. The script writes to `tmp/cache/openbsd/7.9/amd64` by default:

```sh
./scripts/download-openbsd-install-img.sh -v 7.9
```

OpenBSD admin laptops do not need the QEMU builder image. They already have the native OpenBSD tools needed to edit `bsd.rd`.

## Shared steps for both Debian and OpenBSD admin laptops

From here on, both Debian and OpenBSD admin laptops use the same commands.

Create/recreate the Gigahost server currently defined by Terraform:

```sh
terraform -chdir=terraform/gigahost/production/openbsd-canary init
terraform -chdir=terraform/gigahost/production/openbsd-canary apply
```

Terraform writes this vars file:

```text
tmp/build/openbsd-canary-a.mail.privacy.fish-openbsd-dev.vars
```

Render host-specific autoinstall answers from that vars file. The script uses the canary vars path and writes the matching `.conf` by default:

```sh
./scripts/render-openbsd-install-conf.sh
```

Remaster the installer:

```sh
# This script took us 2m 07s to run from a Qubes OS Debian VM.
./scripts/remaster-openbsd-install-img.sh
```

The wrapper picks the right method automatically:

- Debian/Linux: uses the local QEMU OpenBSD builder image created earlier.
- OpenBSD: uses native OpenBSD tools directly, no builder image.

## Flash and verify

Both Debian and OpenBSD admin laptops use the same flash command.

Flash the server currently booted into the Gigahost rescue image. The script reads the admin IP from the vars file, streams the raw miniroot image over SSH into `/dev/sda`, and reboots immediately:

```sh
# This script took us 0m 36s to run from a Qubes OS Debian VM.
./scripts/flash-openbsd-install-img-to-server.sh -d /dev/sda
```

Wait for OpenBSD to come up. This polls every vars file under `tmp/build/`, so it works for one server or many servers:

```sh
# This script took us 4m 05s to run from a Qubes OS Debian VM.
./scripts/wait-for-openbsd-servers.sh
```

## Notes

- Future Gigahost floating IPs can be handled separately once their Terraform provider exposes them.
- Gigahost rescue SSH can take about 3-5 minutes to become usable after server create/recreate. It may briefly ask for a password before Gigahost finishes installing the SSH key; retry shortly and key auth should start working.
- The server disk is `/dev/sda` while booted into the Gigahost rescue system; OpenBSD sees the installed disk as `sd0`.
- The NIC is named `em0` in OpenBSD.
- DNS is rendered as Quad9: `9.9.9.9 149.112.112.112`.
- The flash script streams the raw miniroot image directly over SSH into `dd of=/dev/sda`.
- `flash-openbsd-install-img-to-server.sh` is destructive by design: if you run it, it writes the disk and reboots.
