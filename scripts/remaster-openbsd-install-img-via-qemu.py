#!/usr/bin/env python3
"""Remaster an OpenBSD/amd64 install image using an OpenBSD QEMU builder.

Debian/Linux cannot safely edit OpenBSD FFS/bsd.rd directly. This script copies
the source install image to the output path, boots an installed OpenBSD builder
image in QEMU, attaches the output installer image as a second disk, and runs the
OpenBSD-native rdsetroot/vnconfig workflow there.
"""
import argparse
import shutil
import sys
from pathlib import Path

import pexpect


def expect_root_shell(child, login: str, password: str, timeout: int) -> None:
    """Log into the OpenBSD builder and stop once a root shell prompt appears."""
    # The builder may show login, password, a root prompt, or an unprivileged
    # shell prompt depending on image state. Keep responding until root is ready.
    while True:
        idx = child.expect([r"login:", r"Password:", r"# ", r"\$ ", pexpect.EOF, pexpect.TIMEOUT], timeout=timeout)
        if idx == 0:
            child.sendline(login)
        elif idx == 1:
            child.sendline(password)
        elif idx == 2:
            return
        elif idx == 3:
            child.sendline("su -")
        elif idx == 4:
            raise RuntimeError("QEMU exited before root shell")
        else:
            raise RuntimeError("timed out waiting for OpenBSD builder login/root shell")


def main():
    """Copy an installer image and remaster that copy inside an OpenBSD VM."""
    # Parse all host-side paths and VM settings. The shell wrapper validates the
    # common case, but this script also validates direct invocations.
    p = argparse.ArgumentParser()
    p.add_argument("--source", required=True, help="official minirootXX.img")
    p.add_argument("--conf", required=True, help="per-host answer file to embed as /auto_install.conf")
    p.add_argument("--output", required=True, help="remastered output image")
    p.add_argument("--builder-image", required=True, help="installed OpenBSD raw/qcow2 image with rdsetroot")
    p.add_argument("--builder-login", default="root")
    p.add_argument("--builder-password", required=True)
    p.add_argument("--mem", default="1024M")
    p.add_argument("--timeout", type=int, default=420)
    args = p.parse_args()

    # Resolve paths before passing them to QEMU so relative caller cwd changes do
    # not affect the guest disk attachment or copied output image.
    source = Path(args.source).expanduser().resolve()
    conf = Path(args.conf).expanduser().resolve()
    output = Path(args.output).expanduser().resolve()
    builder = Path(args.builder_image).expanduser().resolve()

    # Validate all read-only inputs and the required QEMU executable before any
    # output image is created or overwritten.
    for label, path in [("source image", source), ("conf", conf), ("builder image", builder)]:
        if not path.is_file():
            raise SystemExit(f"missing {label}: {path}")
    if shutil.which("qemu-system-x86_64") is None:
        raise SystemExit("missing qemu-system-x86_64")

    # Work on an output copy only; never mutate the official source installer.
    output.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, output)

    # Normalize the answer file text before embedding it in the guest shell
    # script. The heredoc below preserves the file content verbatim otherwise.
    conf_text = conf.read_text().rstrip() + "\n"

    # Keep the OpenBSD guest-side remaster logic in its own shell file so it can
    # be read, commented, and debugged independently of the pexpect/QEMU driver.
    guest_template = Path(__file__).with_name("remaster-openbsd-installer-inside-guest.sh")
    guest_script = guest_template.read_text().replace("__AUTO_INSTALL_CONF_PLACEHOLDER__", conf_text.rstrip()).strip()

    # Attach the builder as the first disk and the copied installer as the second
    # disk. nographic routes the VM console through pexpect.
    cmd = [
        "qemu-system-x86_64",
        "-machine", "accel=tcg",
        "-m", args.mem,
        "-smp", "1",
        "-nographic",
        "-no-reboot",
        "-drive", f"file={builder},format=raw,if=virtio",
        "-drive", f"file={output},format=raw,if=virtio",
    ]
    print("booting OpenBSD builder in QEMU to remaster image", flush=True)
    child = pexpect.spawn(cmd[0], cmd[1:], encoding="utf-8", timeout=args.timeout)
    child.logfile_read = sys.stdout
    try:
        # Once logged in, upload the guest script through a quoted heredoc so no
        # host shell interpolation can alter the commands or embedded conf.
        expect_root_shell(child, args.builder_login, args.builder_password, args.timeout)
        print("running remaster commands inside OpenBSD builder", flush=True)
        child.sendline("cat > /tmp/remaster.sh <<'__REMASTER_SCRIPT__'")
        for line in guest_script.splitlines():
            child.sendline(line)
        child.sendline("__REMASTER_SCRIPT__")
        child.expect(r"# ", timeout=60)
        # Run the guest script, print a machine-readable exit marker, and power
        # off. The marker lets the host detect guest-side failures reliably.
        child.sendline("sh /tmp/remaster.sh; echo REMASTER_EXIT:$?; halt -p")
        idx = child.expect([r"REMASTER_EXIT:(\d+)", pexpect.EOF], timeout=args.timeout)
        if idx == 0:
            match = child.match
            rc = int(match.group(1))  # type: ignore[union-attr]
            if rc != 0:
                child.close(force=True)
                raise RuntimeError(f"guest remaster script failed with exit {rc}")
            child.expect(pexpect.EOF, timeout=180)
    except Exception:
        # Force-close QEMU on failures so callers do not inherit a stuck VM.
        child.close(force=True)
        raise
    finally:
        child.close()

    # If control reaches here, QEMU exited after a zero guest remaster status.
    print(f"wrote {output}")


if __name__ == "__main__":
    main()
