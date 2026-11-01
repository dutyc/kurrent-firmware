#!/bin/bash
# fwtest-nvmet-tls.sh - 本地 nvmet 验收靶：DH-HMAC-CHAP 主机 + TLS 1.3 端口 + PSK
#
# 用法（root）:
#   bash test/shared/fwtest-nvmet-tls.sh setup <image> <subsysnqn> <hostnqn> <dhhc-secret> [traddr] [trsvcid] [portid]
#   bash test/shared/fwtest-nvmet-tls.sh teardown <subsysnqn> <hostnqn> <portid>
#
# 设计要点：
#   - 端口级 addr_tsas=tls1.3 / addr_treq=required：连接必须 TLS；
#   - nvmet 从内核全局 .nvme keyring 按 identity "NVMe0R01 <hostnqn> <subnqn>"
#     取 PSK（description=identity, payload=raw PSK），不做 configfs 密钥配置；
#   - PSK 由控制面算法派生（HMAC-SHA256(raw DHHC key, "kurrent-nvme-tls-psk-v1")），
#     与固件 tls_psk / NBCT tls_psk 为同一串十六进制；
#   - host 必须登记在 allowed_hosts（allow_any_host=0），否则连接被拒。
set -euo pipefail

SYS=/sys/kernel/config/nvmet
[ "$(id -u)" = 0 ] || { echo "ERROR: 请以 root 运行" >&2; exit 1; }
command -v keyctl >/dev/null || { echo "ERROR: 缺少 keyctl（keyutils）" >&2; exit 1; }

action=${1:?setup|teardown}

psk_from_secret() {
    python3 - "$1" <<'PYEOF'
import base64, hashlib, hmac, sys
secret = sys.argv[1]
raw = base64.b64decode(secret.split(':', 2)[2])[:32]
print(hmac.new(raw, b'kurrent-nvme-tls-psk-v1', hashlib.sha256).hexdigest())
PYEOF
}

# 把 PMK 注入 .nvme keyring（ctypes add_key；容器/宿主均可用，无需 libkeyutils）
inject_psk() {
    python3 - "$1" "$2" <<'PYEOF'
import ctypes, os, sys
identity, psk_hex, keys_file = sys.argv[1], sys.argv[2], '/proc/keys'
libc = ctypes.CDLL(None, use_errno=True)
SYS_ADD_KEY, SYS_KEYCTL = 248, 250
KEYCTL_UNLINK = 9
keyring = None
for line in open(keys_file, encoding='utf-8', errors='replace'):
    if 'keyring' in line and '.nvme' in line:
        keyring = int(line.split()[0], 16)
        break
if keyring is None:
    sys.exit('ERROR: kernel .nvme keyring not found (modprobe nvme-keyring)')
psk = bytes.fromhex(psk_hex)
if len(psk) != 32:
    sys.exit(f'ERROR: PSK must be 32 bytes, got {len(psk)}')
serial = libc.syscall(SYS_ADD_KEY, b'psk', identity.encode(), psk, len(psk), keyring)
if serial < 0:
    err = ctypes.get_errno()
    sys.exit(f'ERROR: add_key failed: {os.strerror(err)}')
print(f'  PSK key added: serial={serial} identity={identity}')
PYEOF
}

delete_psk() {
    python3 - "$1" <<'PYEOF'
import ctypes, os, sys
identity = sys.argv[1]
libc = ctypes.CDLL(None, use_errno=True)
SYS_ADD_KEY, SYS_KEYCTL = 248, 250
KEYCTL_READ, KEYCTL_UNLINK = 11, 9
keyring = None
for line in open('/proc/keys', encoding='utf-8', errors='replace'):
    if 'keyring' in line and '.nvme' in line:
        keyring = int(line.split()[0], 16)
        break
if keyring is None:
    sys.exit(0)
# 读取 keyring 内 serial 列表，逐个 DESCRIBE 匹配 identity
buf = ctypes.create_string_buffer(8192)
n = libc.syscall(SYS_KEYCTL, KEYCTL_READ, keyring, buf, len(buf))
if n < 0:
    sys.exit(0)
import struct
for i in range(0, n, 4):
    serial = struct.unpack('<i', buf.raw[i:i + 4])[0]
    dbuf = ctypes.create_string_buffer(4096)
    m = libc.syscall(SYS_KEYCTL, 6, serial, dbuf, len(dbuf))  # KEYCTL_DESCRIBE
    if m < 0:
        continue
    desc = dbuf.raw[:m].split(b'\x00', 1)[0].decode('utf-8', 'replace').split(';', 4)
    if len(desc) == 5 and desc[4] == identity:
        libc.syscall(SYS_KEYCTL, KEYCTL_UNLINK, serial, keyring)
        print(f'  PSK key removed: serial={serial}')
PYEOF
}

