#!/bin/bash
# golden-image-setup-ubuntu2604.sh - 一键母盘定制（Ubuntu 26.04 → NVMe-oF SAN 引导母盘）
#
# 对应 docs/zh/distributions.md 的 A-F 六阶段：
#   A. 系统与内核   自带内核(NVME_AUTH 已启用)（CONFIG_NVME_AUTH 已启用，免换内核）
#   B. initramfs 种子模块（initramfs-nbft：NBFT/NBCT 消费，hostid 修复）
#   C. 系统配置     fstab（root UUID 写死 + 注释 /boot/efi）、DHCP、hostname 占位
#   D. GRUB 启动参数（net.ifnames=0 ip=dhcp nbft_auto systemd.mask 防断链）
#   E. 磁盘格式     4K 原生 GPT + 4K FAT32 ESP + GRUB（SAN 形态，交互确认）
#   F. 无状态校验   盘内零身份硬编码 + 验收清单
#
# 用法（在母盘系统内以 root 运行）：
#   sudo bash golden/ubuntu2604/golden-image-setup-ubuntu2604.sh
#   sudo bash golden/ubuntu2604/golden-image-setup-ubuntu2604.sh --skip-disk --yes
#
# 选项：
#   -d DIR        initramfs-nbft 组件目录（默认脚本同仓库的 ../../initramfs-nbft;
#                 仓库组件不可用时自动释放脚本内嵌组件，单文件即可分发到母盘运行）
#   -k VER        内核版本（默认 uname -r；Ubuntu 26.04 自带内核已含 NVME_AUTH）
#   --skip-disk   跳过 E 的 GPT/ESP 重建（仍刷新 ESP 内容与 grub.cfg）
#   --no-serial   grub.cfg 不加 console=ttyS0,115200（无串口场景）
#   --yes         跳过 E 阶段交互确认
#   --grub-efi F  注入宿主预构建 BOOTX64.EFI（跳过母盘内 grub-mkimage）。
#                 Debian 12 自带 grub 2.06 的 mkimage 产物在 SAN 引导路径实测卡死
#                 （2026-09-04，见 docs/zh/distributions.md），需 2.12+。
#   --mirror URL  apt 镜像（默认 http://mirrors.aliyun.com/ubuntu）
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
KVER=$(uname -r)   # Ubuntu 26.04 自带内核（6.8+ 已含 CONFIG_NVME_AUTH）
ESP_VOLID=855B91DF
ESP_UUID=855B-91DF
CONSOLE=console=ttyS0,115200
GRUB_ARGS="net.ifnames=0 biosdevname=0 ip=dhcp nbft_auto systemd.mask=NetworkManager.service systemd.mask=systemd-networkd.service"
DO_DISK=1
YES=0
GRUB_EFI=
MIRROR="http://mirrors.aliyun.com/ubuntu"
KEEP_SOURCES=0
MENU_LABEL="Ubuntu 26.04"
INITRD_SRC_TEMPLATE="/boot/initrd.img-@KVER@"
INITRD_ESP_NAME_TEMPLATE="initrd.img-@KVER@"
IDENTITY_DIRS=(/etc/systemd/network)
PHASE_C_NETWORKD=1
MKFS_FAT_OPTS="-S 4096"
GRUB_MKIMAGE=grub-mkimage
GRUB_REGEN=update-grub
GRUB_DEFAULT_ONLY=1
GRUB_DROP_WORDS="quiet"
PHASE_E_LVM_FALLBACK=1
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
    log "[A] 系统与内核（自带内核，免换内核）"
    apply_sources
    # 禁用安装器残留的 cdrom 源（无光驱环境 apt-get update 会硬失败）
    cdrom_files=$(grep -rsl '^deb cdrom:' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null || true)
    if [ -n "$cdrom_files" ]; then
        for f in $cdrom_files; do sed -i 's|^deb cdrom:|# deb cdrom:|' "$f"; done
        echo "    commented out cdrom sources: $cdrom_files"
    fi
    apt-get update
    apt-get install -y nvme-cli jq initramfs-tools grub-efi-amd64-bin dosfstools
    apt-get install -y "linux-modules-extra-${KVER}" || \
        echo "    note: linux-modules-extra-${KVER} unavailable, NIC set limited to the base kernel package"
    # 内核段 NVMe/TCP TLS（段 1.3c）：keyctl（keyutils）注入 .nvme PSK；tlshd（ktls-utils）
    # 承担内核 TLS 握手 upcall。分两条装：个别发行版仓库无 ktls-utils 时不影响 keyutils，
    # 也不阻断母盘构建（该发行版内核段 TLS 自动降级明文，hook 侧只告警）。
    apt-get install -y keyutils || echo "    note: keyutils missing, TLS-PSK injection unavailable"
    apt-get install -y ktls-utils || echo "    note: ktls-utils missing, kernel-stage TLS unavailable (plaintext)"
    # 内核 NVME_AUTH 校验（Ubuntu 26.04 自带内核，无需换内核）
    CONF="/boot/config-${KVER}"
    [ -f "$CONF" ] || { echo "ERROR: $CONF 不存在"; exit 1; }
    grep -q '^CONFIG_NVME_AUTH=m' "$CONF" || { echo "ERROR: $CONF 中 CONFIG_NVME_AUTH 不是 =m"; exit 1; }
    echo "    CONFIG_NVME_AUTH=m OK"
}

apply_sources() {
    # 宿主无 IPv6 的环境 apt 大文件下载会卡死(实测),统一强制 IPv4
    echo 'Acquire::ForceIPv4 "true";' > /etc/apt/apt.conf.d/99-force-ipv4
    if [ "$KEEP_SOURCES" = 1 ]; then
        echo "    保留母盘原 apt 源(--keep-sources)"
        return
    fi
    local m=${MIRROR:-http://mirrors.aliyun.com/ubuntu}
    local suite; suite=$(. /etc/os-release && echo "$VERSION_CODENAME")
    echo "    切换 apt 源 -> $m($suite,deb822)"
    # Ubuntu 26.04 用 deb822 格式 ubuntu.sources:整体替换(原文件备份)
    [ -f /etc/apt/sources.list.d/ubuntu.sources ] && mv /etc/apt/sources.list.d/ubuntu.sources /etc/apt/sources.list.d/ubuntu.sources.golden-bak
    [ -f /etc/apt/sources.list ] && mv /etc/apt/sources.list /etc/apt/sources.list.golden-bak
    cat > /etc/apt/sources.list.d/ubuntu.sources <<EOF
Types: deb
URIs: $m
Suites: $suite
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: $m
Suites: $suite-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
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
