#!/bin/bash
# golden-image-setup-debian12.sh - 一键母盘定制（Debian 12 bookworm → NVMe-oF SAN 引导母盘）
#
# 对应 docs/zh/distributions.md 的 A-F 六阶段：
#   A. 系统与内核   bookworm-backports 6.12（CONFIG_NVME_AUTH=m）
#   B. initramfs 种子模块（initramfs-nbft：NBFT/NBCT 消费，hostid 修复）
#   C. 系统配置     fstab（root UUID 写死 + 注释 /boot/efi）、DHCP、hostname 占位
#   D. GRUB 启动参数（net.ifnames=0 ip=dhcp nbft_auto systemd.mask 防断链）
#   E. 磁盘格式     4K 原生 GPT + 4K FAT32 ESP + GRUB（SAN 形态，交互确认）
#   F. 无状态校验   盘内零身份硬编码 + 验收清单
#
# 用法（在母盘系统内以 root 运行）：
#   sudo bash golden/debian12/golden-image-setup-debian12.sh
#   sudo bash golden/debian12/golden-image-setup-debian12.sh --skip-disk --yes
#
# 选项：
#   -d DIR        initramfs-nbft 组件目录（默认脚本同仓库的 ../../initramfs-nbft;
#                 仓库组件不可用时自动释放脚本内嵌组件，单文件即可分发到母盘运行）
#   -k VER        内核版本（默认 6.12.95+deb12-amd64，bookworm-backports）
#   --skip-disk   跳过 E 的 GPT/ESP 重建（仍刷新 ESP 内容与 grub.cfg）
#   --no-serial   grub.cfg 不加 console=ttyS0,115200（无串口场景）
#   --yes         跳过 E 阶段交互确认
#   --grub-efi F  注入宿主预构建 BOOTX64.EFI（跳过母盘内 grub-mkimage）。
#                 Debian 12 自带 grub 2.06 的 mkimage 产物在 SAN 引导路径实测卡死
#                 （2026-09-04，见 docs/zh/distributions.md），需 2.12+。
#   --mirror URL  apt 镜像（默认 http://mirrors.aliyun.com/debian，security 同前缀推导）
#   --keep-sources 保留母盘原 apt 源（不切镜像）
#   -h, --help    显示帮助
# ==== END USAGE ====
#
# 幂等：重复运行安全（已处理的步骤自动跳过；E 阶段重跑会刷新 ESP 内容）。
# 注意：E 阶段把盘转为 4K 语义后，512 逻辑块环境（VMware/QEMU 默认）不再可读，
#       仅 SAN（nvmet 4K 块）或 4Kn 环境可引导——这是母盘 SAN 形态的预期结果。
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# COMPONENT_DIR 在参数解析后推导：-d 必须优先于默认值生效
KVER=6.12.95+deb12-amd64
ESP_VOLID=855B91DF
ESP_UUID=855B-91DF
CONSOLE=console=ttyS0,115200
GRUB_ARGS="net.ifnames=0 biosdevname=0 ip=dhcp nbft_auto systemd.mask=NetworkManager.service systemd.mask=systemd-networkd.service"
DO_DISK=1
YES=0
GRUB_EFI=
MIRROR="http://mirrors.aliyun.com/debian"
KEEP_SOURCES=0
MENU_LABEL="Debian GNU/Linux 12"
INITRD_SRC_TEMPLATE="/boot/initrd.img-@KVER@"
INITRD_ESP_NAME_TEMPLATE="initrd.img-@KVER@"
IDENTITY_DIRS=(/etc/systemd/network)
PHASE_C_NETWORKD=1
MKFS_FAT_OPTS="-F 32 -S 4096"
GRUB_MKIMAGE=grub-mkimage
GRUB_REGEN=update-grub
GRUB_DEFAULT_ONLY=1
GRUB_DROP_WORDS="quiet"
PHASE_E_LVM_FALLBACK=0
PHASE_E_LVM_PARAM=0

# ==== EMBEDDED initramfs-nbft components ====
# 由 golden/shared/embed-components.py 从仓库 initramfs-nbft/ 生成(勿手改);
# 仓库组件目录不可用时释放到临时目录使用,使本脚本可单文件分发到母盘运行。
EMBED_B64_CONNECT=''
EMBED_B64_HOOK=''
EMBED_B64_LOCALTOP=''
EMBED_B64_BOOTX64=''
# ==== END EMBEDDED ====

# ==== EMBEDDED golden-common.sh ====
EMBED_B64_COMMON=''
# ==== END EMBEDDED golden-common ====

# Shared stages live in golden/shared/golden-common.sh. The copy embedded above
# keeps this script runnable as a single file on the golden image.
GOLDEN_COMMON="$SCRIPT_DIR/../shared/golden-common.sh"
if [ -f "$GOLDEN_COMMON" ]; then
    . "$GOLDEN_COMMON"