case "$action" in
setup)
    IMG=${2:?image}
    NQN=${3:?subsysnqn}
    HOSTNQN=${4:?hostnqn}
    SECRET=${5:?dhhc-secret}
    TRADDR=${6:-192.168.81.1}
    TRSVCID=${7:-4421}
    PORTID=${8:-3}
    PSK=$(psk_from_secret "$SECRET")
    echo "==> PSK: $PSK"

    modprobe nvmet 2>/dev/null || true
    modprobe nvmet_tcp 2>/dev/null || true
    modprobe nvme-keyring 2>/dev/null || modprobe nvme_keyring 2>/dev/null || true
    [ -e "$IMG" ] || { echo "ERROR: image 不存在: $IMG" >&2; exit 1; }
    [ -d "$SYS/ports/$PORTID" ] && { echo "ERROR: port $PORTID 已存在（先 teardown）" >&2; exit 1; }

    delete_psk "NVMe0R01 $HOSTNQN $NQN"
    inject_psk "NVMe0R01 $HOSTNQN $NQN" "$PSK"

    # 先建 port 并写 TLS 属性（端口一旦 link 子系统即不可再改 addr_tsas）
    mkdir -p "$SYS/ports/$PORTID"
    echo ipv4 > "$SYS/ports/$PORTID/addr_adrfam"
    echo tcp > "$SYS/ports/$PORTID/addr_trtype"
    echo -n "$TRADDR" > "$SYS/ports/$PORTID/addr_traddr"
    echo "$TRSVCID" > "$SYS/ports/$PORTID/addr_trsvcid"
    echo tls1.3 > "$SYS/ports/$PORTID/addr_tsas"
    echo required > "$SYS/ports/$PORTID/addr_treq"

    mkdir -p "$SYS/subsystems/$NQN"
    echo 0 > "$SYS/subsystems/$NQN/attr_allow_any_host"
    mkdir -p "$SYS/subsystems/$NQN/namespaces/1"
    echo -n "$IMG" > "$SYS/subsystems/$NQN/namespaces/1/device_path"
    echo 1 > "$SYS/subsystems/$NQN/namespaces/1/enable"

    mkdir -p "$SYS/hosts/$HOSTNQN"
    echo -n "$SECRET" > "$SYS/hosts/$HOSTNQN/dhchap_key"
    echo ffdhe4096 > "$SYS/hosts/$HOSTNQN/dhchap_dhgroup"
    ln -sfn "$SYS/hosts/$HOSTNQN" "$SYS/subsystems/$NQN/allowed_hosts/$HOSTNQN"

    ln -sfn "$SYS/subsystems/$NQN" "$SYS/ports/$PORTID/subsystems/$NQN"

    echo "==> 靶场就绪"
    echo "  port:   $TRADDR:$TRSVCID (tls1.3, treq=required)"
    echo "  subsys: $NQN"
    echo "  host:   $HOSTNQN (allowed_hosts)"
    echo "  image:  $IMG"
    ss -ltnp 2>/dev/null | grep ":$TRSVCID " || true
    ;;
teardown)
    NQN=${2:?subsysnqn}
    HOSTNQN=${3:?hostnqn}
    PORTID=${4:-3}
    rm -f "$SYS/ports/$PORTID/subsystems/$NQN" 2>/dev/null || true
    rm -f "$SYS/subsystems/$NQN/allowed_hosts/$HOSTNQN" 2>/dev/null || true
    [ -d "$SYS/subsystems/$NQN" ] && {
        echo 0 > "$SYS/subsystems/$NQN/namespaces/1/enable" 2>/dev/null || true
        rmdir "$SYS/subsystems/$NQN/namespaces/1" 2>/dev/null || true
        rmdir "$SYS/subsystems/$NQN" 2>/dev/null || true
    }
    rmdir "$SYS/hosts/$HOSTNQN" 2>/dev/null || true
    rmdir "$SYS/ports/$PORTID" 2>/dev/null || true
    delete_psk "NVMe0R01 $HOSTNQN $NQN"
    echo "teardown OK"
    ;;
*)
    echo "用法: $0 setup|teardown ..." >&2
    exit 1
    ;;
esac
