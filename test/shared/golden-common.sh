# shellcheck shell=bash
# golden-common.sh - shared stages for the RHEL/SUSE golden image setup scripts.
#
# Sourced by test/{almalinux10,fedora44,opensuse-leap16}/golden-image-setup-*.sh.
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
#   NBFT_SHELL (default bash), GRUB_CFG (default /boot/grub2/grub.cfg)

ESP_VOLID=${ESP_VOLID:-855B91DF}
ESP_UUID=${ESP_UUID:-855B-91DF}
CONSOLE=${CONSOLE:-console=ttyS0,115200}
DO_DISK=${DO_DISK:-1}
YES=${YES:-0}
KEEP_SOURCES=${KEEP_SOURCES:-0}
GRUB_EFI=${GRUB_EFI:-}
NBFT_SHELL=${NBFT_SHELL:-bash}
GRUB_CFG=${GRUB_CFG:-/boot/grub2/grub.cfg}

log() { echo "==> $*"; }

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
    [ -n "$EMBED_B64_CONNECT" ] || { echo "ERROR: 脚本未内嵌组件(运行 bash test/shared/embed-components.py 生成)" >&2; return 1; }
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
        echo "    仓库组件目录不可用，释放脚本内嵌组件..."
        COMPONENT_DIR=$(release_embedded_components) || exit 1
    fi
}

