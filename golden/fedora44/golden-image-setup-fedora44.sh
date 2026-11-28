#!/bin/bash
# golden-image-setup-fedora44.sh - 一键母盘定制（Fedora 44 → NVMe-oF SAN 引导母盘）
#
# 对应 docs/zh/distributions.md 的 A-F 六阶段：
#   A. 系统与内核   自带内核(NVME_AUTH 已启用)（CONFIG_NVME_AUTH 已启用，免换内核）
#   B. initramfs 种子模块（dracut 95nbft：NBFT/NBCT 消费，hostid 修复）
#   C. 系统配置     fstab（root UUID 写死 + 注释 /boot/efi）、DHCP、hostname 占位
#   D. GRUB 启动参数（net.ifnames=0 ip=dhcp rd.neednet=1 nbft_auto systemd.mask 防断链）
#   E. 磁盘格式     4K 原生 GPT + 4K FAT32 ESP + GRUB（SAN 形态，交互确认）
#   F. 无状态校验   盘内零身份硬编码 + 验收清单
#
# Fedora 44 适配要点（与 Debian/Ubuntu 变体的差异）：
#   - initramfs 用 dracut 构建（非 initramfs-tools）：95nbft 模块 + systemd-networkd。
#     dracut-108 已无 network-legacy，initrd 内 DHCP 由 networkd 承担；
#   - initrd 文件名为 initramfs-<KVER>.img；GRUB 工具为 grub2-mkimage / grub2-mkconfig；
#   - root 位于 LVM（anaconda 默认布局）→ 内核参数需 rd.lvm.lv=<VG>/<LV>；
#   - initrd 以 --no-hostonly 构建（显式有线网卡与存储/加密驱动白名单）。
#
# 用法（在母盘系统内以 root 运行）：
#   sudo bash golden/fedora44/golden-image-setup-fedora44.sh
#   sudo bash golden/fedora44/golden-image-setup-fedora44.sh --skip-disk --yes
#
# 选项：
#   -d DIR        initramfs-nbft 组件目录（默认脚本同仓库的 ../../initramfs-nbft;
#                 仓库组件不可用时自动释放脚本内嵌组件，单文件即可分发到母盘运行）
#   -k VER        内核版本（默认 uname -r；Fedora 44 自带内核已含 NVME_AUTH）
#   --skip-disk   跳过 E 的 GPT/ESP 重建（仍刷新 ESP 内容与 grub.cfg）
#   --no-serial   grub.cfg 不加 console=ttyS0,115200（无串口场景）
#   --yes         跳过 E 阶段交互确认
#   --grub-efi F  注入宿主预构建 BOOTX64.EFI（跳过母盘内 grub2-mkimage）。
#                 低版本 grub 产物在 SAN 引导路径实测卡死（Debian 12 grub 2.06，
#                 2026-09-04，见 docs/zh/distributions.md），需 2.12+；
#                 默认注入脚本内嵌的 GRUB 2.14 产物（零宿主依赖）。
#   --mirror URL  dnf 镜像（默认 http://mirrors.aliyun.com/fedora）
#   --keep-sources 保留母盘原 dnf 源（不切镜像）
#   -h, --help    显示帮助
# ==== END USAGE ====
#
# 幂等：重复运行安全（已处理的步骤自动跳过；E 阶段重跑会刷新 ESP 内容）。
# 注意：E 阶段把盘转为 4K 语义后，512 逻辑块环境（VMware/QEMU 默认）不再可读，
#       仅 SAN（nvmet 4K 块）或 4Kn 环境可引导——这是母盘 SAN 形态的预期结果。
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# COMPONENT_DIR 在参数解析后推导：-d 必须优先于默认值生效
KVER=$(uname -r)   # Fedora 44 自带内核（6.19，已含 CONFIG_NVME_AUTH）
ESP_VOLID=855B91DF
ESP_UUID=855B-91DF
CONSOLE=console=ttyS0,115200
GRUB_ARGS="net.ifnames=0 biosdevname=0 ip=dhcp rd.neednet=1 nbft_auto systemd.mask=NetworkManager.service systemd.mask=systemd-networkd.service"
DO_DISK=1
YES=0
GRUB_EFI=
MIRROR="http://mirrors.aliyun.com/fedora"
KEEP_SOURCES=0
MENU_LABEL="Fedora 44"
INITRD_SRC_TEMPLATE="/boot/initramfs-@KVER@.img"
INITRD_ESP_NAME_TEMPLATE="initramfs-@KVER@.img"
IDENTITY_DIRS=(/etc/systemd/network)
PHASE_C_NETWORKD=1
NBFT_SHELL=dash   # Fedora installs dash; nbft-connect must run under dash/ash semantics

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
# ---------------------------------------------------------------- A ----------
phase_a() {
    log "[A] 系统与内核（自带内核，免换内核）"
    apply_sources
    # 禁用安装介质残留 repo（无光驱环境 dnf 会因 baseurl 不可达报错）
    for rf in /etc/yum.repos.d/*.repo; do
        [ -f "$rf" ] || continue
        if grep -qE 'InstallMedia|^baseurl=.*cdrom:|^baseurl="cdrom:' "$rf" 2>/dev/null; then
            sed -i 's/^enabled=1/enabled=0/' "$rf"
            echo "    disabled media repo: $rf"
        fi
    done
    # dracut-network：initrd 网络模块（11systemd-networkd/40network 等，基础 dracut 不含）
    # systemd-networkd：networkd 二进制包（11systemd-networkd 模块 require_binaries 依赖）
    dnf install -y nvme-cli dash jq grub2-tools dosfstools dracut-network systemd-networkd \
        python3 tar xz xfsprogs e2fsprogs keyutils ktls-utils
    # 内核段 TLS 工具链（缺一即失败，不静默退回明文）
    [ -x /usr/sbin/tlshd ] || { echo "ERROR: ktls-utils/tlshd not installed; kernel-stage TLS unavailable"; exit 1; }
    [ -x /usr/bin/keyctl ] || { echo "ERROR: keyutils/keyctl not installed; TLS-PSK injection unavailable"; exit 1; }
    # 内核 NVME_AUTH 校验（Fedora 44 自带内核，无需换内核）
    CONF="/boot/config-${KVER}"
    [ -f "$CONF" ] || { echo "ERROR: $CONF 不存在"; exit 1; }
    grep -q '^CONFIG_NVME_AUTH=m' "$CONF" || { echo "ERROR: $CONF 中 CONFIG_NVME_AUTH 不是 =m"; exit 1; }
    echo "    CONFIG_NVME_AUTH=m OK"
}

apply_sources() {
    if [ "$KEEP_SOURCES" = 1 ]; then
        echo "    保留母盘原 dnf 源(--keep-sources)"
        return
    fi
    local m=${MIRROR:-http://mirrors.aliyun.com/fedora}
    echo "    切换 dnf 源 -> $m(fedora + updates)"
    # 官方 repo 的 metalink 换为镜像 baseurl（$releasever/$basearch 保留，由 dnf 展开）
    local rf base
    for rf in /etc/yum.repos.d/fedora.repo /etc/yum.repos.d/fedora-updates.repo; do
        [ -f "$rf" ] || continue
        cp -n "$rf" "$rf.golden-bak" 2>/dev/null || true
        case "$rf" in
        *fedora-updates.repo) base="$m/updates/\$releasever/Everything/\$basearch/" ;;
        *) base="$m/releases/\$releasever/Everything/\$basearch/os/" ;;
        esac
        sed -i "s|^metalink=|#metalink=|; s|^#baseurl=http://download.example/pub/fedora/linux/[^ ]*|baseurl=$base|" "$rf"
        echo "    switched: $rf"
    done
    # 其余 repo（cisco-openh264 / updates-testing 等）统一置停：避免 metalink 依赖，
    # 与 Debian 变体把 sources.list.d 移走的处理等价。
    local of
    for of in /etc/yum.repos.d/*.repo; do
        case "$of" in
        */fedora.repo | */fedora-updates.repo) continue ;;
        esac
        [ -f "$of" ] || continue
        cp -n "$of" "$of.golden-bak" 2>/dev/null || true
        sed -i 's/^enabled=1$/enabled=0/' "$of"
    done
}

