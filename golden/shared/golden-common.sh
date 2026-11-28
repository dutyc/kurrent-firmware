# shellcheck shell=bash
# golden-common.sh - shared stages for the RHEL/SUSE golden image setup scripts.
#
# Sourced by golden/{almalinux10,fedora44,opensuse-leap16}/golden-image-setup-*.sh.
# The distributions keep their own A/B stages (package manager, kernel/initrd,
# dracut modules, network stack); this library owns the A-F stages that must
# behave identically: argument parsing, C/D/F, the whole E disk layout, and the
# in-initrd 95nbft runtime hook (including wait_ipv4/start_tlshd).
#
# Callers must set before golden_init:
#   SCRIPT_DIR, KVER, MIRROR, GRUB_ARGS, MENU_LABEL,
#   INITRD_SRC_TEMPLATE, INITRD_ESP_NAME_TEMPLATE (@KVER@ is substituted),
#   IDENTITY_DIRS (array)
# Optional overrides:
#   VMLINUZ_SRC_TEMPLATE (default /boot/vmlinuz-@KVER@),
#   VMLINUZ_ESP_NAME_TEMPLATE (default vmlinuz-@KVER@; Arch images use the
#   unversioned /boot/vmlinuz-linux),
#   NBFT_SHELL (default bash), GRUB_CFG (default /boot/grub2/grub.cfg),
#   GRUB_MKCONFIG (default grub2-mkconfig; Arch uses grub-mkconfig)

ESP_VOLID=${ESP_VOLID:-855B91DF}
ESP_UUID=${ESP_UUID:-855B-91DF}
CONSOLE=${CONSOLE:-console=ttyS0,115200}
DO_DISK=${DO_DISK:-1}
YES=${YES:-0}
KEEP_SOURCES=${KEEP_SOURCES:-0}
GRUB_EFI=${GRUB_EFI:-}
VMLINUZ_SRC_TEMPLATE=${VMLINUZ_SRC_TEMPLATE:-/boot/vmlinuz-@KVER@}
VMLINUZ_ESP_NAME_TEMPLATE=${VMLINUZ_ESP_NAME_TEMPLATE:-vmlinuz-@KVER@}
NBFT_SHELL=${NBFT_SHELL:-bash}
GRUB_CFG=${GRUB_CFG:-/boot/grub2/grub.cfg}
MKFS_FAT_OPTS=${MKFS_FAT_OPTS:--S 4096}
GRUB_MKIMAGE=${GRUB_MKIMAGE:-grub2-mkimage}
GRUB_MKCONFIG=${GRUB_MKCONFIG:-grub2-mkconfig}
GRUB_REGEN=${GRUB_REGEN:-mkconfig}
GRUB_DEFAULT_ONLY=${GRUB_DEFAULT_ONLY:-0}
GRUB_DROP_WORDS=${GRUB_DROP_WORDS:-quiet rhgb}
PHASE_C_NETWORKD=${PHASE_C_NETWORKD:-0}
PHASE_E_LVM_FALLBACK=${PHASE_E_LVM_FALLBACK:-1}
PHASE_E_LVM_PARAM=${PHASE_E_LVM_PARAM:-1}

log() { echo "==> $*"; }

# Single-file fallback extracts temporary trees; remove them on exit.
GOLDEN_TMP_DIRS=()
golden_cleanup_tmp() {
    local d
    for d in ${GOLDEN_TMP_DIRS[@]+"${GOLDEN_TMP_DIRS[@]}"}; do
        [ -n "$d" ] && rm -rf "$d"
    done
}
trap golden_cleanup_tmp EXIT

usage() {
    sed -n '2,/^# ==== END USAGE/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d'
    exit 0
}

golden_parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
        -d) COMPONENT_DIR=$2; shift 2 ;;
        -k) KVER=$2; shift 2 ;;
        --skip-disk) DO_DISK=0; shift ;;
        --no-serial) CONSOLE=; shift ;;
        --yes) YES=1; shift ;;
        --grub-efi) GRUB_EFI=$2; shift 2 ;;
        --mirror) MIRROR=$2; shift 2 ;;
        --keep-sources) KEEP_SOURCES=1; shift ;;
        -h | --help) usage ;;
        *) echo "ERROR: unknown option: $1" >&2; exit 1 ;;
        esac
    done
}

release_embedded_components() {
    [ -n "$EMBED_B64_CONNECT" ] || { echo "ERROR: no embedded components (run bash golden/shared/embed-components.py)" >&2; return 1; }
    local d; d=$(mktemp -d /tmp/nbft-components.XXXXXX)
    echo "$EMBED_B64_CONNECT" | base64 -d > "$d/nbft-connect"
    mkdir -p "$d/initramfs/hooks" "$d/initramfs/scripts/local-top"
    echo "$EMBED_B64_HOOK" | base64 -d > "$d/initramfs/hooks/nbft"
    echo "$EMBED_B64_LOCALTOP" | base64 -d > "$d/initramfs/scripts/local-top/nbft"
    chmod 0755 "$d/nbft-connect" "$d/initramfs/hooks/nbft" "$d/initramfs/scripts/local-top/nbft"
    printf '%s\n' "$d"
}

golden_resolve_components() {
    # 默认组件目录：显式 -d > 仓库相对目录(开发态,组件改动即时生效) > 脚本内嵌(单文件分发)
    [ -n "${COMPONENT_DIR:-}" ] && return 0
    if [ -f "$SCRIPT_DIR/../../initramfs-nbft/nbft-connect" ] \
       && [ -f "$SCRIPT_DIR/../../initramfs-nbft/initramfs/hooks/nbft" ] \
       && [ -f "$SCRIPT_DIR/../../initramfs-nbft/initramfs/scripts/local-top/nbft" ]; then
        COMPONENT_DIR=$(cd "$SCRIPT_DIR/../../initramfs-nbft" && pwd)
    else
        echo "    repository components unavailable, extracting the embedded copies..."
        COMPONENT_DIR=$(release_embedded_components) || exit 1
        # release runs in a command substitution; register the tree here so the
        # EXIT trap in the parent shell removes it.
        GOLDEN_TMP_DIRS+=("$COMPONENT_DIR")
    fi
}

