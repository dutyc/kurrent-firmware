#!/usr/bin/env python3
"""把仓库 initramfs-nbft 组件以 base64 内嵌进各发行版 golden-image-setup-<distro>.sh。

替换脚本内 EMBED_B64_* 占位(幂等,组件更新后重跑即可重新内嵌)。
用法: python3 golden/shared/embed-components.py
"""
import base64
import hashlib
import pathlib
import re
import sys

repo = pathlib.Path(__file__).resolve().parent.parent.parent
setups = sorted(repo.glob("golden/*/golden-image-setup-*.sh"))
comp = repo / "initramfs-nbft"

items = {
    "EMBED_B64_CONNECT": comp / "nbft-connect",
    "EMBED_B64_BOOTX64": repo / "golden" / "shared" / "assets" / "BOOTX64-2.14-generic.EFI",
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

if not setups:
    sys.exit("ERROR: 未找到 golden/*/golden-image-setup-*.sh")

for setup in setups:
    text = setup.read_text()
    for var, path in {**items, **optional}.items():
        if not path.is_file():
            sys.exit(f"ERROR: 组件缺失: {path}")
        raw = path.read_bytes()
        b64 = base64.b64encode(raw).decode()
        text, n = re.subn(rf"^{var}='[^']*'", f"{var}='{b64}'", text, count=1, flags=re.M)
        if n != 1:
            if var in optional:
                continue
            sys.exit(f"ERROR: {setup.name} 占位 {var} 未找到")
    setup.write_text(text)
    print(f"  {setup.name}: EMBED OK")
print("EMBED OK(组件/产物更新后重跑本工具即可重新内嵌)")
