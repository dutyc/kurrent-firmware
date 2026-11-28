#!/bin/bash
# golden-image-setup-almalinux10.sh - 一键母盘定制（AlmaLinux 10.2 / RHEL 系 → NVMe-oF SAN 引导母盘）
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
# RHEL 系（AlmaLinux 10.2 实测）适配要点：
#   - dracut-107 无 systemd-networkd；initrd 网络由 NetworkManager 承担
#     （dracut-network 提供 35network-manager + nm-initrd-generator）；
#   - 发行版无 dash：nbft-connect 字段提取显式去 NUL，bash 下语义一致；
#   - 内核段 TLS：tlshd（ktls-utils）与 keyctl 进 initrd，连接改用 --tls；
#   - 内核/initrd 路径 /boot/vmlinuz-<ver>、/boot/initramfs-<ver>.img，
#     GRUB 工具为 grub2-mkimage / grub2-mkconfig；
#   - 原生 dracut 95nvmf 会做无凭据的 connect-all --nbft，构建时显式 --omit。
#
# 用法（在母盘系统内以 root 运行）：
#   sudo bash golden/almalinux10/golden-image-setup-almalinux10.sh
#   sudo bash golden/almalinux10/golden-image-setup-almalinux10.sh --skip-disk --yes
#
# 选项：
#   -d DIR        initramfs-nbft 组件目录（默认脚本同仓库的 ../../initramfs-nbft;
#                 仓库组件不可用时自动释放脚本内嵌组件，单文件即可分发到母盘运行）
#   -k VER        内核版本（默认 uname -r）
#   --skip-disk   跳过 E 的 GPT/ESP 重建（仍刷新 ESP 内容与 grub.cfg）
#   --no-serial   grub.cfg 不加 console=ttyS0,115200（无串口场景）
#   --yes         跳过 E 阶段交互确认
#   --grub-efi F  注入宿主预构建 BOOTX64.EFI（跳过母盘内 grub2-mkimage）
#   --mirror URL  dnf 镜像（默认 https://repo.huaweicloud.com/almalinux）
#   --keep-sources 保留母盘原 dnf 源（不切镜像）
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
MIRROR="https://repo.huaweicloud.com/almalinux"
KEEP_SOURCES=0
MENU_LABEL="AlmaLinux 10"
INITRD_SRC_TEMPLATE="/boot/initramfs-@KVER@.img"
INITRD_ESP_NAME_TEMPLATE="initramfs-@KVER@.img"
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
    # 禁用安装介质残留 repo（无光驱环境 dnf 会因 baseurl 不可达报错）
    for rf in /etc/yum.repos.d/*.repo; do
        [ -f "$rf" ] || continue
        if grep -qE 'InstallMedia|^baseurl=.*cdrom:|^baseurl="cdrom:' "$rf" 2>/dev/null; then
            sed -i 's/^enabled=1/enabled=0/' "$rf"
            echo "    disabled media repo: $rf"
        fi
    done
    # RHEL 系 initrd 网络栈：dracut-network 提供 35network-manager / 40network，
    # NetworkManager 与 nm-initrd-generator 是 ip=dhcp 的实际承担者。
    dnf install -y nvme-cli jq grub2-tools dosfstools dracut-network NetworkManager \
        python3 tar xz xfsprogs e2fsprogs keyutils ktls-utils
    # 内核段 TLS 工具链（缺一即失败，不静默退回明文）
    [ -x /usr/sbin/tlshd ] || { echo "ERROR: ktls-utils/tlshd not installed; kernel-stage TLS unavailable"; exit 1; }
    [ -x /usr/bin/keyctl ] || { echo "ERROR: keyutils/keyctl not installed; TLS-PSK injection unavailable"; exit 1; }
    # 内核配置校验：认证与 TLS 都是模块内建能力
    CONF="/boot/config-${KVER}"
    [ -f "$CONF" ] || { echo "ERROR: $CONF 不存在"; exit 1; }
    grep -q '^CONFIG_NVME_AUTH=m' "$CONF" || { echo "ERROR: $CONF 中 CONFIG_NVME_AUTH 不是 =m"; exit 1; }
    grep -q '^CONFIG_NVME_TCP_TLS=y' "$CONF" || { echo "ERROR: $CONF 中 CONFIG_NVME_TCP_TLS 不是 =y"; exit 1; }
    echo "    CONFIG_NVME_AUTH=m / CONFIG_NVME_TCP_TLS=y OK"
}

apply_sources() {
    if [ "$KEEP_SOURCES" = 1 ]; then
        echo "    保留母盘原 dnf 源(--keep-sources)"
        return
    fi
    local m=${MIRROR:-https://repo.huaweicloud.com/almalinux}
    echo "    切换 dnf 源 -> $m"
    # AlmaLinux repo 的节名是小写（baseos/appstream/crb），镜像目录是
    # CamelCase（BaseOS/AppStream/CRB）；直接按节名拼 baseurl 会 404，
    # 故用显式映射改写核心节，并停用 debuginfo/source/附加仓库。
    python3 - "$m" <<'PYEOF'
import glob, re, sys
mirror = sys.argv[1].rstrip('/')
dirs = {'baseos': 'BaseOS', 'appstream': 'AppStream', 'crb': 'CRB', 'extras': 'extras'}
keep = set(dirs)
for path in glob.glob('/etc/yum.repos.d/almalinux*.repo'):
    out, section = [], ''
    for ln in open(path).readlines():
        m = re.match(r'\[([^]]+)\]', ln.strip())
        if m:
            section = m.group(1)
        if re.match(r'\s*#?\s*baseurl=', ln):
            if section in dirs:
                out.append(f'baseurl={mirror}/$releasever/{dirs[section]}/$basearch/os/\n')
            else:
                out.append(ln)
        elif re.match(r'\s*metalink=', ln):
            out.append('#' + ln.lstrip())
        elif re.match(r'\s*enabled=', ln):
            out.append(f'enabled={1 if section in keep else 0}\n')
        else:
            out.append(ln)
    open(path, 'w').writelines(out)
    print(f'    refreshed {path}')
PYEOF
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
