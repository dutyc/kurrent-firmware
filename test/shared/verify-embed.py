#!/usr/bin/env python3
"""Verify the generated golden image setup scripts.

Each generated script carries base64 copies of the initramfs-nbft components,
the GRUB BOOTX64 image and the shared golden-common library so it can run as a
single file on the golden image. A stale copy silently ships an old component,
so check the decoded SHA-256 against the repository sources and the EFI image,
and check that image against the pinned SHA-256 in grub-efi.lock.

Usage: python3 test/shared/verify-embed.py [--dir DIR] [--efi FILE]

Default DIR is dist/golden; every golden template must have a generated
counterpart there. Exit status is non-zero if a payload is missing, malformed,
stale or the EFI image does not match the lock.
"""
import argparse
import base64
import binascii
import hashlib
import pathlib
import re
import sys

repo = pathlib.Path(__file__).resolve().parent.parent.parent
templates = sorted(repo.glob("golden/*/golden-image-setup-*.sh"))

sources = {
    "EMBED_B64_CONNECT": repo / "initramfs-nbft" / "nbft-connect",
}
# Optional payloads: checked when present, ignored when a script does not use
# them. initramfs-tools scripts embed the hook pair; the Arch script embeds the
# mkinitcpio pair instead.
optional_sources = {
    "EMBED_B64_HOOK": repo / "initramfs-nbft" / "initramfs" / "hooks" / "nbft",
    "EMBED_B64_LOCALTOP": repo / "initramfs-nbft" / "initramfs" / "scripts" / "local-top" / "nbft",
    "EMBED_B64_COMMON": repo / "golden" / "shared" / "golden-common.sh",
    "EMBED_B64_MKINITCPIO_INSTALL": repo / "golden" / "archlinux" / "mkinitcpio-nbft" / "install" / "nbft",
    "EMBED_B64_MKINITCPIO_HOOK": repo / "golden" / "archlinux" / "mkinitcpio-nbft" / "hooks" / "nbft",
}


def lock_sha256():
    text = (repo / "golden" / "shared" / "grub-efi.lock").read_text()
    m = re.search(r'^GRUB_EFI_SHA256="([0-9a-f]{64})"$', text, flags=re.M)
    if not m:
        sys.exit("ERROR: GRUB_EFI_SHA256 missing from golden/shared/grub-efi.lock")
    return m.group(1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dir", type=pathlib.Path, default=repo / "dist" / "golden")
    parser.add_argument(
        "--efi",
        type=pathlib.Path,
        default=repo / "dist" / "grub" / "BOOTX64-2.14-generic.EFI",
    )
    args = parser.parse_args()

    efi = args.efi
    if not efi.is_file():
        sys.exit(f"ERROR: GRUB EFI missing: {efi}")
    got = hashlib.sha256(efi.read_bytes()).hexdigest()
    want = lock_sha256()
    failed = got != want
    if failed:
        print(f"FAIL {efi}: sha256 {got} != lock {want}")
    else:
        print(f"ok   {efi.name}: sha256 matches lock")

    scripts = {t.parent.name: args.dir / t.parent.name / t.name for t in templates}
    if not scripts:
        sys.exit("ERROR: no golden-image-setup templates found")

    payloads = {**sources, "EMBED_B64_BOOTX64": efi, **optional_sources}
    for script in scripts.values():
        if not script.is_file():
            print(f"FAIL {script}: generated script missing")
            failed = True
            continue
        text = script.read_text()
        for var, src in payloads.items():
            found = re.findall(rf"^{var}='([^']*)'", text, flags=re.M)
            if not found and var in optional_sources:
                continue
            if len(found) != 1:
                print(f"FAIL {script.name}: {var} found {len(found)} times")
                failed = True
                continue
            if not src.is_file():
                print(f"FAIL {script.name}: source missing {src}")
                failed = True
                continue
            try:
                data = base64.b64decode(found[0], validate=True)
            except (binascii.Error, ValueError) as exc:
                print(f"FAIL {script.name}: {var} is not valid base64 ({exc})")
                failed = True
                continue
            if hashlib.sha256(data).hexdigest() != hashlib.sha256(src.read_bytes()).hexdigest():
                print(f"FAIL {script.name}: {var} payload does not match {src}")
                failed = True
            else:
                print(f"ok   {script.name}: {var}")

    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
