#!/bin/bash
# Assemble the NVMe/TCP SAN boot disk from a prepared Debian rootfs.
# No root required: GPT via python, rootfs via mkfs.ext4 -d (ownership is
# preserved from the debootstrap-created rootfs), ESP via mkfs.vfat+mtools.
#
# Prerequisite: diag/debian-rootfs/ built by
#     sudo bash diag/make-debian-rootfs.sh
#
# Usage: bash test/manual/nbft/make-debian-san-disk.sh
#
# Output: diag/nvme-boot.img (2G GPT: ESP 300MiB + ext4 rootfs)
#
# Stateless-disk rule: the disk carries only generic payload (kernel,
# initramfs with the seed module, GRUB) plus disk-inherent identifiers
# (rootfs UUID/PARTUUID).  No target address, NQN or secret is baked in:
# the NBFT table (firmware side) supplies the target at boot time.
set -e

ROOT=$(cd "$(dirname "$0")/../../.." && pwd)

# mkfs.ext4 -d must read root-only files (e.g. /etc/shadow, 640 root:shadow)
# and preserve their ownership in the image; re-exec as root via sudo.
if [ "$(id -u)" -ne 0 ]; then
        echo "==> re-exec as root (sudo)"
        exec sudo bash "$ROOT/test/manual/nbft/make-debian-san-disk.sh" "$@"
fi

D=$ROOT/diag
RFS=$D/debian-rootfs
IMG=$D/nvme-boot.img
ESP=$D/.esp.img
STAGE=$D/.esp-stage

# Disk layout (4K sectors: the nvmet file backend exposes 4096-byte blocks)
SIZE_M=2048
ESP_M=300
ESP_START_M=8

# Fixed disk-inherent identifiers (shared with make-debian-rootfs.sh)
ROOTFS_UUID=0f1e2d3c-4b5a-6789-abcd-ef0123456789
ROOTFS_PARTUUID=a1b2c3d4-1111-2222-3333-444455556666

echo "==> Prerequisites"
for t in mkfs.vfat mcopy debugfs; do
	command -v "$t" >/dev/null || { echo "missing: $t"; exit 1; }
done
KVER=$(ls "$RFS"/lib/modules/ 2>/dev/null | grep -v '^\.' | head -1)
[ -n "$KVER" ] || { echo "ERROR: no kernel in $RFS/lib/modules (run make-debian-rootfs.sh first)"; exit 1; }
VMLINUZ="$RFS/boot/vmlinuz-$KVER"
INITRD="$RFS/boot/initrd.img-$KVER"
[ -e "$VMLINUZ" ] && [ -e "$INITRD" ] || { echo "ERROR: kernel/initrd missing for $KVER"; exit 1; }
# GRUB 2.12 in the iPXE Uri() device-path environment cannot reliably
# determine its boot device, so the stock Debian monolithic image never
# reads the ESP grub.cfg (it stops at the grub> prompt without issuing
# any SAN reads).  Build our own image with an embedded early config
# that searches the rootfs UUID directly.
#
# The embedded config runs from the rescue parser BEFORE normal loads, so
# it must not execute grub.cfg (menuentry etc. are normal's commands and
# the whole script would fail).  It only pins the root device; normal then
# reads (root)/boot/grub/grub.cfg itself (prefix is compiled in as
# /boot/grub and resolves relative to root).
#
# Debian 13 (grub-efi-amd64-bin 2.12) ships grub-mkimage and modules
# under /usr/bin and /usr/lib/grub/x86_64-efi; use them so the image
# matches the rootfs module version.  Fall back to the stock monolithic
# image (Debian 13 ships it under monolithic/) if unavailable.
#
# NOTE: Debian's 2.12 packaging merged the script module into normal and
# ships no script.mod, so it must not appear in the module list.
echo "==> GRUB image (grub-mkimage + embedded early config)"
GRUBEFI="$D/.grubx64.efi"
GMI="$RFS/usr/bin/grub-mkimage"
GMOD="$RFS/usr/lib/grub/x86_64-efi"
if [ -x "$GMI" ] && [ -d "$GMOD" ]; then
	cat > "$D/.grub-embedded.cfg" <<EOF
echo === EMBED START ===
search --no-floppy --fs-uuid $ROOTFS_UUID --set=root
echo === EMBED DONE root=\$root ===
EOF
	"$GMI" -O x86_64-efi -d "$GMOD" -o "$GRUBEFI" -p /boot/grub \
		-c "$D/.grub-embedded.cfg" \
		normal search search_fs_uuid part_gpt part_msdos ext2 fat \
		linux xzio gzio serial terminal echo ls configfile test >/dev/null || {
		echo "ERROR: grub-mkimage failed"; exit 1; }