golden_check_nbft_component() {
    [ -f "$COMPONENT_DIR/nbft-connect" ] || {
        echo "ERROR: 缺少组件 $COMPONENT_DIR/nbft-connect（-d 指定目录）"; exit 1
    }
    grep -q -- '--hostid' "$COMPONENT_DIR/nbft-connect" || {
        echo "ERROR: nbft-connect 缺少 hostid 修复（文档 3.1），请先更新组件"; exit 1
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
    [ "$(id -u)" = 0 ] || { echo "ERROR: 请以 root 运行（母盘内）"; exit 1; }
    case "$KVER" in
    '') echo "ERROR: 内核版本为空（-k 或 uname -r）" >&2; exit 1 ;;
    esac
    INITRD_SRC=${INITRD_SRC_TEMPLATE//@KVER@/$KVER}
    INITRD_ESP_NAME=${INITRD_ESP_NAME_TEMPLATE//@KVER@/$KVER}
}

# ---------------------------------------------------------------- C ----------
phase_c() {
    log "[C] 系统配置（fstab / hostname）"
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
    print('    fstab: 已注释 /boot/efi 行（备份 .golden-*.bak）')
else:
    print('    fstab: /boot/efi 已注释或不存在，无需改动')
PYEOF

    rootdev=$(lsblk -no SOURCE / 2>/dev/null || findmnt -no SOURCE / 2>/dev/null || true)
    case "$rootdev" in
    UUID=*)
        echo "    root 已用 UUID 挂载（$rootdev）"
        ;;
    /dev/*)
        rootuuid=$(blkid -s UUID -o value "$rootdev")
        [ -n "$rootuuid" ] || { echo "ERROR: 无法获取 $rootdev 的 UUID"; exit 1; }
        if grep -qE "^[^#].*[[:space:]]/[[:space:]]" /etc/fstab && [ -z "$(awk '$2=="/" && $1 !~ /^UUID=/' /etc/fstab)" ]; then
            echo "    fstab 的 / 行已是 UUID=$rootuuid"
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
    print(f'    fstab: / 行已写死 UUID={uuid}（备份 .golden-*.bak）')
else:
    print(f'    fstab: / 行已符合要求（UUID={uuid}）')
PYEOF
        fi
        ;;
    *) echo "WARN: 无法识别 root 设备（$rootdev），跳过 root UUID 校验" ;;
    esac

    # 发行版可选的额外网络配置（Fedora 的 systemd-networkd 单元）
    if declare -F phase_c_network >/dev/null; then
        phase_c_network
    fi

    # hostname 去标识：真实 hostname 由控制面在引导链中下发，母盘不留克隆身份。
    printf 'localhost\n' > /etc/hostname
    echo "    hostname 占位: localhost（生产 hostname 由控制面下发）"
}

# ---------------------------------------------------------------- D ----------
phase_d() {
    log "[D] GRUB 启动参数"
    local grub=/etc/default/grub
    [ -f "$grub" ] || { echo "ERROR: $grub 不存在"; exit 1; }
    python3 - "$GRUB_ARGS" <<'PYEOF'
import shutil, sys, time
path = '/etc/default/grub'
extra = sys.argv[1]
drop = {'quiet', 'rhgb'}  # quiet/rhgb 压掉 info 级内核打印（含 nvme 认证），串口场景无益
lines, out, changed, found = open(path).readlines(), [], False, False
for ln in lines:
    key = next((k for k in ('GRUB_CMDLINE_LINUX=', 'GRUB_CMDLINE_LINUX_DEFAULT=')
                if ln.startswith(k)), None)
    if key is None:
        out.append(ln)
        continue
    found = True
    val = ln[len(key):].strip()
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
        out.append(f'{key}"{new}"\n')
        changed = True
if not found:
    out.append(f'GRUB_CMDLINE_LINUX_DEFAULT="{extra}"\n')
    changed = True
if changed:
    shutil.copy(path, f"{path}.golden-{time.strftime('%Y%m%d%H%M%S')}.bak")
    open(path, 'w').writelines(out)
    print('    GRUB cmdline 已更新（追加 SAN 参数、移除 quiet/rhgb，备份 .golden-*.bak）')
else:
    print('    cmdline 已符合要求（含 SAN 参数且无 quiet/rhgb）')
PYEOF
    # 盘内 grub.cfg 再生成（SAN 实引导走 ESP/grub.cfg，此处保盘内一致性）
    grub2-mkconfig -o "$GRUB_CFG" >/dev/null || \
        echo "WARN: grub2-mkconfig 失败（非致命：SAN 引导走 ESP/grub.cfg）"
    echo "    grub2-mkconfig 完成"
}

# ---------------------------------------------------------------- E ----------
# 定位整盘（沿 PKNAME 逐级上溯）；无法回溯时输出空。
# 实现注记（util-linux 实测）：默认输出带树形符号（├─vda1）且行序不保证，
# 带 -d 时连分区行的 PKNAME 也被清空；故用 -r（raw）按“设备名取自身行”查询。
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

gpt_sector() { # 输出 512 / 4096 / none（od 转十六进制比对，避免 NUL 字节进命令替换）
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
    python3 - "$1" <<'PYEOF'
import sys
with open(sys.argv[1], 'rb') as f:
    b = f.read(512)
ok = len(b) == 512 and b[11] | (b[12] << 8) == 4096 and b[39:43] == b'\xdf\x91\x5b\x85'
sys.exit(0 if ok else 1)
PYEOF
}

phase_e() {
    log "[E] 磁盘格式（4K 原生 GPT + 4K FAT32 ESP）"
    local rootdev disk esp espsize
    # 兼容链：个别环境 lsblk 不支持 SOURCE 列（或 chroot 内无设备上下文）时降级 findmnt，
    # 均失败则跳过 root UUID 校验（保持安全）
    rootdev=$(lsblk -no SOURCE / 2>/dev/null || findmnt -no SOURCE / 2>/dev/null || true)
    esp=$(find_esp)
    [ -b "$esp" ] || { echo "ERROR: 无法定位 ESP 分区"; exit 1; }

    [ "$DO_DISK" = 1 ] && [ "$YES" != 1 ] && {
        read -r -p "    将重写 GPT 为 4K 语义并重建 ESP，继续？[y/N] " ans || ans=
        case "$ans" in y | Y) ;; *) DO_DISK=0 ;; esac
    }
    if [ "$DO_DISK" = 1 ]; then
        if [ "$(ss -tn 2>/dev/null | awk 'NR>1 {print $4}' | grep -c ':4420$' || true)" -gt 0 ]; then
            echo "ERROR: 检测到活跃 NVMe/TCP 连接（:4420），请先断开"; exit 1
        fi
        # 盘 = root 所在整盘；LVM/dm root 无法沿 PKNAME 回溯（安装器默认布局），
        # 退化为 ESP 分区所在盘（母盘同盘布局，E 的目标就是引导盘）。
        disk=$(root_disk "$rootdev")
        [ -n "$disk" ] || disk=$(root_disk "$esp")
        [ -b "$disk" ] || { echo "ERROR: 无法定位引导盘（root=$rootdev esp=$esp）"; exit 1; }
        espsize=$(lsblk -bno SIZE "$esp")
        echo "    root: $rootdev  盘: $disk  ESP: $esp ($((espsize / 1024 / 1024)) MiB)"

        # 4K FAT32 需要 >= 65525 簇（4K 簇 → 约 256 MiB），不足则拒绝（不自动扩分区）
        if [ "$espsize" -lt $((256 * 1024 * 1024)) ]; then
            echo "ERROR: ESP 仅 $((espsize / 1024 / 1024)) MiB，4K FAT32 需 >= 256 MiB（文档 6.2），请先扩分区"; exit 1
        fi

        local sec
        sec=$(gpt_sector "$disk")
        case "$sec" in
        4096) echo "    GPT 已是 4K 语义，跳过转换" ;;
        512)  convert_gpt_4k "$disk" ;;
        none) echo "ERROR: $disk 上未找到 GPT（512 或 4K 均无）"; exit 1 ;;
        esac

        # ESP 重建（4K FAT32，固定 volid；fstab 已注释故系统内不再挂载）
        umount /boot/efi 2>/dev/null || true
        if esp_is_4k_volid "$esp"; then
            echo "    ESP 已是 4K FAT32（volid $ESP_VOLID），跳过 mkfs"
        else
            mkfs.fat -S 4096 "$esp" >/dev/null   # 106 MiB cloud img ESP 自动 FAT16（EDK2 支持）
            # FAT32 的 volid 固定在 BPB 偏移 0x43（与 sector size 无关）;
            # mkfs.fat 4.2 的 -i 不生效,因此格式化后直接补写。注意: 偏移 39(0x27)
            # 是历史错误位置,会破坏 FAT32 sectors 字段导致 EDK2 拒挂(0x7f22208e)。
            python3 - "$esp" "$ESP_VOLID" <<'PYEOF'
import struct, sys
with open(sys.argv[1], 'r+b') as f:
    f.seek(0x43)
    f.write(struct.pack('<I', int(sys.argv[2], 16)))
v = sys.argv[2]
print(f'    volid 已写入 BPB 0x43（{v[:4]}-{v[4:]}）')
PYEOF
            echo "    ESP 已重建为 4K FAT32（volid $ESP_VOLID）"
        fi
    else
        # --skip-disk 只跳过 GPT/ESP 重建，ESP 内容仍每次刷新：
        # 新 initrd 不落 ESP 是"改动不生效"的最常见来源（AGENTS §9）。
        echo "    --skip-disk：跳过 GPT 转换与 ESP 重建，仅刷新 ESP 内容"
    fi

    [ -f "/boot/vmlinuz-$KVER" ] || { echo "ERROR: /boot/vmlinuz-$KVER 不存在"; exit 1; }
    [ -f "$INITRD_SRC" ] || { echo "ERROR: $INITRD_SRC 不存在"; exit 1; }

    if ! findmnt /boot/efi >/dev/null 2>&1; then
        mkdir -p /boot/efi
        mount "$esp" /boot/efi
        echo "    挂载 ESP → /boot/efi"
    fi
    find /boot/efi -mindepth 1 -maxdepth 1 -exec rm -rf {} +

    cp -a "/boot/vmlinuz-$KVER" /boot/efi/
    cp -a "$INITRD_SRC" "/boot/efi/$INITRD_ESP_NAME"
    mkdir -p /boot/efi/EFI/BOOT

    local grub_mods="normal search search_fs_uuid part_gpt part_msdos ext2 fat linux xzio gzio serial terminal echo ls configfile test"
    if [ -z "${GRUB_EFI:-}" ] && [ -n "$EMBED_B64_BOOTX64" ]; then
        # 默认: 脚本内嵌的 GRUB 2.14 产物(实测引导基线),零宿主依赖
        GRUB_EFI=$(mktemp /tmp/BOOTX64.XXXXXX.EFI)
        echo "$EMBED_B64_BOOTX64" | base64 -d > "$GRUB_EFI"
        echo "    使用脚本内嵌 GRUB 2.14 产物"
    fi
    if [ -n "${GRUB_EFI:-}" ]; then
        [ -f "$GRUB_EFI" ] || { echo "ERROR: --grub-efi 文件不存在: $GRUB_EFI"; exit 1; }
        install -m 0644 "$GRUB_EFI" /boot/efi/EFI/BOOT/BOOTX64.EFI
        echo "    BOOTX64.EFI 使用预构建注入（$GRUB_EFI）"
    else
        # 发行版 grub-mkimage 版本门控：Debian 12 自带 2.06 的产物在 SAN 引导路径
        # 实测卡死（发行版缺陷，与 4K 逻辑块无关；2026-09-04 实测，见文档 6.3）
        local gver
        gver=$(grub2-mkimage --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1) || gver=""
        if [ -z "$gver" ] || ! awk -v v="$gver" 'BEGIN { exit !(v + 0 >= 2.12) }'; then
            echo "ERROR: 母盘 grub2-mkimage 版本 ${gver:-未知} < 2.12，其 BOOTX64.EFI 在 SAN 引导路径卡死。出路：" >&2
            echo "       a) 宿主机（grub 2.14+）生成后 --grub-efi 注入；" >&2
            echo "       b) 母盘升级 grub2 >= 2.12 后重跑本脚本。" >&2
            exit 1
        fi
        if ! grub2-mkimage -O x86_64-efi -o /boot/efi/EFI/BOOT/BOOTX64.EFI -p /EFI/BOOT $grub_mods; then
            echo "WARN: grub2-mkimage 含 echo 失败，降级重试（echo 模块缺失）"
            grub_mods=${grub_mods/ echo/}
            grub2-mkimage -O x86_64-efi -o /boot/efi/EFI/BOOT/BOOTX64.EFI -p /EFI/BOOT $grub_mods
        fi
        echo "    BOOTX64.EFI 生成（grub2-mkimage $gver）"
    fi

    local rootuuid rd_lvm="" vglv
    rootuuid=$(blkid -s UUID -o value "$rootdev")
    # LVM root（安装器默认布局）：需显式激活 VG/LV，否则 dracut 找不到 root
    if lvs --noheadings -o vg_name,lv_name "$rootdev" >/dev/null 2>&1; then
        vglv=$(lvs --noheadings -o vg_name,lv_name "$rootdev" 2>/dev/null | awk '{print $1"/"$2}')
        [ -n "$vglv" ] && rd_lvm="rd.lvm.lv=$vglv"
    fi
    cat > /boot/efi/EFI/BOOT/grub.cfg <<EOF
set default=0
set timeout=5
menuentry '${MENU_LABEL} (SAN, ${KVER})' {
    search --no-floppy --fs-uuid --set=root ${ESP_UUID}
    linux /vmlinuz-${KVER} root=UUID=${rootuuid} ro ${CONSOLE} ${GRUB_ARGS}${rd_lvm:+ $rd_lvm}
    initrd /${INITRD_ESP_NAME}
}
EOF
    echo "    grub.cfg 已生成（ESP UUID=$ESP_UUID, root UUID=$rootuuid${rd_lvm:+，$rd_lvm}）"

    umount /boot/efi
    echo "    ESP 内容就绪，已卸载"
}

# 512 扇区 GPT → 4K 原生 GPT（设备版；与 diag/convert-gpt-4k.sh 同源，仅输入为块设备）
convert_gpt_4k() {
    local disk=$1 bak=/root/golden-image-gpt-512-$(date +%Y%m%d%H%M%S).bak size
    size=$(blockdev --getsize64 "$disk")
    echo "    GPT 512 → 4K 转换（盘 $((size / 1024 / 1024)) MiB），备份到 $bak"
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
print('    4K GPT 写入并验证通过（转换前 GPT 已备份）')
PYEOF
}

# ---------------------------------------------------------------- F ----------
phase_f() {
    log "[F] 无状态校验"
    local dirs=("$@")
    if grep -rnE 'hostnqn|dhchap|secret|kurrent:host|tls_psk' \
        /etc/hostname /etc/hosts /etc/fstab /etc/default/grub "${dirs[@]}" 2>/dev/null; then
        echo "WARN: 上述位置疑似身份硬编码，请人工确认"
    else
        echo "    身份检查：系统配置中无 hostnqn/dhchap/secret/tls_psk 硬编码"
    fi
    # 连接信息（target 地址/端口/NQN）只允许出现在内存中的 NBCT：
    if grep -rlnE 'nvme://|traddr|trsvcid|tls_psk|nbft-secret' /etc 2>/dev/null \
        | grep -vE '^/etc/(ssl|pki|crypto-policies)/' | head -5 | grep -q .; then
        echo "WARN: /etc 下疑似连接信息硬编码（见上）"
    else
        echo "    连接信息检查：/etc 下无 nvme:// / traddr / trsvcid / tls_psk"
    fi
    for f in /etc/nvme/hostnqn /etc/nvme/hostid /etc/nvme/discovery.conf; do
        [ -e "$f" ] && echo "WARN: $f 存在（host NQN 应由 NBCT 每次下发，不应落盘）"
    done
    echo "    hostname 占位: $(cat /etc/hostname)"
    cat <<EOF

==> 定制完成。验收清单（克隆分发后 SAN 冷启动一轮）：
  1. 固件段：sanboot 握手（DH-HMAC-CHAP 或 TLS 1.3 PSK）后注册 SAN 设备
  2. 内核段：nbft-connect 按 NBCT 逐条 connect（--dhchap-secret / --tls），
     target 端 dmesg 出现 "Created nvm controller ... , TLS."（固件段 + 内核段各一次）
  3. nvme0n1 分区 → rootfs 挂载 → login:
  4. 无 keep-alive 错误、无 emergency mode
  注意：本盘已转为 4K 语义，512 环境（VMware/QEMU 默认虚拟盘）不再可读；
       仅 SAN（nvmet 4K 块）或 4Kn 环境可引导。
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
    # Two hook phases: initqueue/settled runs when root-wait stays, pre-mount
    # runs when there is no queue; /run/nbft-done makes them idempotent.
    inst_hook initqueue/settled 30 "\$moddir/nbft.sh"
    inst_hook pre-mount 30 "\$moddir/nbft.sh"
}
EOF
    golden_write_nbft_hook "$mod" NetworkManager.service "$NBFT_SHELL"
    chmod 0755 "$mod/module-setup.sh"
}

# Full B stage for the NetworkManager variants (shared package-independent part).
phase_b_dracut_nm() {
    log "[B] initramfs 种子模块（dracut 95nbft：NBCT 凭据 + 内核段 TLS）"
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
    [ "$nbft_count" -gt 0 ] || { echo "ERROR: $img 中未找到 nbft 组件"; exit 1; }
    [ "$nm_count" -gt 0 ] || { echo "ERROR: $img 中未找到 NetworkManager（initrd DHCP 承担者）"; exit 1; }
    [ "$tls_count" -gt 0 ] || { echo "ERROR: $img 中未找到 tlshd（内核段 TLS 必需）"; exit 1; }
    echo "    $img 已含 nbft（$nbft_count 项）、NetworkManager（$nm_count 项）、tlshd（$tls_count 项）"
}