else
    echo "    repository shared library unavailable, extracting the embedded copy..."
    GOLDEN_COMMON_DIR=$(mktemp -d /tmp/golden-common.XXXXXX)
    printf '%s' "$EMBED_B64_COMMON" | base64 -d > "$GOLDEN_COMMON_DIR/golden-common.sh"
    . "$GOLDEN_COMMON_DIR/golden-common.sh"
    GOLDEN_TMP_DIRS+=("$GOLDEN_COMMON_DIR")
fi

golden_init "$@"

# ---------------------------------------------------------------- A ----------
phase_a() {
    log "[A] 系统与内核（6.12 backports）"
    apply_sources
    # 禁用安装器残留的 cdrom 源（无光驱环境 apt-get update 会硬失败）
    cdrom_files=$(grep -rsl '^deb cdrom:' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null || true)
    if [ -n "$cdrom_files" ]; then
        for f in $cdrom_files; do sed -i 's|^deb cdrom:|# deb cdrom:|' "$f"; done
        echo "    commented out cdrom sources: $cdrom_files"
    fi
    apt-get update
    apt-get install -y nvme-cli jq initramfs-tools grub-efi-amd64-bin dosfstools
    install_nvme_cli_tls
    # 内核段 NVMe/TCP TLS（段 1.3c）：keyctl（keyutils）注入 .nvme PSK；tlshd（ktls-utils）
    # 承担内核 TLS 握手 upcall。两者是 TLS-only 引导路径的硬依赖，缺失即中止构建。
    apt-get install -y keyutils
    command -v keyctl >/dev/null || { echo "ERROR: keyutils/keyctl not installed; TLS-PSK injection unavailable"; exit 1; }
    install_ktls_utils
    [ -x /usr/sbin/tlshd ] || { echo "ERROR: tlshd not installed; kernel-stage TLS unavailable"; exit 1; }
    ensure_backports_source
    apt-get update
    apt-get install -y -t bookworm-backports "linux-image-${KVER}"
    CONF="/boot/config-${KVER}"
    [ -f "$CONF" ] || { echo "ERROR: $CONF 不存在（内核安装失败？）"; exit 1; }
    grep -q '^CONFIG_NVME_AUTH=m' "$CONF" || { echo "ERROR: $CONF 中 CONFIG_NVME_AUTH 不是 =m"; exit 1; }
    echo "    CONFIG_NVME_AUTH=m OK"
}

install_nvme_cli_tls() {
    # bookworm 的 nvme-cli 2.4 没有 connect --tls；内核段 TLS 需要 2.16 的选项。
    local help
    help=$(nvme connect --help 2>&1 || true)
    case "$help" in
    *--tls*)
        echo "    nvme-cli supports connect --tls"
        return
        ;;
    esac
    echo "    nvme-cli lacks connect --tls, building libnvme 1.16.2 + nvme-cli 2.16 from source"
    apt-get install -y meson ninja-build pkg-config gcc libc6-dev curl xz-utils \
        libjson-c-dev libkeyutils-dev libssl-dev
    local ln_sha=cf5a71549f6f6bfd1965af21731a7f8d79b6cff30de536d1dc4998e53f9a264d
    local nc_sha=6736153164634ddd16492aa68c5c5560e70f1c1c9edf009e20c182fcb3219af9
    local tmp
    tmp=$(mktemp -d /var/tmp/nvme-cli.XXXXXX)
    curl -fsSL --retry 3 -o "$tmp/libnvme.tar.xz" \
        "${MIRROR%/}/pool/main/libn/libnvme/libnvme_1.16.2.orig.tar.xz"
    echo "$ln_sha  $tmp/libnvme.tar.xz" | sha256sum -c -
    curl -fsSL --retry 3 -o "$tmp/nvme-cli.tar.xz" \
        "${MIRROR%/}/pool/main/n/nvme-cli/nvme-cli_2.16.orig.tar.xz"
    echo "$nc_sha  $tmp/nvme-cli.tar.xz" | sha256sum -c -
    tar -xJf "$tmp/libnvme.tar.xz" -C "$tmp"
    tar -xJf "$tmp/nvme-cli.tar.xz" -C "$tmp"
    (
        cd "$tmp/libnvme-1.16.2"
        meson setup build -Ddocs=false -Dexamples=false -Dtests=false -Dpython=disabled --prefix=/usr
        ninja -C build
        ninja -C build install
    )
    ldconfig
    (
        cd "$tmp/nvme-cli-2.16"
        meson setup build --prefix=/usr
        ninja -C build
        ninja -C build install
    )
    ldconfig
    rm -rf "$tmp"
    help=$(nvme connect --help 2>&1 || true)
    case "$help" in
    *--tls*) ;;
    *) echo "ERROR: the built nvme-cli still lacks connect --tls"; exit 1 ;;
    esac
    echo "    nvme-cli $(nvme version | head -1) installed"
}