golden_check_nbft_component() {
    [ -f "$COMPONENT_DIR/nbft-connect" ] || {
        echo "ERROR: missing $COMPONENT_DIR/nbft-connect (see -d)"; exit 1
    }
    grep -q -- '--hostid' "$COMPONENT_DIR/nbft-connect" || {
        echo "ERROR: nbft-connect lacks the hostid fix (doc 3.1); update the component"; exit 1
    }
}

golden_install_tlshd_config() {
    # tlshd 在配置文件缺失时会立刻退出，留空文件即可（ktls-utils 语义）
    mkdir -p /etc/tlshd
    [ -e /etc/tlshd/config ] || : > /etc/tlshd/config
}

golden_init() {
    golden_parse_args "$@"
    golden_resolve_components
    [ "$(id -u)" = 0 ] || { echo "ERROR: run as root (inside the golden image)"; exit 1; }
    case "$KVER" in
    '') echo "ERROR: empty kernel version (-k or uname -r)" >&2; exit 1 ;;
    esac
    INITRD_SRC=${INITRD_SRC_TEMPLATE//@KVER@/$KVER}
    INITRD_ESP_NAME=${INITRD_ESP_NAME_TEMPLATE//@KVER@/$KVER}
    VMLINUZ_SRC=${VMLINUZ_SRC_TEMPLATE//@KVER@/$KVER}
    VMLINUZ_ESP_NAME=${VMLINUZ_ESP_NAME_TEMPLATE//@KVER@/$KVER}
}

# ---------------------------------------------------------------- C ----------
phase_c() {
    log "[C] system configuration (fstab / hostname)"
    python3 - <<'PYEOF'
import shutil, time
path = '/etc/fstab'
lines = open(path).readlines()
out, changed = [], False
for ln in lines:
    if ln.startswith('#'):
        out.append(ln)
        continue
    f = ln.split()
    if len(f) < 2:
        out.append(ln)
        continue
    if f[1] == '/boot/efi':
        out.append('#' + ln)              # 防 boot-efi.mount 失败 → emergency mode
        changed = True
        continue
    out.append(ln)
if changed:
    shutil.copy(path, f"{path}.golden-{time.strftime('%Y%m%d%H%M%S')}.bak")
    open(path, 'w').writelines(out)
    print('    fstab: commented out /boot/efi (backup .golden-*.bak)')
else:
    print('    fstab: /boot/efi already commented out or absent')
PYEOF

    rootdev=$(lsblk -no SOURCE / 2>/dev/null || findmnt -no SOURCE / 2>/dev/null || true)
    case "$rootdev" in
    UUID=*)
        echo "    root already mounted by UUID ($rootdev)"
        ;;
    /dev/*)
        rootuuid=$(blkid -s UUID -o value "$rootdev")
        [ -n "$rootuuid" ] || { echo "ERROR: cannot read the UUID of $rootdev"; exit 1; }
        if grep -qE "^[^#].*[[:space:]]/[[:space:]]" /etc/fstab && [ -z "$(awk '$2=="/" && $1 !~ /^UUID=/' /etc/fstab)" ]; then
            echo "    fstab / entry already uses UUID=$rootuuid"
        else
            python3 - "$rootuuid" <<'PYEOF'
import shutil, sys, time
uuid, path = sys.argv[1], '/etc/fstab'
lines, out, changed = open(path).readlines(), [], False
for ln in lines:
    f = ln.split()
    if not ln.startswith('#') and len(f) >= 2 and f[1] == '/' and not f[0].startswith('UUID='):
        f[0] = f'UUID={uuid}'
        ln = '\t'.join(f) + '\n'
        changed = True
    out.append(ln)
if changed:
    shutil.copy(path, f"{path}.golden-{time.strftime('%Y%m%d%H%M%S')}.bak")
    open(path, 'w').writelines(out)
    print(f'    fstab: / entry pinned to UUID={uuid} (backup .golden-*.bak)')
else:
    print(f'    fstab: / entry already compliant (UUID={uuid})')
PYEOF
        fi
        ;;
    *) echo "WARN: unknown root device ($rootdev), skipping the UUID check" ;;
    esac

    if [ "$PHASE_C_NETWORKD" = 1 ]; then
        mkdir -p /etc/systemd/network
        if [ -f /etc/systemd/network/10-dhcp.network ]; then
            echo "    10-dhcp.network already present"
        else
            cat > /etc/systemd/network/10-dhcp.network <<'EOF'
[Match]
Name=e*

[Network]
DHCP=yes
EOF
            echo "    wrote 10-dhcp.network (DHCP on all links)"
        fi
    fi

    # hostname 去标识：真实 hostname 由控制面在引导链中下发，母盘不留克隆身份。
    printf 'localhost\n' > /etc/hostname
    echo "    hostname placeholder: localhost (the control plane sets the production name)"
}

# ---------------------------------------------------------------- D ----------
phase_d() {
    log "[D] GRUB boot parameters"
    local grub=/etc/default/grub
    [ -f "$grub" ] || { echo "ERROR: $grub missing"; exit 1; }
    python3 - "$GRUB_ARGS" "$GRUB_DEFAULT_ONLY" "$GRUB_DROP_WORDS" <<'PYEOF'
import shutil, sys, time
path = '/etc/default/grub'
extra = sys.argv[1]
default_only = sys.argv[2] == '1'
drop = set(sys.argv[3].split())
keys = ('GRUB_CMDLINE_LINUX_DEFAULT',) if default_only else (
    'GRUB_CMDLINE_LINUX', 'GRUB_CMDLINE_LINUX_DEFAULT')
lines, out, changed, found = open(path).readlines(), [], False, False
for ln in lines:
    key = next((k for k in keys if ln.startswith(k + '=')), None)
    if key is None:
        out.append(ln)
        continue
    found = True
    val = ln[len(key) + 1:].strip()
    quoted = val.startswith('"') and val.endswith('"') and len(val) >= 2
    inner = val[1:-1] if quoted else val
    toks = [t for t in inner.split() if t not in drop]
    for t in extra.split():
        if t not in toks:
            toks.append(t)
    new = ' '.join(toks)
    if new == inner:
        out.append(ln)  # 无变化：保持原文（幂等）
    else:
        out.append(f'{key}="{new}"\n')
        changed = True
if not found:
    out.append(f'GRUB_CMDLINE_LINUX_DEFAULT="{extra}"\n')
    changed = True
if changed:
    shutil.copy(path, f"{path}.golden-{time.strftime('%Y%m%d%H%M%S')}.bak")
    open(path, 'w').writelines(out)
    print('    GRUB cmdline updated (SAN parameters added, quiet/rhgb removed, backup .golden-*.bak)')
else:
    print('    cmdline already compliant (SAN parameters present, no quiet/rhgb)')
PYEOF
    if [ "$GRUB_REGEN" = update-grub ]; then
        update-grub
        echo "    update-grub done"
    else
        # 盘内 grub.cfg 再生成（SAN 实引导走 ESP/grub.cfg，此处保盘内一致性）。
        # Arch 安装未创建 /boot/grub，先补目录，避免 grub-mkconfig 写临时文件失败。
        mkdir -p "$(dirname "$GRUB_CFG")"
        "$GRUB_MKCONFIG" -o "$GRUB_CFG" >/dev/null || \
            echo "WARN: $GRUB_MKCONFIG failed (non-fatal: SAN boot uses ESP/grub.cfg)"
        echo "    $GRUB_MKCONFIG done"
    fi
}

# ---------------------------------------------------------------- E ----------
# 定位整盘（沿 PKNAME 逐级上溯）；无法回溯时输出空。
# 实现注记（util-linux 实测）：默认输出带树形符号（├─vda1）且行序不保证，
# 带 -d 时连分区行的 PKNAME 也被清空；故用 -r（raw）按“设备名取自身行”查询。
# Debian/Ubuntu 原实现用单列 `lsblk -no PKNAME`；在 vda1→vda、dm→分区等
# 常见链路上与本实现等价，且本实现对多级链路与树形输出更稳健，故统一。
root_disk() {
    local name=${1#/dev/} p i
    [ -n "$name" ] || return 0
    p=$(lsblk -rno NAME,PKNAME 2>/dev/null | awk -v d="$name" '$1 == d { print $2; exit }')
    [ -n "$p" ] || return 0
    name=$p
    for i in 1 2 3 4 5 6 7 8; do
        p=$(lsblk -rno NAME,PKNAME 2>/dev/null | awk -v d="$name" '$1 == d { print $2; exit }')
        [ -n "$p" ] || break
        name=$p
    done
    echo "/dev/$name"
}

# 定位 ESP：优先 /boot/efi 挂载源，否则按分区类型找 EFI System
find_esp() {
    local mnt
    mnt=$(findmnt -no SOURCE /boot/efi 2>/dev/null || true)
    [ -n "$mnt" ] && [ -b "$mnt" ] && { echo "$mnt"; return; }
    lsblk -no PATH,PARTTYPENAME | awk '$2 ~ /^EFI/ {print $1; exit}'
}

# 输出 512 / 4096 / none。统一用 od 转十六进制比对：Debian/Ubuntu 原实现把
# 二进制签名放进命令替换，bash 会告警并丢弃 NUL；ASCII 比对结果一致，od 更稳健。
gpt_sector() {
    local disk=$1 h4 h5
    h4=$(dd if="$disk" bs=1 skip=4096 count=8 2>/dev/null | od -An -tx1 | tr -d ' \n')
    h5=$(dd if="$disk" bs=1 skip=512 count=8 2>/dev/null | od -An -tx1 | tr -d ' \n')
    if [ "$h4" = "4546492050415254" ]; then
        echo 4096
    elif [ "$h5" = "4546492050415254" ]; then
        echo 512
    else
        echo none
    fi
}

esp_is_4k_volid() { # $1 设备：4K FAT32 且 volid=855B91DF → 0
    # FAT32 的卷标在 BPB 偏移 0x43；0x27 是 FAT12/16 的位置（本库写 0x43）。
    python3 - "$1" <<'PYEOF'
import sys
with open(sys.argv[1], 'rb') as f:
    b = f.read(512)
ok = len(b) == 512 and b[11] | (b[12] << 8) == 4096 and b[67:71] == b'\xdf\x91\x5b\x85'
sys.exit(0 if ok else 1)
PYEOF
}

phase_e() {
    log "[E] disk layout (4K native GPT + 4K FAT32 ESP)"
    local rootdev disk esp espsize
    # 兼容链：个别环境 lsblk 不支持 SOURCE 列（或 chroot 内无设备上下文）时降级 findmnt，
    # 均失败则跳过 root UUID 校验（保持安全）
    rootdev=$(lsblk -no SOURCE / 2>/dev/null || findmnt -no SOURCE / 2>/dev/null || true)
    esp=$(find_esp)
    [ -b "$esp" ] || { echo "ERROR: cannot locate the ESP partition"; exit 1; }

    [ "$DO_DISK" = 1 ] && [ "$YES" != 1 ] && {
        read -r -p "    Rewrite the GPT with 4K sectors and rebuild the ESP; its content will be refreshed. Continue? [y/N] " ans || ans=
        case "$ans" in y | Y) ;; *) DO_DISK=0 ;; esac
    }
    if [ "$DO_DISK" = 1 ]; then
        if [ "$(ss -tn 2>/dev/null | awk 'NR>1 {print $4}' | grep -c ':4420$' || true)" -gt 0 ]; then
            echo "ERROR: active NVMe/TCP connection on :4420, disconnect it first"; exit 1
        fi
        # 盘 = root 所在整盘。LVM/dm root 的 PKNAME 为空；RHEL/SUSE 安装器默认
        # LVM 布局，故退化为 ESP 分区所在盘（母盘同盘布局，E 的目标就是引导盘）。
        disk=$(root_disk "$rootdev")
        if [ "$PHASE_E_LVM_FALLBACK" = 1 ]; then
            [ -n "$disk" ] || disk=$(root_disk "$esp")
            [ -b "$disk" ] || { echo "ERROR: cannot locate the boot disk (root=$rootdev esp=$esp)"; exit 1; }
        else
            [ -b "$disk" ] || { echo "ERROR: cannot locate the disk holding root ($disk)"; exit 1; }
        fi
        espsize=$(lsblk -bno SIZE "$esp")
        echo "    root: $rootdev  disk: $disk  ESP: $esp ($((espsize / 1024 / 1024)) MiB)"

        # 4K FAT32 需要 >= 65525 簇（4K 簇 → 约 256 MiB），不足则拒绝（不自动扩分区）
        if [ "$espsize" -lt $((256 * 1024 * 1024)) ]; then
            echo "ERROR: ESP is only $((espsize / 1024 / 1024)) MiB; 4K FAT32 needs >= 256 MiB (doc 6.2), enlarge it first"; exit 1
        fi

        local sec
        sec=$(gpt_sector "$disk")
        case "$sec" in
        4096) echo "    GPT already uses 4K sectors, skipping the conversion" ;;
        512)  convert_gpt_4k "$disk" ;;
        none) echo "ERROR: no GPT found on $disk (neither 512 nor 4K)"; exit 1 ;;
        esac

        # ESP 重建（4K FAT32，固定 volid；fstab 已注释故系统内不再挂载）
        umount /boot/efi 2>/dev/null || true
        if esp_is_4k_volid "$esp"; then
            echo "    ESP already 4K FAT32 (volid $ESP_VOLID), skipping mkfs"
        else
            # Debian/Ubuntu 的 cloud img ESP 可能只有 ~106 MiB 且被识别为 FAT16，
            # 故 Debian 变体显式 -F 32；RHEL/SUSE 用默认探测。
            mkfs.fat $MKFS_FAT_OPTS "$esp" >/dev/null
            # FAT32 的 volid 固定在 BPB 偏移 0x43（与 sector size 无关）;
            # mkfs.fat 4.2 的 -i 不生效,因此格式化后直接补写。注意: 偏移 39(0x27)
            # 是历史错误位置,会破坏 FAT32 sectors 字段导致 EDK2 拒挂(0x7f22208e)。
            python3 - "$esp" "$ESP_VOLID" <<'PYEOF'
import struct, sys
with open(sys.argv[1], 'r+b') as f:
    f.seek(0x43)
    f.write(struct.pack('<I', int(sys.argv[2], 16)))
v = sys.argv[2]
print(f'    volid written at BPB 0x43 ({v[:4]}-{v[4:]})')
PYEOF
            echo "    ESP rebuilt as 4K FAT32 (volid $ESP_VOLID)"
        fi
    else
        # --skip-disk 只跳过 GPT/ESP 重建，ESP 内容仍每次刷新：
        # 新 initrd 不落 ESP 是"改动不生效"的最常见来源（AGENTS §9）。
        echo "    --skip-disk: GPT conversion and ESP rebuild skipped, content refreshed"
    fi

    [ -f "$VMLINUZ_SRC" ] || { echo "ERROR: $VMLINUZ_SRC missing"; exit 1; }
    [ -f "$INITRD_SRC" ] || { echo "ERROR: $INITRD_SRC missing"; exit 1; }

    if ! findmnt /boot/efi >/dev/null 2>&1; then
        mkdir -p /boot/efi
        mount "$esp" /boot/efi
        echo "    mounted ESP at /boot/efi"
    fi
    find /boot/efi -mindepth 1 -maxdepth 1 -exec rm -rf {} +

    cp -a "$VMLINUZ_SRC" "/boot/efi/$VMLINUZ_ESP_NAME"
    cp -a "$INITRD_SRC" "/boot/efi/$INITRD_ESP_NAME"
    mkdir -p /boot/efi/EFI/BOOT

    local grub_mods="normal search search_fs_uuid part_gpt part_msdos ext2 fat linux xzio gzio serial terminal echo ls configfile test"
    if [ -z "${GRUB_EFI:-}" ] && [ -n "$EMBED_B64_BOOTX64" ]; then
        # 默认: 脚本内嵌的 GRUB 2.14 产物(实测引导基线),零宿主依赖
        GRUB_EFI=$(mktemp /tmp/BOOTX64.XXXXXX.EFI)
        echo "$EMBED_B64_BOOTX64" | base64 -d > "$GRUB_EFI"
        echo "    using the embedded GRUB 2.14 image"
    fi
    if [ -n "${GRUB_EFI:-}" ]; then
        [ -f "$GRUB_EFI" ] || { echo "ERROR: --grub-efi file missing: $GRUB_EFI"; exit 1; }
        install -m 0644 "$GRUB_EFI" /boot/efi/EFI/BOOT/BOOTX64.EFI
        echo "    BOOTX64.EFI injected from $GRUB_EFI"
    else
        # 发行版 grub-mkimage 版本门控：Debian 12 自带 2.06 的产物在 SAN 引导路径
        # 实测卡死（发行版缺陷，与 4K 逻辑块无关；2026-09-04 实测，见文档 6.3）
        local gver
        gver=$("$GRUB_MKIMAGE" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1) || gver=""
        # 版本比较统一用 awk 数值比较（Debian 侧原先用 dpkg --compare-versions，
        # 对 2.x 形式结果一致）；< 2.12 的产物在 SAN 引导路径实测卡死。
        if [ -z "$gver" ] || ! awk -v v="$gver" 'BEGIN { exit !(v + 0 >= 2.12) }'; then
            echo "ERROR: golden image $GRUB_MKIMAGE version ${gver:-unknown} < 2.12; its BOOTX64.EFI hangs on the SAN boot path. Options:" >&2
            echo "       a) build it on the host (grub 2.14+) and inject with --grub-efi;" >&2
            echo "       b) upgrade grub2/grub-efi to >= 2.12 in the image and rerun." >&2
            exit 1
        fi
        if ! "$GRUB_MKIMAGE" -O x86_64-efi -o /boot/efi/EFI/BOOT/BOOTX64.EFI -p /EFI/BOOT $grub_mods; then
            echo "WARN: $GRUB_MKIMAGE with echo failed, retrying without it"
            grub_mods=${grub_mods/ echo/}
            "$GRUB_MKIMAGE" -O x86_64-efi -o /boot/efi/EFI/BOOT/BOOTX64.EFI -p /EFI/BOOT $grub_mods
        fi
        echo "    BOOTX64.EFI generated ($GRUB_MKIMAGE $gver)"
    fi

    local rootuuid rd_lvm="" vglv
    rootuuid=$(blkid -s UUID -o value "$rootdev")
    # LVM root（RHEL/SUSE 安装器默认布局）：需显式激活 VG/LV，否则 dracut 找不到 root
    if [ "$PHASE_E_LVM_PARAM" = 1 ] && lvs --noheadings -o vg_name,lv_name "$rootdev" >/dev/null 2>&1; then
        vglv=$(lvs --noheadings -o vg_name,lv_name "$rootdev" 2>/dev/null | awk '{print $1"/"$2}')
        [ -n "$vglv" ] && rd_lvm="rd.lvm.lv=$vglv"
    fi
    cat > /boot/efi/EFI/BOOT/grub.cfg <<EOF
set default=0
set timeout=5
menuentry '${MENU_LABEL} (SAN, ${KVER})' {
    search --no-floppy --fs-uuid --set=root ${ESP_UUID}
    linux /${VMLINUZ_ESP_NAME} root=UUID=${rootuuid} ro ${CONSOLE} ${GRUB_ARGS}${rd_lvm:+ $rd_lvm}
    initrd /${INITRD_ESP_NAME}
}
EOF
    echo "    grub.cfg written (ESP UUID=$ESP_UUID, root UUID=$rootuuid${rd_lvm:+, $rd_lvm})"

    umount /boot/efi
    echo "    ESP content ready, unmounted"
}

# 512 扇区 GPT → 4K 原生 GPT（设备版；与 diag/convert-gpt-4k.sh 同源，仅输入为块设备）
convert_gpt_4k() {
    local disk=$1 bak=/root/golden-image-gpt-512-$(date +%Y%m%d%H%M%S).bak size
    size=$(blockdev --getsize64 "$disk")
    echo "    GPT 512 -> 4K conversion (disk $((size / 1024 / 1024)) MiB), backup at $bak"
    python3 - "$disk" "$size" "$bak" <<'PYEOF'
import struct, sys, zlib
disk, size, bak = sys.argv[1], int(sys.argv[2]), sys.argv[3]
S4K = size // 4096
SECTOR = 4096

def crc(b): return zlib.crc32(b)

with open(disk, 'rb') as f:
    f.seek(512)
    hdr = f.read(512)
    if hdr[0:8] != b'EFI PART':
        sys.exit('ERROR: no GPT header at offset 512 (not a 512-sector GPT?)')
    disk_guid = hdr[56:72]
    elba = struct.unpack('<Q', hdr[72:80])[0]
    num = struct.unpack('<I', hdr[80:84])[0]
    esz = struct.unpack('<I', hdr[84:88])[0]
    f.seek(elba * 512)
    raw = f.read(num * esz)

parts = []
for i in range(num):
    e = raw[i*esz:(i+1)*esz]
    if e[0:16] == b'\x00' * 16: continue
    s, en, a = struct.unpack('<QQQ', e[32:56])
    if s * 512 % 4096 or (en + 1) * 512 % 4096:
        sys.exit('ERROR: partition not 4K-aligned, aborting')
    parts.append((e[0:16], e[16:32], s * 512 // 4096, (en + 1) * 512 // 4096 - 1, a, e[56:112]))

if not parts:
    sys.exit('ERROR: no partitions found')

old_backup_off = (size // 512 - 34) * 512
with open(disk, 'rb') as f:
    head = f.read(17408)                      # MBR + header + table
    f.seek(old_backup_off)
    tail = f.read(34 * 512)                   # on-disk backup GPT
with open(bak, 'wb') as g:
    g.write(head); g.write(tail)

def build_header(cur, bku, elba):
    h = bytearray(SECTOR)
    h[0:8] = b'EFI PART'
    struct.pack_into('<I', h, 8, 0x00010000)
    struct.pack_into('<I', h, 12, 92)
    struct.pack_into('<Q', h, 24, cur)
    struct.pack_into('<Q', h, 32, bku)
    struct.pack_into('<Q', h, 40, 34)
    struct.pack_into('<Q', h, 48, S4K - 35)
    h[56:72] = disk_guid
    struct.pack_into('<Q', h, 72, elba)
    struct.pack_into('<I', h, 80, 128)
    struct.pack_into('<I', h, 84, 128)
    return h

def build_table():
    tab = bytearray(128 * 128)
    for i, (t, g, s4k, e4k, a, name_raw) in enumerate(parts):
        e = tab[i*128:(i+1)*128]
        e[0:16] = t; e[16:32] = g
        struct.pack_into('<Q', e, 32, s4k)
        struct.pack_into('<Q', e, 40, e4k)
        struct.pack_into('<Q', e, 48, a)
        e[56:112] = name_raw
        tab[i*128:(i+1)*128] = e
    return tab

tab = build_table()
hdr1 = build_header(1, S4K - 1, 2)
hdr2 = build_header(S4K - 1, 1, S4K - 34)
hdr1[88:92] = struct.pack('<I', crc(tab))
hdr2[88:92] = struct.pack('<I', crc(tab))
hdr1[16:20] = struct.pack('<I', crc(hdr1[:92]))
hdr2[16:20] = struct.pack('<I', crc(hdr2[:92]))

with open(disk, 'r+b') as f:
    f.seek(512)                                  # clear stale 512 GPT
    f.write(b'\x00' * (17408 - 512))
    mbr = bytearray(SECTOR)                      # protective MBR
    mbr[0x1BE + 4] = 0xEE
    struct.pack_into('<I', mbr, 0x1BE + 8, 1)
    struct.pack_into('<I', mbr, 0x1BE + 12, S4K - 1)
    mbr[0x1FE:0x200] = b'\x55\xaa'
    f.seek(0); f.write(mbr)
    f.seek(SECTOR); f.write(hdr1)                # header @4096
    f.seek(2 * SECTOR); f.write(tab)             # table @8192
    f.seek((S4K - 34) * SECTOR); f.write(tab)    # backup table
    f.seek((S4K - 1) * SECTOR); f.write(hdr2)    # backup header

with open(disk, 'rb') as f:                      # verify
    f.seek(4096)
    h = f.read(512)
    assert h[0:8] == b'EFI PART', 'verify: header signature missing'
    hcrc = bytearray(h[:92]); hcrc[16:20] = b'\x00\x00\x00\x00'
    assert struct.unpack('<I', h[16:20])[0] == crc(hcrc), 'verify: header CRC mismatch'
print('    4K GPT written and verified (pre-conversion GPT backed up)')
PYEOF
}

# ---------------------------------------------------------------- F ----------
phase_f() {
    log "[F] stateless checks"
    local dirs=("$@")
    if grep -rnE 'hostnqn|dhchap|secret|kurrent:host|tls_psk' \
        /etc/hostname /etc/hosts /etc/fstab /etc/default/grub "${dirs[@]}" 2>/dev/null; then
        echo "WARN: possible identity hard-coding in the paths above, review manually"
    else
        echo "    identity: no hostnqn/dhchap/secret/tls_psk hard-coded in system config"
    fi
    # 连接信息（target 地址/端口/NQN）只允许出现在内存中的 NBCT：
    if grep -rlnE 'nvme://|traddr|trsvcid|tls_psk|nbft-secret' /etc 2>/dev/null \
        | grep -vE '^/etc/(ssl|pki|crypto-policies)/' | head -5 | grep -q .; then
        echo "WARN: possible connection hard-coding under /etc (see above)"
    else
        echo "    connection: no nvme:// / traddr / trsvcid / tls_psk under /etc"
    fi
    for f in /etc/nvme/hostnqn /etc/nvme/hostid /etc/nvme/discovery.conf; do
        [ -e "$f" ] && echo "WARN: $f exists (the host NQN must come from NBCT every boot, not from disk)"
    done
    echo "    hostname placeholder: $(cat /etc/hostname)"
    cat <<EOF

==> Customization complete. Acceptance checklist (one cold SAN boot after distribution):
  1. firmware: sanboot handshake (DH-HMAC-CHAP or TLS 1.3 PSK), then the SAN device registers
  2. kernel: nbft-connect connects each NBCT entry (--dhchap-secret / --tls);
     the target dmesg shows "Created nvm controller ... , TLS." (once per stage)
  3. nvme0n1 partitions -> rootfs mounted -> login:
  4. no keep-alive errors, no emergency mode
  Note: this disk now uses 4K sectors; 512-byte environments (VMware/QEMU default
        disks) can no longer read it. Only SAN (nvmet 4K blocks) or 4Kn can boot it.
EOF
}

# ------------------------------------------------------- dracut 95nbft -------
# Shared runtime hook. Distribution differences are parameters, not forks:
#   $2 = unit that owns initrd DHCP (NetworkManager.service / systemd-networkd.service)
#   $3 = shell used to run nbft-connect (bash on RHEL/SUSE, dash on Fedora)
golden_write_nbft_hook() {
    local mod=$1 nm_unit=$2 nbft_sh=$3
    cat > "$mod/nbft.sh" <<EOF
#!/bin/bash
# 95nbft runtime hook (pre-mount): NBFT/NBCT -> NVMe-oF sessions.
# Networking is owned by ${nm_unit}; this hook only waits for IPv4, starts
# tlshd, applies NBFT static entries and connects the NBCT credentials.
# nbft-connect runs under ${nbft_sh}: RHEL/SUSE base repositories ship no dash
# and the component strips NBFT NUL padding explicitly; Fedora requires dash.
# Log messages go to /dev/kmsg so they reach the serial console.
log() { echo "95nbft: \$*" > /dev/kmsg 2>/dev/null || echo "95nbft: \$*"; }

BOOT_IFACE=

wait_ipv4() {
    local t=0 d dev
    while [ "\$t" -lt 120 ]; do
        for d in /sys/class/net/*; do
            dev=\${d##*/}
            [ "\$dev" = "lo" ] && continue
            if ip -4 addr show dev "\$dev" 2>/dev/null | grep -q 'inet '; then
                BOOT_IFACE=\$dev
                return 0
            fi
        done
        # One late start of the DHCP owner (covers an abnormal dracut net stage).
        if [ "\$t" -eq 20 ]; then
            systemctl start ${nm_unit} >/dev/null 2>&1 || true
        fi
        sleep 1
        t=\$((t + 1))
    done
    return 1
}

start_tlshd() {
    local conf=/etc/tlshd.conf
    [ -f "\$conf" ] || conf=/etc/tlshd/config
    [ -x /usr/sbin/tlshd ] || { log "WARNING: tlshd missing, TLS will fail"; return 0; }
    if [ -s /run/tlshd.pid ] && kill -0 "\$(cat /run/tlshd.pid)" 2>/dev/null; then
        return 0
    fi
    /usr/sbin/tlshd -s -c "\$conf" >/dev/kmsg 2>&1 &
    echo \$! > /run/tlshd.pid
    sleep 1
    kill -0 "\$(cat /run/tlshd.pid)" 2>/dev/null || \\
        log "WARNING: tlshd exited (missing /etc/tlshd/config?), TLS will fail"
}

main() {
    local nbft_auto= x out rc TBL iface mac proto vlan ipaddr prefix netmask gateway i
    [ -e /run/nbft-done ] && return 0
    for x in \$(cat /proc/cmdline); do
        [ "\$x" = "nbft_auto" ] && nbft_auto=1
    done
    [ -n "\$nbft_auto" ] || { log "nbft_auto not on cmdline, skipping"; : > /run/nbft-done; return 0; }
    [ -x /usr/libexec/nbft-connect ] || { log "ERROR: nbft-connect missing"; return 0; }

    TBL=/sys/firmware/acpi/tables
    if [ ! -e "\$TBL/NBFT" ] && ! ls "\$TBL"/NBCT* >/dev/null 2>&1; then
        log "no NBFT/NBCT table, skipping"
        : > /run/nbft-done
        return 0
    fi
    log "NBFT/NBCT present, waiting for network"
    udevadm settle
    systemctl start ${nm_unit} >/dev/null 2>&1 || true
    wait_ipv4 || log "WARNING: no IPv4 after 120s, connecting anyway"

    modprobe -q nvme_tcp 2>/dev/null || modprobe -q nvme-tcp 2>/dev/null || \\
        log "WARNING: nvme_tcp module not found"
    modprobe -q tls 2>/dev/null || true
    modprobe -q nvme-keyring 2>/dev/null || modprobe -q nvme_keyring 2>/dev/null || true
    start_tlshd

    eval "\$(${nbft_sh} /usr/libexec/nbft-connect)" || log "WARNING: NBFT parse failed"

    i=0
    while [ "\$i" -lt "\${NBFT_ENTRY_COUNT:-0}" ]; do
        eval "iface=\\\$NBFT_IFACE_\${i}"
        eval "mac=\\\$NBFT_MAC_\${i}"
        eval "proto=\\\$NBFT_PROTO_\${i}"
        eval "vlan=\\\$NBFT_VLAN_\${i}"
        eval "ipaddr=\\\$NBFT_IP_\${i}"
        eval "prefix=\\\$NBFT_PREFIX_\${i}"
        eval "netmask=\\\$NBFT_NETMASK_\${i}"
        eval "gateway=\\\$NBFT_GATEWAY_\${i}"
        if [ -n "\$vlan" ]; then
            log "WARNING: VLAN \${iface}.\${vlan} unsupported, skipping"
        elif [ -z "\$iface" ]; then
            log "WARNING: no interface for MAC \${mac}, skipping"
        elif [ "\$proto" = "static" ] && [ -n "\$ipaddr" ]; then
            ip link set dev "\$iface" up
            ip addr replace "\$ipaddr/\$prefix" dev "\$iface" 2>/dev/null || \\
                ip addr add "\$ipaddr" netmask "\$netmask" dev "\$iface" 2>/dev/null || \\
                log "WARNING: cannot configure \$ipaddr on \$iface"
            [ -n "\$gateway" ] && [ "\$gateway" != "0.0.0.0" ] && \\
                ip route replace default via "\$gateway" 2>/dev/null || true
        fi
        i=\$((i + 1))
    done

    out=\$(${nbft_sh} /usr/libexec/nbft-connect --connect --verbose 2>&1)
    rc=\$?
    [ -n "\$out" ] && printf '%s\n' "\$out" | while IFS= read -r l; do
        [ -n "\$l" ] && log "\$l"
    done
    log "nbft-connect --connect rc=\$rc"

    # Root on LVM needs an explicit activation (dracut's settled stage may not run).
    if command -v lvm >/dev/null 2>&1; then
        out=\$(lvm vgchange -ay 2>&1) || true
        [ -n "\$out" ] && printf '%s\n' "\$out" | while IFS= read -r l; do
            [ -n "\$l" ] && log "\$l"
        done
    fi

    udevadm settle
    [ -n "\$BOOT_IFACE" ] && echo "\$BOOT_IFACE" > /run/initramfs/nvmeof.interface
    : > /run/nbft-done
    return 0
}

main
EOF
    chmod 0755 "$mod/nbft.sh"
}