else
	GRUBEFI="$RFS/usr/lib/grub/x86_64-efi/monolithic/grubx64.efi"
	[ -e "$GRUBEFI" ] || GRUBEFI="$RFS/usr/lib/grub/x86_64-efi/grubx64.efi"
	[ -e "$GRUBEFI" ] || { echo "ERROR: no GRUB image available"; exit 1; }
fi
echo "  kernel: $KVER"

echo "==> Blank disk image (${SIZE_M}M)"
# Recreate from scratch: a stale image from a previous failed run would
# otherwise keep its old owner (e.g. a non-root leftover).
rm -f "$IMG"
truncate -s "${SIZE_M}M" "$IMG"

echo "==> GPT (4K sectors): ESP ${ESP_M}M@${ESP_START_M}M + rootfs"
python3 - "$IMG" "$ESP_M" "$ESP_START_M" "$SIZE_M" <<'PYEOF'
import struct, sys, zlib

path, esp_m, esp_start_m, size_m = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
sector = 4096
sectors = size_m * 1024 * 1024 // sector
first_usable = 34
last_usable = sectors - 34 - 1
esp_start = esp_start_m * 1024 * 1024 // sector      # 8 MiB
esp_sectors = esp_m * 1024 * 1024 // sector          # 76800 x 4K (> 65525 FAT32 min)
esp_end = esp_start + esp_sectors - 1
root_start = esp_end + 1
root_end = last_usable

def guid_bytes(u):
    # GPT GUIDs are stored mixed-endian: the first three components are
    # little-endian (EFI spec).  Writing a UUID string as plain hex would
    # read back byte-swapped (a1b2c3d4-... would surface as d4c3b2a1-...)
    # and never match root=PARTUUID=...
    b = bytes.fromhex(u)
    return b[3::-1] + b[5:3:-1] + b[7:5:-1] + b[8:]

# Protective MBR (LBA0)
mbr = bytearray(sector)
mbr[0x1BE + 4] = 0xEE
mbr[0x1BE + 8:0x1BE + 12] = struct.pack('<I', 1)
mbr[0x1BE + 12:0x1BE + 16] = struct.pack('<I', sectors - 1)
mbr[0x1FE:0x200] = b'\x55\xaa'

# GPT header (LBA1)
header = bytearray(92)
header[0:8] = b'EFI PART'
header[8:12] = struct.pack('<I', 0x00010000)
header[12:16] = struct.pack('<I', 92)
header[24:32] = struct.pack('<Q', 1)
header[32:40] = struct.pack('<Q', sectors - 1)
header[40:48] = struct.pack('<Q', first_usable)
header[48:56] = struct.pack('<Q', last_usable)
header[56:72] = guid_bytes('4dc45c6de8a6bf47b0b0009e0c71d2c1')  # disk GUID
header[72:80] = struct.pack('<Q', 2)
header[80:84] = struct.pack('<I', 128)
header[84:88] = struct.pack('<I', 128)

# Partition table (LBA2-5): ESP + rootfs (fixed PARTUUID for the rootfs).
# GUIDs are canonical UUID strings; guid_bytes() puts them on disk in
# the mixed-endian form GPT mandates (see helper above).
parts = [
    # ESP
    ('c12a7328f81f11d2ba4b00a0c93ec93b', '00a0c9e1933e4b88b8d1e2a90d1c2e3f',
     esp_start, esp_end, 'EFI System Partition'),
    # rootfs: Linux filesystem type GUID, PARTUUID fixed (disk-inherent)
    ('0fc63daf848347728e793d69d8477de4', 'a1b2c3d4111122223333444455556666',
     root_start, root_end, 'Linux rootfs'),
]
part = bytearray(128 * 128)
# NOTE: plain slice assignment copies (part[i*128:...] yields a new bytes),
# so writes would be lost and the table would stay all-zero.  Use a
# memoryview slice to write through to the buffer.
for i, (tguid, uguid, s, e, name) in enumerate(parts):
    p = memoryview(part)[i * 128:(i + 1) * 128]
    p[0:16] = guid_bytes(tguid)
    p[16:32] = guid_bytes(uguid)
    p[32:40] = struct.pack('<Q', s)
    p[40:48] = struct.pack('<Q', e)
    n = name.encode('utf-16le')
    p[56:56 + len(n)] = n
header[88:92] = struct.pack('<I', zlib.crc32(part))
header[16:20] = struct.pack('<I', zlib.crc32(header))

with open(path, 'r+b') as f:
    f.seek(0)
    f.write(mbr)
    f.seek(sector)
    f.write(header)
    f.seek(2 * sector)
    f.write(part)
    # Backup partition table: canonical GPT location is last_usable+1
    # (EDK2 PartitionDxe cross-checks it there; sectors-5 would leave
    # zeroes at that LBA and fail the CRC check).
    backup_table_lba = last_usable + 1
    f.seek(backup_table_lba * sector)
    f.write(part)
    f.seek((sectors - 1) * sector)
    header[24:32] = struct.pack('<Q', sectors - 1)
    header[32:40] = struct.pack('<Q', 1)
    header[72:80] = struct.pack('<Q', backup_table_lba)
    header[16:20] = struct.pack('<I', 0)
    header[16:20] = struct.pack('<I', zlib.crc32(header))
    f.write(header)