# ---------------------------------------------------------------- B ----------
phase_b() {
    log "[B] initramfs seed module (dracut 95nbft: NBFT/NBCT + kernel TLS)"
    golden_check_nbft_component
    install -m 0755 "$COMPONENT_DIR/nbft-connect" /usr/libexec/nbft-connect
    golden_install_tlshd_config
    install_dracut_module
    # --no-hostonly keeps the image portable; --drivers replaces its full
    # driver set with the shared wired NIC and storage/crypto whitelist.
    # --omit nvmf：发行版原生 95nvmf 只做无凭据的 connect-all --nbft，与本模块的
    # NBCT 带凭据连接互斥，必须排除以免先发明文/无认证握手。
    # --omit drm：initrd 只用串口控制台，drm 模块会拉入 amdgpu 等 GPU 驱动。
    local drivers img=$INITRD_SRC list nbft_count netd_count tls_count
    drivers=$(golden_dracut_wired_drivers)
    [ -n "$drivers" ] || { echo "ERROR: no wired dracut drivers available"; exit 1; }
    golden_dracut_wired_network_module "$drivers"
    dracut --force --no-hostonly --drivers "$drivers" \
        --add "nbft lvm" --omit "nvmf drm" --kver "$KVER"
    list=$(mktemp "${TMPDIR:-/tmp}/golden-initrd.XXXXXX")
    lsinitrd "$img" > "$list" 2>/dev/null || {
        rm -f "$list"
        echo "ERROR: lsinitrd failed for $img"
        exit 1
    }
    nbft_count=$(grep -c 'nbft' "$list" || true)
    netd_count=$(grep -c 'systemd-networkd' "$list" || true)
    tls_count=$(grep -c 'tlshd' "$list" || true)
    [ "$nbft_count" -gt 0 ] || { echo "ERROR: $img 中未找到 nbft 组件"; exit 1; }
    [ "$netd_count" -gt 0 ] || { echo "ERROR: $img 中未找到 systemd-networkd（initrd DHCP 承担者）"; exit 1; }
    [ "$tls_count" -gt 0 ] || { echo "ERROR: $img 中未找到 tlshd（内核段 TLS 必需）"; exit 1; }
    golden_verify_initramfs "$img" "$list" "$KVER" "dracut"
    rm -f "$list"
    echo "    $img already carries nbft ($nbft_count items), systemd-networkd ($netd_count items), tlshd ($tls_count items)"
}