# dracut module for the NetworkManager variants (AlmaLinux, openSUSE Leap).
golden_write_dracut_module_nm() {
    local mod=$1
    mkdir -p "$mod"
    cat > "$mod/module-setup.sh" <<EOF
#!/bin/bash
# 95nbft - NBFT/NBCT consumer (golden image injection, not shipped by the distro).
# Unlike the native 95nvmf it reads DH-HMAC-CHAP credentials and TLS-PSK from
# NBCT and connects them one by one (--dhchap-secret / --tls).
check() { [ -x /usr/libexec/nbft-connect ] || return 1; return 0; }
depends() { echo "rootfs-block network network-manager"; }
install() {
    # dd extracts the fixed-width NBCT fields; keyctl/tlshd are required for
    # kernel-side TLS; ${NBFT_SHELL} runs nbft-connect (see hook header).
    inst_multiple -o nvme jq ip udevadm modprobe grep awk sed cut tr dd head wc od stat keyctl tlshd ${NBFT_SHELL}
    inst_simple /usr/libexec/nbft-connect
    inst_multiple -o /etc/tlshd.conf /etc/tlshd/config
    # GnuTLS @SYSTEM priority comes from crypto-policies; without it tlshd exits
    # with gnutls -50 (EINVAL) and kernel TLS fails.
    if [ -e /etc/crypto-policies/back-ends/gnutls.config ]; then
        inst_simple "\$(readlink -f /etc/crypto-policies/back-ends/gnutls.config)" \\
            /etc/crypto-policies/back-ends/gnutls.config
    fi
    instmods nvme_fabrics nvme_tcp nvme_auth tls nvme-keyring
    # kTLS installs the negotiated TLS 1.3 cipher via the crypto API after the
    # handshake; without these modules the session completes in tlshd but
    # nvme reports EIO ("TLS handshake complete, error -5").
    instmods gcm ccm chacha20poly1305 ghash_generic aesni_intel ghash_clmulni_intel
    # Two hook phases: initqueue/settled runs when root-wait stays, pre-mount
    # runs when there is no queue; /run/nbft-done makes them idempotent.
    inst_hook initqueue/settled 30 "\$moddir/nbft.sh"
    inst_hook pre-mount 30 "\$moddir/nbft.sh"
}
EOF
    golden_write_nbft_hook "$mod" NetworkManager.service "$NBFT_SHELL"
    chmod 0755 "$mod/module-setup.sh"
}

