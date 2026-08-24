#!/bin/bash
# NVMe-oF target setup for QEMU validation of the iPXE nvmetcp driver.
# Idempotent: safe to re-run.
# Usage: sudo bash test/nvmet-setup.sh
#        sudo AUTH=1 bash test/nvmet-setup.sh   # enable DH-HMAC-CHAP auth
set -e

ROOT=$(cd "$(dirname "$0")/.." && pwd)

NQN="nqn.2026-08.org.ipxe-stateless:test"
# backing 文件支持环境覆盖（如 VMware 盘作为 target）
IMG="${IMG:-$ROOT/diag/nvme-boot.img}"
SYS=/sys/kernel/config/nvmet/subsystems/$NQN
PORT=/sys/kernel/config/nvmet/ports/1

# DH-HMAC-CHAP authentication (disabled by default)
# Host NQN must match what iPXE actually sends (QEMU+OVMF has no SMBIOS
# UUID, so iPXE falls back to the fixed suffix):
AUTH="${AUTH:-0}"
HOSTNQN="nqn.2014-08.org.ipxe:ipxe"
# DH-HMAC-CHAP key, "DHHC-1:XX:base64" format (NVMe base spec).
# XX = 01 (SHA256); base64 = 32-byte key + CRC32 little-endian.
# IMPORTANT: XX MUST be two digits.  Both kernel sides hardcode a 10-byte
# prefix skip (nvme_auth_generate_key() and nvmet_setup_auth() pass
# secret+10 to nvme_auth_extract_key()), so "DHHC-1:1:" (9 chars) silently
# truncates the first base64 char and fails with
# "base64 key decoding error -1".  iPXE parses the prefix dynamically and
# accepts either, but the kernel format is authoritative here.
# IMPORTANT: the appended CRC32 must be the standard CRC-32 final value
# (zlib.crc32, i.e. crc32_le(0xffffffff) with the final XOR).  nvmet's
# nvme_auth_extract_key() verifies ~crc32_le(0xffffffff, key) against the
# stored little-endian value and rejects the key on mismatch with
# "Failed to setup authentication, dhchap status 2".
# Regenerate with: python3 -c 'import zlib,base64; k=b"0123456789abcdef0123456789abcdef"; print("DHHC-1:01:"+base64.b64encode(k+zlib.crc32(k).to_bytes(4,"little")).decode())'
# The same string is delivered to iPXE via the HTTP credential endpoint
# (test/cred-server.py) as the sanboot ?secret= parameter.
DHHCP_KEY="DHHC-1:01:MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWYOtVl3"

# Self-check the key before writing it to configfs (set -e aborts on failure).
# Same semantics as the kernel's nvme_auth_extract_key(): 10-byte prefix skip
# (secret+10), 36/68 decoded bytes, CRC32 (zlib final value, little-endian).
python3 - "$DHHCP_KEY" <<'PYEOF'
import base64, sys, zlib
k = sys.argv[1]
assert len(k) > 10 and k[:7] == "DHHC-1:" and k[7:9].isdigit() and k[9] == ':', \
    "prefix must be exactly 'DHHC-1:XX:' (10 chars)"
raw = base64.b64decode(k[10:])
assert len(raw) in (36, 68), f"decoded key+CRC {len(raw)}B not in (36, 68)"
key, crc = raw[:-4], raw[-4:]
assert int.from_bytes(crc, "little") == zlib.crc32(key), "CRC32 mismatch"
print(f"  KEY OK: type={k[7:9]} key={len(key)}B")
PYEOF

echo "==> Loading kernel modules"
modprobe nvmet 2>/dev/null || true
modprobe nvmet_tcp

echo "==> Backing file"
# Create the backing file only if missing; the disk image itself is built
# by test/make-grub-bootdisk.sh (512M validation disk) or
# test/make-debian-san-disk.sh (2G SAN boot disk).  truncate -s would
# otherwise truncate an existing larger image.
if [ ! -e "$IMG" ]; then
        truncate -s 2G "$IMG"