# Fedora dracut integration: the only differences from the NetworkManager
# variants are the DHCP owner (systemd-networkd + 09-nbft.network) and the
# interpreter used for nbft-connect (dash is installed and required here).
install_dracut_module() {
    local mod=/usr/lib/dracut/modules.d/95nbft
    mkdir -p "$mod"
    cat > "$mod/module-setup.sh" <<'EOF'
#!/bin/bash
# 95nbft - NBFT/NBCT consumer (golden image injection, Fedora variant).
# dracut-108 has no network-legacy: initrd DHCP is owned by systemd-networkd
# (systemd-network-management + the 09-nbft.network static configuration).
check() { [ -x /usr/libexec/nbft-connect ] || return 1; return 0; }
depends() { echo "rootfs-block systemd-network-management"; }
install() {
    # dd extracts the fixed-width NBCT fields; keyctl/tlshd are required for
    # kernel-side TLS; dash runs nbft-connect (see the hook header).
    inst_multiple -o nvme dash jq ip udevadm modprobe grep awk sed cut tr dd head wc od stat keyctl tlshd
    inst_simple /usr/libexec/nbft-connect
    inst_simple "$moddir/09-nbft.network" "/usr/lib/systemd/network/09-nbft.network"
    inst_multiple -o /etc/tlshd.conf /etc/tlshd/config
    # GnuTLS @SYSTEM priority comes from crypto-policies; without it tlshd exits
    # with gnutls -50 (EINVAL) and kernel TLS fails.
    if [ -e /etc/crypto-policies/back-ends/gnutls.config ]; then
        inst_simple "$(readlink -f /etc/crypto-policies/back-ends/gnutls.config)" \
            /etc/crypto-policies/back-ends/gnutls.config
    fi
    instmods nvme_fabrics nvme_tcp nvme_auth tls nvme-keyring
    # Two hook phases: initqueue/settled runs when a root wait stays, pre-mount
    # runs when there is no queue; /run/nbft-done makes them idempotent.
    inst_hook initqueue/settled 30 "$moddir/nbft.sh"
    inst_hook pre-mount 30 "$moddir/nbft.sh"
}
EOF
    cat > "$mod/09-nbft.network" <<'EOF'
# 95nbft: initrd network configuration (the 09-* prefix precedes the
# network-generator 10-* files). The golden image always boots with ip=dhcp;
# NBFT static entries are applied on top by nbft.sh.
[Match]
Type=ether

[Network]
DHCP=ipv4
KeepConfiguration=yes

[DHCPv4]
SendRelease=no
EOF
    golden_write_nbft_hook "$mod" systemd-networkd.service dash
    chmod 0755 "$mod/module-setup.sh"
    echo "    wrote dracut module $mod (module-setup.sh + nbft.sh + 09-nbft.network)"
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