print('GPT written: ESP LBA %d-%d, rootfs LBA %d-%d' % (esp_start, esp_end, root_start, root_end))
PYEOF

echo "==> Rootfs filesystem (ext4, fixed UUID, -d copies from $RFS)"
ROOTFS_IMG=$D/.rootfs.img
rm -f "$ROOTFS_IMG"
# Rootfs partition spans root_start..last_usable, the same 4K geometry the
# GPT writer above computes.  The staging image must be exactly that many
# blocks: a MiB-rounded size makes ext4 claim blocks past the partition end
# (kernel mount check fails: "bad geometry ... exceeds size of device") and
# the dd tail would clobber the backup GPT table/header at the disk end.
SECTORS=$((SIZE_M * 1024 * 1024 / 4096))
LAST_USABLE=$((SECTORS - 34 - 1))
ROOT_START=$(((ESP_START_M + ESP_M) * 1024 * 1024 / 4096))
ROOT_BLOCKS=$((LAST_USABLE - ROOT_START + 1))
truncate -s $((ROOT_BLOCKS * 4096)) "$ROOTFS_IMG"
mkfs.ext4 -q -F -U "$ROOTFS_UUID" -d "$RFS" "$ROOTFS_IMG"
dd if="$ROOTFS_IMG" of="$IMG" bs=4096 seek="$ROOT_START" conv=notrunc status=none

echo "==> grub.cfg (static; disk-inherent root identifiers only)"
ROOTFS_OFF_BYTES=$((8 + ESP_M))  # MiB, for debugfs workaround note
cat > "$D/.grub.cfg" <<EOF
set timeout=5
set default=0

serial --unit=0 --speed=115200
terminal_input serial
terminal_output serial

menuentry "Debian 13 (trixie) NVMe/TCP SAN" {
	search --no-floppy --fs-uuid $ROOTFS_UUID --set=root
	linux /boot/vmlinuz-$KVER root=PARTUUID=$ROOTFS_PARTUUID \
		ip=dhcp ipv6.disable=1 nbft_auto rootwait console=ttyS0,115200
	initrd /boot/initrd.img-$KVER
}
EOF
# The static grub.cfg lives in the rootfs /boot/grub/ (GRUB prefix of the
# Debian grubx64.efi).  debugfs appends it without a mount (no root needed);
# ownership is irrelevant for a GRUB-readable config.
ROOTFS_IMG_SZ=$(stat -c%s "$ROOTFS_IMG")
debugfs -w -R "mkdir /boot/grub" "$ROOTFS_IMG" >/dev/null 2>&1 || true
debugfs -w -R "write $D/.grub.cfg /boot/grub/grub.cfg" "$ROOTFS_IMG"
echo "  /boot/grub/grub.cfg written (grub.cfg source: $D/.grub.cfg)"

echo "==> ESP filesystem (FAT32 4K) + BOOTX64.EFI + grub.cfg"
rm -f "$ESP"
truncate -s "${ESP_M}M" "$ESP"
mkfs.vfat -F 32 -S 4096 -n IPXENVME "$ESP"
rm -rf "$STAGE"
mkdir -p "$STAGE/EFI/BOOT" "$STAGE/boot/grub"
cp "$GRUBEFI" "$STAGE/EFI/BOOT/BOOTX64.EFI"
# Debian grubx64.efi (monolithic) has its prefix compiled in as /boot/grub
# and reads grub.cfg from the *boot device* only (the ESP, i.e. the SAN
# partition iPXE booted from), not from the rootfs.  Ship the same static
# config on the ESP as well; the rootfs copy stays for on-metal deploys.
cp "$D/.grub.cfg" "$STAGE/boot/grub/grub.cfg"
mcopy -i "$ESP" -s "$STAGE"/* ::/
dd if="$ESP" of="$IMG" bs=1M seek="$ESP_START_M" conv=notrunc status=none

echo "==> Verify"
ls -la "$IMG"
mdir -i "$ESP" ::/EFI/BOOT/
debugfs -R "stat /boot/grub/grub.cfg" "$ROOTFS_IMG" 2>/dev/null | head -5 || true
rm -rf "$STAGE" "$ESP" "$ROOTFS_IMG" "$D/.grub.cfg" "$D/.grub-embedded.cfg"
echo "==> DONE: $IMG (ESP @${ESP_START_M}M, rootfs @$((ESP_START_M + ESP_M))M, kernel $KVER)"