fi

echo "==> Removing stale config"
# The validation environment owns port 1 / 4420 exclusively: drop every
# subsystem link (including leftovers from other projects), then remove
# the port itself.  A stale enabled port rejects attribute writes with
# EACCES ("Cannot change address family while enabled"), which surfaces
# as a confusing "write error: Permission denied" further down.
rm -f "$PORT"/subsystems/*
if [ -d "$PORT" ] && ! rmdir "$PORT" 2>/dev/null; then
	echo "WARNING: port dir still present, contents:" >&2
	ls -la "$PORT" >&2 || true
	echo "       remove it manually: sudo rmdir $PORT" >&2
fi
if [ -d "$SYS" ]; then
	# 7.x teardown: rmdir of a subsystem fails while configfs links under
	# allowed_hosts/ (stale AUTH=1 config) exist, which in turn blocks
	# "Can't set allow_any_host when explicit hosts are set!".  Drop the
	# links explicitly before removing the directory.
	rm -f "$SYS"/allowed_hosts/*
	rmdir "$SYS/namespaces/1" 2>/dev/null || true
	if ! rmdir "$SYS" 2>/dev/null; then
		echo "ERROR: subsystem dir still present (live controller?)" >&2
		echo "       check: ls /sys/kernel/config/nvmet/" >&2
		exit 1
	fi
fi

echo "==> Subsystem"
mkdir -p "$SYS"
echo 1 > "$SYS/attr_allow_any_host"
mkdir -p "$SYS/namespaces/1"
echo -n "$IMG" > "$SYS/namespaces/1/device_path"
echo 1 > "$SYS/namespaces/1/enable"

if [ "$AUTH" = "1" ]; then
	echo "==> DH-HMAC-CHAP auth (host $HOSTNQN)"
	# allow_any_host=1 makes nvmet_setup_auth() skip authentication
	# entirely (drivers/nvme/target/auth.c), so it must be disabled.
	echo 0 > "$SYS/attr_allow_any_host"
	# 7.x layout: hosts live in the global hosts group and are linked
	# into the subsystem's allowed_hosts directory (configfs link,
	# mkdir on allowed_hosts is rejected by the kernel).
	HOST_DIR=/sys/kernel/config/nvmet/hosts/$HOSTNQN
	mkdir -p "$HOST_DIR"
	echo -n "$DHHCP_KEY" > "$HOST_DIR/dhchap_key"
	# iPXE supports dhgid 0/2048/3072/4096; explicit ffdhe4096 exercises
	# the full DH exchange path
	echo ffdhe4096 > "$HOST_DIR/dhchap_dhgroup"
	ln -sf "$HOST_DIR" "$SYS/allowed_hosts/$HOSTNQN"
else
	echo "==> No authentication (AUTH=0)"
fi

echo "==> Port"
mkdir -p "$PORT"
echo ipv4 > "$PORT/addr_adrfam"
echo tcp > "$PORT/addr_trtype"
echo 127.0.0.1 > "$PORT/addr_traddr"
echo 4420 > "$PORT/addr_trsvcid"
ln -sf "$SYS" "$PORT/subsystems/$NQN"

echo "==> Verify"
cat "$SYS/attr_allow_any_host"
cat "$SYS/namespaces/1/device_path"
cat "$SYS/namespaces/1/enable"
if [ "$AUTH" = "1" ]; then
	cat "$SYS/attr_allow_any_host"
	cat "/sys/kernel/config/nvmet/hosts/$HOSTNQN/dhchap_key"
	cat "/sys/kernel/config/nvmet/hosts/$HOSTNQN/dhchap_dhgroup"
	ls "$SYS/allowed_hosts/"
fi
cat "$PORT/addr_trtype" "$PORT/addr_traddr" "$PORT/addr_trsvcid"
if ss -tln | grep -q 4420; then
	echo "==> LISTENING on 4420"
else
	echo "==> NOT LISTENING (check nvmet_tcp module)"
fi
echo "==> DONE"
