#!/bin/bash
# golden-image-setup-debian12.sh - 一键母盘定制（Debian 12 bookworm → NVMe-oF SAN 引导母盘）
#
# 对应 docs/golden-image-customization.md 的 A-F 六阶段：
#   A. 系统与内核   bookworm-backports 6.12（CONFIG_NVME_AUTH=m）
#   B. initramfs 种子模块（initramfs-nbft：NBFT/NBCT 消费，hostid 修复）
#   C. 系统配置     fstab（root UUID 写死 + 注释 /boot/efi）、DHCP、hostname 占位
#   D. GRUB 启动参数（net.ifnames=0 ip=dhcp nbft_auto systemd.mask 防断链）
#   E. 磁盘格式     4K 原生 GPT + 4K FAT32 ESP + GRUB（SAN 形态，交互确认）
#   F. 无状态校验   盘内零身份硬编码 + 验收清单
#
# 用法（在母盘系统内以 root 运行）：
#   sudo bash test/golden-image-setup-debian12.sh
#   sudo bash test/golden-image-setup-debian12.sh --skip-disk --yes
#
# 选项：
#   -d DIR        initramfs-nbft 组件目录（默认脚本同仓库的 ../initramfs-nbft）
#   -k VER        内核版本（默认 6.12.95+deb12-amd64，bookworm-backports）
#   --skip-disk   跳过 E 磁盘格式（不重写 GPT / 不重建 ESP）
#   --no-serial   grub.cfg 不加 console=ttyS0,115200（无串口场景）
#   --yes         跳过 E 阶段交互确认
#   -h, --help    显示帮助
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

usage() {
    sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
    -d) COMPONENT_DIR=$2; shift 2 ;;
    -k) KVER=$2; shift 2 ;;
    --skip-disk) DO_DISK=0; shift ;;
    --no-serial) CONSOLE=; shift ;;
    --yes) YES=1; shift ;;
    -h | --help) usage ;;
    *) echo "ERROR: unknown option: $1" >&2; usage ;;
    esac
done

# 默认组件目录：脚本在 <repo>/test|diag 等子目录时取仓库根 initramfs-nbft
if [ -z "${COMPONENT_DIR:-}" ]; then
    COMPONENT_DIR=$(cd "$SCRIPT_DIR/../initramfs-nbft" && pwd) \
        || { echo "ERROR: 找不到默认组件目录 $SCRIPT_DIR/../initramfs-nbft，请用 -d 指定" >&2; exit 1; }
fi

[ "$(id -u)" = 0 ] || { echo "ERROR: 请以 root 运行（母盘内）"; exit 1; }

log() { echo "==> $*"; }

# ---------------------------------------------------------------- A ----------
phase_a() {
    log "[A] 系统与内核（6.12 backports）"
    # 禁用安装器残留的 cdrom 源（无光驱环境 apt-get update 会硬失败）
    cdrom_files=$(grep -rsl '^deb cdrom:' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null || true)
    if [ -n "$cdrom_files" ]; then
        for f in $cdrom_files; do sed -i 's|^deb cdrom:|# deb cdrom:|' "$f"; done
        echo "    已注释 cdrom 源：$cdrom_files"
    fi
    apt-get update
    apt-get install -y nvme-cli jq initramfs-tools grub-efi-amd64-bin dosfstools
    ensure_backports_source
    apt-get update
    apt-get install -y -t bookworm-backports "linux-image-${KVER}"
    CONF="/boot/config-${KVER}"
    [ -f "$CONF" ] || { echo "ERROR: $CONF 不存在（内核安装失败？）"; exit 1; }
    grep -q '^CONFIG_NVME_AUTH=m' "$CONF" || { echo "ERROR: $CONF 中 CONFIG_NVME_AUTH 不是 =m"; exit 1; }
    echo "    CONFIG_NVME_AUTH=m OK"
}

