#!/usr/bin/env python3
"""Verify EMBED_B64_* payloads in the golden image scripts against their sources.

Each distribution script carries base64 copies of the initramfs-nbft
components, the GRUB BOOTX64 image and the shared golden-common library so it
can run as a single file on the golden image.  A stale copy silently ships an
old component, so check the decoded SHA-256 against the repository source.

Usage:
    python3 test/shared/verify-embed.py [SCRIPT ...]

Without arguments every test/*/golden-image-setup-*.sh is checked.  Exit
status is non-zero if a payload is missing, duplicated, malformed or stale.
"""
import base64
import binascii
import hashlib
import pathlib
import re
import sys

repo = pathlib.Path(__file__).resolve().parent.parent.parent

sources = {
    "EMBED_B64_CONNECT": repo / "initramfs-nbft" / "nbft-connect",
    "EMBED_B64_HOOK": repo / "initramfs-nbft" / "initramfs" / "hooks" / "nbft",
    "EMBED_B64_LOCALTOP": repo / "initramfs-nbft" / "initramfs" / "scripts" / "local-top" / "nbft",
    "EMBED_B64_BOOTX64": repo / "test" / "shared" / "assets" / "BOOTX64-2.14-generic.EFI",
    "EMBED_B64_COMMON": repo / "test" / "shared" / "golden-common.sh",
}

scripts = [pathlib.Path(a) for a in sys.argv[1:]] or sorted(
    repo.glob("test/*/golden-image-setup-*.sh"))
if not scripts:
    sys.exit("ERROR: no golden-image-setup scripts found")

failed = False
for script in scripts:
    try:
        text = script.read_text()
    except OSError as exc:
        print(f"FAIL {script}: {exc}")
        failed = True
        continue
    for var, src in sources.items():
        found = re.findall(rf"^{var}='([^']*)'", text, flags=re.M)
        if len(found) != 1:
            print(f"FAIL {script.name}: {var} found {len(found)} times")
            failed = True
            continue
        if not src.is_file():
            print(f"FAIL {script.name}: source missing {src}")
            failed = True
            continue
        try:
            payload = base64.b64decode(found[0], validate=True)
        except (binascii.Error, ValueError) as exc:
            print(f"FAIL {script.name}: {var} is not valid base64 ({exc})")
            failed = True
            continue
        want = hashlib.sha256(src.read_bytes()).hexdigest()
        got = hashlib.sha256(payload).hexdigest()
        if got != want:
            print(f"FAIL {script.name}: {var} sha256 {got} != {want} ({src.name})")
            failed = True
        else:
            print(f"ok   {script.name}: {var}")

sys.exit(1 if failed else 0)
