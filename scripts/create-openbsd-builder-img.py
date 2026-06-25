#!/usr/bin/env python3
# Summary: create the local OpenBSD builder VM disk used for remastering.
# It boots the official miniroot in QEMU, installs a minimal OpenBSD system onto
# a raw disk image, and leaves that image ready to run rdsetroot/vnconfig later.
import argparse
import os
import re
import sys
import time
import pexpect


def wait_prompt(child, patterns, timeout=900):
    """Wait for one installer prompt and convert EOF/timeouts into clear errors."""
    # pexpect returns the index of the first matching pattern. Appending EOF and
    # TIMEOUT lets this helper distinguish normal prompts from QEMU failures.
    idx = child.expect(patterns + [pexpect.EOF, pexpect.TIMEOUT], timeout=timeout)
    if idx == len(patterns):
        raise RuntimeError("QEMU exited")
    if idx == len(patterns) + 1:
        raise RuntimeError("timed out waiting for installer prompt")
    return idx, child.after if isinstance(child.after, str) else str(child.after)


def main():
    """Install OpenBSD into a raw QEMU disk image for later remastering work."""
    # CLI defaults mirror the rest of this repo's tmp/cache layout so the
    # download script and remaster wrapper can share artifacts without glue code.
    ap = argparse.ArgumentParser(description="Create a local OpenBSD raw builder image for Debian/Linux remastering")
    ap.add_argument("--install-img", help="OpenBSD miniroot image; default: tmp/cache/openbsd/VERSION/ARCH/minirootXX.img")
    ap.add_argument("--install-iso", dest="install_img", help=argparse.SUPPRESS)
    ap.add_argument("--output", help="raw builder disk image to create; default: tmp/cache/openbsd-builder-VERSION-ARCH.raw")
    ap.add_argument("--size", default="8G")
    ap.add_argument("--password", default="secret")
    ap.add_argument("--mem", default="1024M")
    ap.add_argument("--version", default="7.9")
    ap.add_argument("--arch", default="amd64")
    ap.add_argument("--pubkey", default=os.path.expanduser("~/.ssh/id_ed25519.pub"))
    args = ap.parse_args()

    rel = args.version.replace(".", "")
    # Fill in default paths only after parsing version/arch overrides.
    if args.install_img is None:
        args.install_img = f"tmp/cache/openbsd/{args.version}/{args.arch}/miniroot{rel}.img"
    if args.output is None:
        args.output = f"tmp/cache/openbsd-builder-{args.version}-{args.arch}.raw"

    # Refuse to overwrite builder images: they are expensive to create and may
    # contain local setup state useful for debugging remaster failures.
    if not os.path.exists(args.install_img):
        raise SystemExit(f"miniroot image not found: {args.install_img}")
    if os.path.exists(args.output):
        raise SystemExit(f"output already exists: {args.output}")
    pubkey = ""
    if os.path.exists(args.pubkey):
        # Currently read for future/interactive use; keep behavior unchanged by
        # leaving the installation answers below as password-based root access.
        pubkey = open(args.pubkey).read().strip()

    # Create the empty disk, then boot QEMU from the official miniroot image with
    # a serial console so pexpect can drive the text installer. The miniroot is
    # attached as the first virtio disk (boot media), so the install target is
    # the second virtio disk, `sd1`, during the builder install.
    os.makedirs(os.path.dirname(os.path.abspath(args.output)) or ".", exist_ok=True)
    os.system(f"qemu-img create -f raw {args.output!r} {args.size!r}")

    cmd = (
        "qemu-system-x86_64 -machine accel=tcg -m {mem} -smp 1 -nographic "
        "-drive file={install_img},format=raw,if=virtio,readonly=on "
        "-drive file={disk},format=raw,if=virtio "
        "-netdev user,id=n0 -device e1000,netdev=n0"
    ).format(mem=args.mem, install_img=args.install_img, disk=args.output)
    child = pexpect.spawn(cmd, encoding="utf-8", timeout=240, dimensions=(40, 140))
    child.logfile = sys.stdout

    # Switch the OpenBSD boot loader to com0; the QEMU process is nographic, so
    # all subsequent installer prompts must appear on the serial console.
    child.expect("boot>")
    child.sendline("set tty com0")
    child.expect("boot>")
    child.sendline("boot")
    child.expect(r"\(I\)nstall.*\?")
    child.sendline("i")

    # Prompt patterns cover normal OpenBSD installer questions plus completion
    # states. The main loop below maps each matched prompt to an answer.
    patterns = [
        r"Terminal type\?[^\n]*",
        r"Keyboard layout\?[^\n]*",
        r"System hostname\?[^\n]*",
        r"(?:Which network interface do you wish to configure|Network interface to configure)\?[^\n]*",
        r"IPv4 address for [^?]+\?[^\n]*",
        r"IPv6 address for [^?]+\?[^\n]*",
        r"DNS domain name\?[^\n]*",
        r"DNS nameservers\?[^\n]*",
        r"Password for root account\?[^\n]*",
        r"Password for root account \(again\)\?[^\n]*",
        r"Start sshd\(8\) by default\?[^\n]*",
        r"Do you expect to run the X Window System\?[^\n]*",
        r"Change the default console to com0\?[^\n]*",
        r"Which speed should com0 use\?[^\n]*",
        r"Setup a user\?[^\n]*",
        r"Allow root ssh login\?[^\n]*",
        r"What timezone are you in\?[^\n]*",
        r"Which disk is the root disk\?[^\n]*",
        r"Which disk do you wish to initialize\?[^\n]*",
        r"Encrypt the root disk.*\?[^\n]*",
        r"Use \(W\)hole disk MBR.*\?[^\n]*",
        r"Use \(A\)uto layout.*\?[^\n]*",
        r"Location of sets\?[^\n]*",
        r"HTTP Server\?[^\n]*",
        r"Server directory\?[^\n]*",
        r"Use HTTPS\?[^\n]*",
        r"HTTP proxy URL\?[^\n]*",
        r"Pathname to the sets\?[^\n]*",
        r"Set name\(s\)\?[^\n]*",
        r"Directory does not contain SHA256.sig.*\?[^\n]*",
        r"CONGRATULATIONS",
        r"Exit to \(S\)hell, \(H\)alt or \(R\)eboot\?[^\n]*",
    ]

    seen_net_done = False
    set_prompt_count = 0
    loc_sets_count = 0
    while True:
        # Wait for the next recognized installer prompt, decide the answer from
        # the prompt text, and send it. State counters handle repeated prompts.
        _, s = wait_prompt(child, patterns, timeout=1200)
        ans = None
        if "CONGRATULATIONS" in s:
            # The installer prints this before the final halt/reboot question.
            continue
        if "Terminal type" in s:
            ans = "vt220"
        elif "Keyboard layout" in s:
            ans = ""
        elif "System hostname" in s:
            ans = "openbsd-builder"
        elif "Which network interface" in s or "Network interface to configure" in s:
            # First configure em0; if asked again, indicate that networking is
            # complete. This matches OpenBSD's multi-interface prompt flow.
            ans = "done" if seen_net_done else "em0"
            seen_net_done = True
        elif "IPv4 address" in s:
            ans = "dhcp"
        elif "IPv6 address" in s:
            ans = "none"
        elif "DNS domain name" in s or "DNS nameservers" in s:
            ans = ""
        elif "Password for root account" in s:
            ans = args.password
        elif "Start sshd" in s:
            ans = "no"
        elif "X Window System" in s:
            ans = "no"
        elif "default console to com0" in s:
            ans = "yes"
        elif "speed should com0" in s:
            ans = "115200"
        elif "Setup a user" in s:
            ans = "no"
        elif "Allow root ssh login" in s:
            ans = "yes"
        elif "What timezone" in s:
            ans = "UTC"
        elif "Which disk is the root disk" in s:
            # The miniroot boot media is sd0 during this QEMU install; install
            # the reusable builder system onto the second virtio disk.
            ans = "sd1"
        elif "Which disk do you wish to initialize" in s:
            # sd1 was already initialized for the builder. Do not touch the
            # miniroot boot media (sd0); continue to set selection.
            ans = "done"
        elif "Encrypt the root disk" in s:
            ans = "no"
        elif "Whole disk MBR" in s or "(W)hole disk MBR" in s:
            ans = "whole"
        elif "Auto layout" in s or "(A)uto layout" in s:
            ans = "a"
        elif "Location of sets" in s:
            # miniroot does not contain the install sets; fetch the minimal
            # builder system directly from OpenBSD's CDN.
            loc_sets_count += 1
            ans = "http" if loc_sets_count == 1 else "done"
        elif "HTTP Server" in s:
            ans = "cdn.openbsd.org"
        elif "Server directory" in s:
            ans = f"pub/OpenBSD/{args.version}/{args.arch}"
        elif "Use HTTPS" in s:
            ans = "yes"
        elif "HTTP proxy URL" in s:
            ans = "none"
        elif "Pathname to the sets" in s:
            ans = f"{args.version}/amd64"
        elif "Set name" in s:
            # Keep the local builder minimal: base/bsd/bsd.rd/man are enough for
            # remastering. The user's preferred server profile also skips comp,
            # games, and X sets.
            set_prompt_count += 1
            deselect = ["-comp*", "-game*", "-x*"]
            ans = deselect[set_prompt_count - 1] if set_prompt_count <= len(deselect) else "done"
        elif "SHA256.sig" in s:
            ans = "yes"
        elif "Exit to" in s:
            # Halt rather than reboot so the newly written image is cleanly
            # closed and ready for later QEMU boots by the remaster script.
            child.sendline("h")
            break
        else:
            raise RuntimeError(f"unhandled prompt: {s!r}")
        child.sendline(ans)

    # Give QEMU a moment to flush disk writes after the halt command, then close
    # the child process and report the resulting image path/password.
    time.sleep(5)
    child.close(force=True)
    print(f"builder image written: {args.output}")
    print(f"local builder root password: {args.password}")


if __name__ == "__main__":
    main()