install_ktls_utils() {
    # bookworm 仓库不提供 ktls-utils。从 Debian 源码池取 1.0.0 orig 源码在本机
    # 构建（软件源仍只含 bookworm），构建依赖全部取自 bookworm。
    if apt-get install -y ktls-utils >/dev/null 2>&1; then
        echo "    ktls-utils installed from the archive"
        return
    fi
    echo "    ktls-utils absent from bookworm, building 1.0.0 from source"
    apt-get install -y build-essential autoconf automake libtool pkg-config curl xz-utils \
        libgnutls28-dev libkeyutils-dev libglib2.0-dev libnl-3-dev libnl-genl-3-dev
    local ver=1.0.0
    local sha=fff9af1639cb21437a3f5b73728aba8df6f165fe15b09eabd1f98be6d85e2783
    local tmp
    tmp=$(mktemp -d /var/tmp/ktls-utils.XXXXXX)
    curl -fsSL --retry 3 -o "$tmp/ktls-utils.tar.xz" \
        "${MIRROR%/}/pool/main/k/ktls-utils/ktls-utils_${ver}.orig.tar.xz"
    echo "$sha  $tmp/ktls-utils.tar.xz" | sha256sum -c -
    tar -xJf "$tmp/ktls-utils.tar.xz" -C "$tmp"
    (
        cd "$tmp/ktls-utils-$ver"
        ./autogen.sh
        ./configure --prefix=/usr --sysconfdir=/etc
        make -j"$(nproc)"
        make install
        # The source tree does not install a default config file; the initramfs
        # hook ships /etc/tlshd/config and tlshd needs a parseable file there.
        install -D -m 0644 src/tlshd/tlshd.conf /etc/tlshd/config
    )
    rm -rf "$tmp"
    [ -x /usr/sbin/tlshd ] || { echo "ERROR: ktls-utils build did not install /usr/sbin/tlshd"; exit 1; }
    echo "    ktls-utils $ver built and installed"
}

apply_sources() {
    # 宿主无 IPv6 的环境 apt 大文件下载会卡死(实测),统一强制 IPv4
    echo 'Acquire::ForceIPv4 "true";' > /etc/apt/apt.conf.d/99-force-ipv4
    if [ "$KEEP_SOURCES" = 1 ]; then
        echo "    保留母盘原 apt 源(--keep-sources)"
        return
    fi
    local sec="${MIRROR%/}-security"
    echo "    切换 apt 源 -> $MIRROR(security: $sec)"
    for f in /etc/apt/sources.list.d/*.sources; do
        [ -e "$f" ] && mv "$f" "$f.golden-bak"
    done
    cat > /etc/apt/sources.list <<EOF
deb $MIRROR bookworm main contrib non-free non-free-firmware
deb $MIRROR bookworm-updates main contrib non-free non-free-firmware
deb $sec bookworm-security main contrib non-free non-free-firmware
EOF
}

ensure_backports_source() {
    if grep -rqs 'bookworm-backports' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
        echo "    bookworm-backports source already present"
        return
    fi
    if ls /etc/apt/sources.list.d/*.sources >/dev/null 2>&1; then
        cat > /etc/apt/sources.list.d/bookworm-backports.sources <<EOF
Types: deb
URIs: $MIRROR
Suites: bookworm-backports
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
    else
        echo "deb $MIRROR bookworm-backports main contrib non-free non-free-firmware" \
            > /etc/apt/sources.list.d/bookworm-backports.list
    fi
    echo "    added the bookworm-backports source"
}

# ---------------------------------------------------------------- B ----------
phase_b() {
    log "[B] initramfs 种子模块（initramfs-nbft）"
    for f in nbft-connect initramfs/hooks/nbft initramfs/scripts/local-top/nbft; do
        [ -f "$COMPONENT_DIR/$f" ] || { echo "ERROR: 缺少组件 $COMPONENT_DIR/$f（-d 指定目录）"; exit 1; }
    done
    grep -q -- '--hostid' "$COMPONENT_DIR/nbft-connect" || {
        echo "ERROR: nbft-connect 缺少 hostid 修复（文档 3.1），请先更新组件"; exit 1
    }
    mkdir -p /usr/share/initramfs-tools/scripts/local-top
    install -m 0755 "$COMPONENT_DIR/nbft-connect" /usr/local/sbin/
    install -m 0755 "$COMPONENT_DIR/initramfs/hooks/nbft" /usr/share/initramfs-tools/hooks/
    install -m 0755 "$COMPONENT_DIR/initramfs/scripts/local-top/nbft" /usr/share/initramfs-tools/scripts/local-top/
    golden_initramfs_tools_wired
}


main() {
    phase_a
    phase_b
    phase_c
    phase_d
    phase_e
    phase_f "${IDENTITY_DIRS[@]}"
}

main
