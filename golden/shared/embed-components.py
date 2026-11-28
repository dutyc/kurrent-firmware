#!/usr/bin/env python3
"""Generate the single-file golden image setup scripts.

The tracked golden/<distro>/golden-image-setup-*.sh files are templates whose
EMBED_B64_* variables are empty. This tool fills them from the repository
sources and the GRUB EFI image in dist/grub, writing the runnable scripts to
--out (default dist/golden). The tracked files are never modified.

Usage: python3 golden/shared/embed-components.py [--out DIR] [--efi FILE]
"""
import argparse
import base64
import pathlib
import re
import sys

repo = pathlib.Path(__file__).resolve().parent.parent.parent
setups = sorted(repo.glob("golden/*/golden-image-setup-*.sh"))
comp = repo / "initramfs-nbft"

items = {
    "EMBED_B64_CONNECT": comp / "nbft-connect",
}
# Scripts that source golden/shared/golden-common.sh also carry an embedded copy
# so they stay runnable as a single file; scripts without the marker are left
# untouched. The initramfs-tools hook pair is only used by the initramfs-tools
# distributions (Arch uses the mkinitcpio hooks below).
optional = {
    "EMBED_B64_HOOK": comp / "initramfs/hooks/nbft",
    "EMBED_B64_LOCALTOP": comp / "initramfs/scripts/local-top/nbft",
    "EMBED_B64_COMMON": repo / "golden" / "shared" / "golden-common.sh",
    "EMBED_B64_MKINITCPIO_INSTALL": repo / "golden" / "archlinux" / "mkinitcpio-nbft" / "install" / "nbft",
    "EMBED_B64_MKINITCPIO_HOOK": repo / "golden" / "archlinux" / "mkinitcpio-nbft" / "hooks" / "nbft",
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=pathlib.Path, default=repo / "dist" / "golden")
    parser.add_argument(
        "--efi",
        type=pathlib.Path,
        default=repo / "dist" / "grub" / "BOOTX64-2.14-generic.EFI",
    )
    args = parser.parse_args()

    efi = args.efi
    if not efi.is_file():
        sys.exit(
            f"ERROR: GRUB EFI missing: {efi} "
            "(run golden/shared/build-grub-efi.sh)"
        )
    if not setups:
        sys.exit("ERROR: no golden/*/golden-image-setup-*.sh templates")

    payloads = {**items, "EMBED_B64_BOOTX64": efi, **optional}
    args.out.mkdir(parents=True, exist_ok=True)

    for setup in setups:
        text = setup.read_text()
        for var, path in payloads.items():
            if not path.is_file():
                sys.exit(f"ERROR: source missing: {path}")
            b64 = base64.b64encode(path.read_bytes()).decode()
            text, n = re.subn(
                rf"^{var}='[^']*'", f"{var}='{b64}'", text, count=1, flags=re.M
            )
            if n != 1 and var not in optional:
                sys.exit(f"ERROR: {setup.name} placeholder {var} not found")
        dest = args.out / setup.parent.name / setup.name
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(text)
        dest.chmod(0o755)
        print(f"  {dest}: EMBED OK")
    print(f"generated {len(setups)} scripts under {args.out}")


if __name__ == "__main__":
    main()
