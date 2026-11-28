#!/bin/bash
# golden-image-setup-leap16.sh - 一键母盘定制（openSUSE Leap 16.0 / SUSE 系 → NVMe-oF SAN 引导母盘）
#
# 对应 docs/zh/distributions.md 的 A-F 六阶段：
#   A. 系统与内核   自带内核 6.12（CONFIG_NVME_AUTH=m / CONFIG_NVME_TCP_TLS=y）
#   B. initramfs     dracut 95nbft（NBCT 凭据消费 + 内核段 TLS）；网络由
#                    NetworkManager（nm-initrd-generator + ip=dhcp）承担
#   C. 系统配置     fstab（/ 用 UUID、注释 /boot/efi）、hostname 去标识
#   D. GRUB 启动参数（net.ifnames=0 ip=dhcp rd.neednet=1 nbft_auto）
#   E. 磁盘格式     4K 原生 GPT + 4K FAT32 ESP + GRUB 2.14（SAN 形态，交互确认）
#   F. 无状态校验   盘内零身份硬编码 + 验收清单
#
# SUSE 系（openSUSE Leap 16.0 实测）适配要点：
#   - dracut 059+suse：initrd 网络由 NetworkManager 承担（35network-manager +
#     nm-initrd-generator）；原生 95nvmf 只做无凭据的 `nvme connect-all --nbft`，
#     不携带 DH-HMAC-CHAP 密钥与 TLS-PSK，构建时显式 --omit，改由 95nbft 逐条连接；
#   - 内核段 TLS：tlshd（ktls-utils）与 keyctl 进 initrd，连接带 --tls；
#   - initrd 路径 /boot/initrd-<ver>（dracut 默认命名；拷入 ESP 时改名
#     initramfs-<ver>，与 grub.cfg 一致），GRUB 工具同 RHEL 系；
#   - zypper 源切换到 TUNA 镜像（$releasever 由发行版 repo 文件保留）。
#
# 用法（在母盘系统内以 root 运行）：
#   sudo bash golden/opensuse-leap16/golden-image-setup-leap16.sh
#   sudo bash golden/opensuse-leap16/golden-image-setup-leap16.sh --skip-disk --yes
#
# 选项：
#   -d DIR        initramfs-nbft 组件目录（默认脚本同仓库的 ../../initramfs-nbft;
#                 仓库组件不可用时自动释放脚本内嵌组件，单文件即可分发到母盘运行）
#   -k VER        内核版本（默认 uname -r）
#   --skip-disk   跳过 E 的 GPT/ESP 重建（仍刷新 ESP 内容与 grub.cfg）
#   --no-serial   grub.cfg 不加 console=ttyS0,115200（无串口场景）
#   --yes         跳过 E 阶段交互确认
#   --grub-efi F  注入宿主预构建 BOOTX64.EFI（跳过母盘内 grub2-mkimage）
#   --mirror URL  zypper 镜像（默认 https://mirrors.tuna.tsinghua.edu.cn/opensuse）
#   --keep-sources 保留母盘原 zypper 源（不切镜像）
#   -h, --help    显示帮助
# ==== END USAGE ====
#
# 幂等：重复运行安全（已处理的步骤自动跳过；E 阶段重跑会刷新 ESP 内容）。
# 注意：E 阶段把盘转为 4K 语义后，512 逻辑块环境不再可读，仅 SAN（nvmet 4K 块）
#       或 4Kn 环境可引导——这是母盘 SAN 形态的预期结果。
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# COMPONENT_DIR 在参数解析后推导：-d 必须优先于默认值生效
KVER=$(uname -r)
ESP_VOLID=855B91DF
ESP_UUID=855B-91DF
CONSOLE=console=ttyS0,115200
GRUB_ARGS="net.ifnames=0 biosdevname=0 ip=dhcp rd.neednet=1 nbft_auto systemd.mask=NetworkManager.service"
DO_DISK=1
YES=0
GRUB_EFI=
MIRROR="https://mirrors.tuna.tsinghua.edu.cn/opensuse"
KEEP_SOURCES=0
MENU_LABEL="openSUSE Leap 16.0"
INITRD_SRC_TEMPLATE="/boot/initrd-@KVER@"
INITRD_ESP_NAME_TEMPLATE="initramfs-@KVER@"
IDENTITY_DIRS=(/etc/NetworkManager/system-connections)
NBFT_SHELL=bash   # 发行版基础仓库无 dash；nbft-connect 显式剥离 NUL，bash 语义已验证

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
    log "[A] 系统与内核（自带 6.12 内核，NVMe/TCP TLS 已启用）"
    apply_sources
    zypper --non-interactive install nvme-cli jq grub2 dosfstools dracut NetworkManager \
        python3 tar xz xfsprogs e2fsprogs keyutils ktls-utils lvm2
    # 内核段 TLS 工具链（缺一即失败，不静默退回明文）
    [ -x /usr/sbin/tlshd ] || { echo "ERROR: ktls-utils/tlshd not installed; kernel-stage TLS unavailable"; exit 1; }
    [ -x /usr/bin/keyctl ] || { echo "ERROR: keyutils/keyctl not installed; TLS-PSK injection unavailable"; exit 1; }
    CONF="/boot/config-${KVER}"
    [ -f "$CONF" ] || CONF="/usr/lib/modules/${KVER}/config"
    [ -f "$CONF" ] || { echo "ERROR: 内核配置 $CONF 不存在"; exit 1; }
    grep -q '^CONFIG_NVME_AUTH=m' "$CONF" || { echo "ERROR: $CONF 中 CONFIG_NVME_AUTH 不是 =m"; exit 1; }
    grep -q '^CONFIG_NVME_TCP_TLS=y' "$CONF" || { echo "ERROR: $CONF 中 CONFIG_NVME_TCP_TLS 不是 =y"; exit 1; }
    echo "    CONFIG_NVME_AUTH=m / CONFIG_NVME_TCP_TLS=y OK"
}

apply_sources() {
    if [ "$KEEP_SOURCES" = 1 ]; then
        echo "    保留母盘原 zypper 源(--keep-sources)"
        return
    fi
    local m=${MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/opensuse}
    echo "    切换 zypper 源 -> $m"
    local rf
    for rf in /etc/zypp/repos.d/*.repo; do
        [ -f "$rf" ] || continue
        cp -n "$rf" "$rf.golden-bak" 2>/dev/null || true
        sed -i -e "s|https://download.opensuse.org/|$m/|g" \
               -e "s|http://download.opensuse.org/|$m/|g" "$rf"
        echo "    switched: $rf"
    done
    zypper --non-interactive --gpg-auto-import-keys refresh
}


# ---------------------------------------------------------------- B ----------
phase_b() {
    phase_b_dracut_nm
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
