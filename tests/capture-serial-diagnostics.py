#!/usr/bin/env python3
"""Connect to a QEMU serial unix socket, log in as root, and capture diagnostics."""

import os
import re
import select
import socket
import sys
import time


def main() -> int:
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <sock-path> <out-path>", file=sys.stderr)
        return 1

    sock_path, out_path = sys.argv[1], sys.argv[2]
    if not os.path.exists(sock_path):
        with open(out_path, "w", encoding="utf-8") as f:
            f.write(f"(serial socket {sock_path} does not exist)\n")
        return 0

    ansi_re = re.compile(
        rb"\x1b(?:\[[0-9;?]*[ -/]*[@-~]|\][^\x1b\x07]*(?:\x07|\x1b\\)|[PX^_].*?\x1b\\|[()][AB012]|.)"
    )
    cmd = (
        "ip -br a; ss -tlnp; "
        "systemctl --failed --no-pager --no-legend; "
        "systemctl status sshd.service systemd-repart.service systemd-bless-boot.service --no-pager -l; "
        "journalctl -b -u sshd.service -u systemd-repart.service -u systemd-bless-boot.service --no-pager; "
        "lsblk -o NAME,PARTLABEL,FSTYPE,MOUNTPOINTS,SIZE; "
        "findmnt; "
        "journalctl -b -p err -n 100 --no-pager; "
        'echo "__DIAG""_DONE__"\n'
    ).encode()

    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(5.0)
    raw = bytearray()
    try:
        s.connect(sock_path)
        s.setblocking(False)
        s.sendall(b"\n")
        sent_user = False
        sent_pass = False
        sent_cmd = False
        buf = b""
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            r, _, _ = select.select([s], [], [], 1.0)
            if not r:
                if not sent_cmd:
                    s.sendall(b"\n")
                continue
            data = s.recv(4096)
            if not data:
                break
            raw.extend(data)
            buf = ansi_re.sub(b"", buf + data).replace(b"\r", b"")
            if not sent_user and re.search(rb"(?:^|\n)[^\n]*login:\s*$", buf):
                s.sendall(b"root\n")
                sent_user = True
                buf = b""
            elif sent_user and not sent_pass and re.search(rb"Password:\s*$", buf):
                s.sendall(b"\n")
                sent_pass = True
                buf = b""
            elif not sent_cmd and re.search(rb"(?:^|\n)[^\n]*#\s*$", buf):
                s.sendall(cmd)
                sent_user = True
                sent_pass = True
                sent_cmd = True
                buf = b""
            elif sent_cmd and b"__DIAG_DONE__" in buf:
                break
    finally:
        s.close()

    cleaned = ansi_re.sub(b"", bytes(raw)).replace(b"\r", b"")
    with open(out_path, "wb") as f:
        f.write(cleaned)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