# Wired NIC candidates shared with the Arch mkinitcpio hook
# (golden/archlinux/mkinitcpio-nbft/install/nbft). Wireless, USB, WWAN and CAN
# adapters are not boot paths; GPU drivers stay out with early KMS disabled.
GOLDEN_WIRED_NICS="virtio_net vmxnet3 hv_netvsc \
    e1000 e1000e igb igc ixgbe ixgbevf i40e iavf ice \
    r8169 tg3 bnx2 bnx2x bnxt_en \
    mlx4_core mlx5_core \
    qede qlcnic netxen_nic cxgb4 sfc nfp liquidio atlantic sky2 skge \
    alx atl1c atl1e be2net \
    ena gve mana hns3 amd_xgbe \
    8139too via_rhine sis900"

# Print the wired NIC modules present on the running kernel. Missing names are
# skipped: a golden image must build on distributions without every driver.
golden_available_wired_nics() {
    local _m
    for _m in $GOLDEN_WIRED_NICS; do
        modinfo -n "$_m" >/dev/null 2>&1 && printf '%s\n' "$_m"
    done
    return 0
}

# Check a generated initramfs against its lsinitrd/lsinitramfs listing.
# golden_verify_initramfs <image> <listing-file> <kver> <label>
golden_verify_initramfs() {
    local img=$1 listing=$2 kver=$3 label=$4 pat n size
    [ -f "$img" ] || { echo "ERROR: $label: $img is missing"; exit 1; }
    [ -f "$listing" ] || { echo "ERROR: $label: initramfs listing $listing is missing"; exit 1; }
    for pat in nbft-connect tlshd keyctl nvme 'nvme[-_]tcp' tls virtio_net gcm ccm \
        chacha20poly1305 'aesni[-_]intel' 'ghash[-_]clmulni[-_]intel'; do
        n=$(grep -Ec "$pat" "$listing" || true)
        if [ "$n" -eq 0 ] && grep -qE "$pat" "/lib/modules/$kver/modules.builtin" 2>/dev/null; then
            echo "    $label: $pat built into the kernel"
            continue
        fi
        [ "$n" -gt 0 ] || { echo "ERROR: $label: $pat not found in $img"; exit 1; }
    done
    for pat in nvidia amdgpu iwlwifi ath10k ath11k rtw89 brcmfmac \
        '/drivers/net/wireless/' '/drivers/net/usb/' '/drivers/net/wan/'; do
        n=$(grep -Ec "$pat" "$listing" || true)
        [ "$n" -eq 0 ] || { echo "ERROR: $label: $img contains $pat ($n entries)"; exit 1; }
    done
    size=$(stat -c %s "$img")
    echo "    $label: initramfs size $((size / 1024 / 1024)) MiB ($size bytes)"
    [ "$size" -le $((120 * 1024 * 1024)) ] || {
        echo "ERROR: $label: $img is $size bytes, above the 120 MiB limit"; exit 1
    }
}