ensure_backports_source() {
    if grep -rqs 'bookworm-backports' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
        echo "    bookworm-backports 源已存在"
        return
    fi
    if ls /etc/apt/sources.list.d/*.sources >/dev/null 2>&1; then
        cat > /etc/apt/sources.list.d/bookworm-backports.sources <<'EOF'
Types: deb
URIs: http://deb.debian.org/debian
Suites: bookworm-backports
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
    else
        echo "deb http://deb.debian.org/debian bookworm-backports main contrib non-free non-free-firmware" \
            > /etc/apt/sources.list.d/bookworm-backports.list
    fi
    echo "    已添加 bookworm-backports 源"
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
    update-initramfs -u -k "$KVER"
    # 注意：grep -q 提前退出会让上游 lsinitramfs 吃到 SIGPIPE（pipefail 下误判失败），
    # 因此用 grep -c 消费完整输出后再判断
    nbft_count=$(lsinitramfs "/boot/initrd.img-$KVER" 2>/dev/null | grep -c 'nbft' || true)
    [ "$nbft_count" -gt 0 ] || { echo "ERROR: initrd 中未找到 nbft 组件"; exit 1; }
    echo "    initrd.img-$KVER 已含 nbft 组件（$nbft_count 项）"
}

# ---------------------------------------------------------------- C ----------
phase_c() {
    log "[C] 系统配置（fstab / 网络 / hostname）"
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

    mkdir -p /etc/systemd/network
    if [ -f /etc/systemd/network/10-dhcp.network ]; then
        echo "    10-dhcp.network 已存在"
    else
        cat > /etc/systemd/network/10-dhcp.network <<'EOF'
[Match]
Name=e*

[Network]
DHCP=yes
EOF
        echo "    已写入 10-dhcp.network（全链路 DHCP）"
    fi

    echo "    hostname 占位: $(cat /etc/hostname)（生产 hostname 由控制面下发，不属母盘职责）"
}

# ---------------------------------------------------------------- D ----------
phase_d() {
    log "[D] GRUB 启动参数"
    local grub=/etc/default/grub
    [ -f "$grub" ] || { echo "ERROR: $grub 不存在"; exit 1; }
    python3 - <<'PYEOF'
import shutil, time
path = '/etc/default/grub'
extra = 'net.ifnames=0 biosdevname=0 ip=dhcp nbft_auto systemd.mask=NetworkManager.service systemd.mask=systemd-networkd.service'
drop = {'quiet'}  # quiet 把 console 日志压到 WARNING，抑制 info 级内核打印（含 nvme 认证）
lines, out, changed, found = open(path).readlines(), [], False, False
for ln in lines:
    if not ln.startswith('GRUB_CMDLINE_LINUX_DEFAULT='):
        out.append(ln)
        continue
    found = True
    val = ln[len('GRUB_CMDLINE_LINUX_DEFAULT='):].strip()
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
        out.append(f'GRUB_CMDLINE_LINUX_DEFAULT="{new}"\n')
        changed = True
if not found:
    out.append(f'GRUB_CMDLINE_LINUX_DEFAULT="{extra}"\n')
    changed = True
if changed:
    shutil.copy(path, f"{path}.golden-{time.strftime('%Y%m%d%H%M%S')}.bak")
    open(path, 'w').writelines(out)
    print('    GRUB_CMDLINE_LINUX_DEFAULT 已更新（追加 SAN 参数、移除 quiet，备份 .golden-*.bak）')
else:
    print('    cmdline 已符合要求（含 SAN 参数且无 quiet）')
PYEOF
    update-grub
    echo "    update-grub 完成"
}

# ---------------------------------------------------------------- E ----------
# 定位 root 所在整盘（沿 PKNAME 逐级上溯）
root_disk() {
    local dev=$1 p
    p=$(lsblk -no PKNAME "$dev" 2>/dev/null | head -1)
    while [ -n "$p" ]; do
        dev=/dev/$p
        p=$(lsblk -no PKNAME "$dev" 2>/dev/null | head -1)
    done
    echo "$dev"
}

# 定位 ESP：优先 /boot/efi 挂载源，否则按分区类型找 EFI System
find_esp() {
    local mnt
    mnt=$(findmnt -no SOURCE /boot/efi 2>/dev/null || true)
    [ -n "$mnt" ] && [ -b "$mnt" ] && { echo "$mnt"; return; }
    lsblk -no PATH,PARTTYPENAME | awk '$2 ~ /^EFI/ {print $1; exit}'
}

gpt_sector() { # 输出 512 / 4096 / none
    local disk=$1 sig
    sig=$(dd if="$disk" bs=1 skip=4096 count=8 2>/dev/null)
    if [ "$sig" = "EFI PART" ]; then
        echo 4096
    elif [ "$(dd if="$disk" bs=1 skip=512 count=8 2>/dev/null)" = "EFI PART" ]; then
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
    if [ "$YES" != 1 ]; then
        read -r -p "    将重写 GPT 为 4K 语义并重建 ESP，继续？[y/N] " ans || ans=
        case "$ans" in y | Y) ;; *) echo "    已跳过 E"; return ;; esac
    fi
    if [ "$(ss -tn 2>/dev/null | awk 'NR>1 {print $4}' | grep -c ':4420$' || true)" -gt 0 ]; then
        echo "ERROR: 检测到活跃 NVMe/TCP 连接（:4420），请先断开"; exit 1
    fi

    local rootdev disk esp espsize
    # 兼容链：个别环境 lsblk 不支持 SOURCE 列（或 chroot 内无设备上下文）时降级 findmnt，
    # 均失败则跳过 root UUID 校验（保持安全）
    rootdev=$(lsblk -no SOURCE / 2>/dev/null || findmnt -no SOURCE / 2>/dev/null || true)
    disk=$(root_disk "$rootdev")
    esp=$(find_esp)
    [ -b "$disk" ] || { echo "ERROR: 无法定位 root 所在盘（$disk）"; exit 1; }
    [ -b "$esp" ] || { echo "ERROR: 无法定位 ESP 分区"; exit 1; }
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
        mkfs.fat -F 32 -S 4096 "$esp" >/dev/null
        # mkfs.fat 4.2 的 -i 不生效（volid 恒 0），改为直接写 BPB 偏移 39（小端）
        python3 - "$esp" <<'PYEOF'
import struct, sys
with open(sys.argv[1], 'r+b') as f:
    f.seek(39)
    f.write(struct.pack('<I', 0x855B91DF))
print('    volid 已写入 BPB（855B-91DF）')
PYEOF
        echo "    ESP 已重建为 4K FAT32（volid $ESP_VOLID）"
    fi

    [ -f "/boot/vmlinuz-$KVER" ] || { echo "ERROR: /boot/vmlinuz-$KVER 不存在"; exit 1; }
    [ -f "/boot/initrd.img-$KVER" ] || { echo "ERROR: /boot/initrd.img-$KVER 不存在"; exit 1; }

    if ! findmnt /boot/efi >/dev/null 2>&1; then
        mkdir -p /boot/efi
        mount "$esp" /boot/efi
        echo "    挂载 ESP → /boot/efi"
    fi
    find /boot/efi -mindepth 1 -maxdepth 1 -exec rm -rf {} +

    cp -a "/boot/vmlinuz-$KVER" /boot/efi/
    cp -a "/boot/initrd.img-$KVER" /boot/efi/
    mkdir -p /boot/efi/EFI/BOOT

    local grub_mods="normal search search_fs_uuid part_gpt part_msdos ext2 fat linux xzio gzio serial terminal echo ls configfile test"
    if ! grub-mkimage -O x86_64-efi -o /boot/efi/EFI/BOOT/BOOTX64.EFI -p /EFI/BOOT $grub_mods; then
        echo "WARN: grub-mkimage 含 echo 失败，降级重试（GRUB 2.06 兼容）"
        grub_mods=${grub_mods/ echo/}
        grub-mkimage -O x86_64-efi -o /boot/efi/EFI/BOOT/BOOTX64.EFI -p /EFI/BOOT $grub_mods
    fi
    echo "    BOOTX64.EFI 生成（grub-mkimage）"

    local rootuuid
    rootuuid=$(blkid -s UUID -o value "$rootdev")
    cat > /boot/efi/EFI/BOOT/grub.cfg <<EOF
set default=0
set timeout=5
menuentry 'Debian GNU/Linux 12 (SAN, ${KVER})' {
    search --no-floppy --fs-uuid --set=root ${ESP_UUID}
    linux /vmlinuz-${KVER} root=UUID=${rootuuid} ro ${CONSOLE} ${GRUB_ARGS}
    initrd /initrd.img-${KVER}
}
EOF
    echo "    grub.cfg 已生成（ESP UUID=$ESP_UUID, root UUID=$rootuuid）"

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
    if grep -rnE 'hostnqn|dhchap|secret|kurrent:host' \
        /etc/hostname /etc/hosts /etc/fstab /etc/default/grub /etc/systemd/network 2>/dev/null; then
        echo "WARN: 上述位置疑似身份硬编码，请人工确认"
    else
        echo "    身份检查：系统配置中无 hostnqn/dhchap/secret 硬编码"
    fi
    echo "    hostname 占位: $(cat /etc/hostname)"
    cat <<EOF

==> 定制完成。验收清单（克隆分发后 SAN 冷启动一轮）：
  1. 串口出现 authenticated ... dhgroup ffdhe4096（固件段 + 内核段各一次）
  2. nvme0n1: p1 p2 p3 → rootfs 挂载 → login:
  3. 无 keep-alive 错误、无 emergency mode
  注意：本盘已转为 4K 语义，512 环境（VMware/QEMU 默认虚拟盘）不再可读；
       仅 SAN（nvmet 4K 块）或 4Kn 环境可引导。
EOF
}

main() {
    phase_a
    phase_b
    phase_c
    phase_d
    [ "$DO_DISK" = 1 ] && phase_e
    phase_f
}

main