# Full B stage for the NetworkManager variants (shared package-independent part).
phase_b_dracut_nm() {
    log "[B] initramfs seed module (dracut 95nbft: NBCT credentials + kernel TLS)"
    golden_check_nbft_component
    install -m 0755 "$COMPONENT_DIR/nbft-connect" /usr/libexec/nbft-connect
    golden_install_tlshd_config
    golden_write_dracut_module_nm /usr/lib/dracut/modules.d/95nbft
    # --no-hostonly：母盘跨硬件（网卡/存储驱动全量）。
    # --omit nvmf：发行版原生 95nvmf 只做无凭据的 connect-all --nbft，
    # 与本模块的 NBCT 带凭据连接互斥，必须排除以免先发明文/无认证握手。
    dracut --force --no-hostonly --add "nbft network network-manager" \
        --omit "nvmf" --kver "$KVER"
    # 注意：grep -q 提前退出会让上游 lsinitrd 吃到 SIGPIPE（pipefail 下误判失败），
    # 因此用 grep -c 消费完整输出后再判断
    local img=$INITRD_SRC nbft_count nm_count tls_count
    nbft_count=$(lsinitrd "$img" 2>/dev/null | grep -c 'nbft' || true)
    nm_count=$(lsinitrd "$img" 2>/dev/null | grep -c 'NetworkManager' || true)
    tls_count=$(lsinitrd "$img" 2>/dev/null | grep -c 'tlshd' || true)
    [ "$nbft_count" -gt 0 ] || { echo "ERROR: $img has no nbft component"; exit 1; }
    [ "$nm_count" -gt 0 ] || { echo "ERROR: $img has no NetworkManager (initrd DHCP owner)"; exit 1; }
    [ "$tls_count" -gt 0 ] || { echo "ERROR: $img has no tlshd (required for kernel TLS)"; exit 1; }
    echo "    $img contains nbft ($nbft_count), NetworkManager ($nm_count), tlshd ($tls_count)"
}
