#!/bin/bash
# run-archlinux-install.sh - unattended Arch Linux install VM (archinstall + OVMF)
#
# Usage: bash test/archlinux/run-archlinux-install.sh [ISO]
# Default ISO: <repo>/.cache/isos/archlinux-2026.11.01-x86_64.iso
#
# Flow: 4K-logical virtio-blk target disk -> extract the archiso kernel/initrd
#       -> host HTTP serves the archinstall JSON -> serial login into the live
#       ISO -> archinstall --silent -> automatic power-off.
# Result: .cache/vm/archlinux.raw (10G sparse), .cache/vm/archlinux-install.serial
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
CACHE=$ROOT/.cache
ISO=${1:-$CACHE/isos/archlinux-2026.11.01-x86_64.iso}
RAW=${RAW:-$CACHE/vm/archlinux.raw}
VARS=$CACHE/vm/archlinux-OVMF_VARS.fd
KDIR=$CACHE/vm/archlinux-install
LOG=$CACHE/vm/archlinux-install.serial
KS_DIR=$CACHE/archinstall
KS_RUN=$KS_DIR/archinstall.json
HTTP_PORT=${HTTP_PORT:-8011}
HTTP_PID_FILE=$CACHE/archinstall/http-$HTTP_PORT.pid
SOCK=$CACHE/vm/archlinux-install.sock
SSH_KEY=$CACHE/ssh/archlinux
TEMPLATE=$ROOT/test/archlinux/archinstall.json.in
WRAPPER=$ROOT/test/archlinux/arch-install.sh

. "$ROOT/test/shared/golden-install-vm.sh"

[ -f "$ISO" ] || { echo "ERROR: missing ISO: $ISO" >&2; exit 1; }

mkdir -p "$CACHE/vm" "$KDIR" "$KS_DIR" "$CACHE/ssh"
install_vm_ssh_key "$SSH_KEY" golden-archlinux
install_vm_extract_iso "$ISO" "$KDIR" \
    /arch/boot/x86_64/vmlinuz-linux:vmlinuz-linux \
    /arch/boot/x86_64/initramfs-linux.img:initramfs-linux.img

echo "==> generate the runtime archinstall configuration (public key injected)"
python3 - "$TEMPLATE" "$KS_RUN" "$(cat "$SSH_KEY.pub")" <<'PYEOF'
import json
import sys

template, target, pubkey = sys.argv[1:]
data = open(template).read().replace('__GOLDEN_SSH_PUBKEY__', pubkey)
json.loads(data)  # fail early on a broken template or placeholder
open(target, 'w').write(data)
PYEOF
cp -f "$WRAPPER" "$KS_DIR/arch-install.sh"
cp -f "$CACHE/ktls-utils-1.5.0.tar.gz" "$KS_DIR/" 2>/dev/null || true

if curl -fsS "http://127.0.0.1:$HTTP_PORT/" >/dev/null 2>&1; then
    echo "ERROR: port $HTTP_PORT is already in use; retry with HTTP_PORT=..." >&2
    exit 1
fi
echo "==> serving the configuration on :$HTTP_PORT (directory $KS_DIR)"
python3 -m http.server "$HTTP_PORT" --bind 0.0.0.0 --directory "$KS_DIR" \
    > "$CACHE/vm/arch-install-http.log" 2>&1 < /dev/null &
echo $! > "$HTTP_PID_FILE"
sleep 1
curl -fsS "http://127.0.0.1:$HTTP_PORT/archinstall.json" >/dev/null

install_vm_prepare_target "$RAW" "$VARS"

LABEL=$(blkid -s LABEL -o value "$ISO")
[ -n "$LABEL" ] || { echo "ERROR: cannot read the ISO volume label" >&2; exit 1; }

rm -f "$LOG" "$SOCK"
echo "==> starting the archiso install VM (serial log $LOG, powers off when done)"
qemu-system-x86_64 \
    -machine q35,accel=kvm -cpu host -m 3072 -smp 2 \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
    -drive if=pflash,format=raw,file="$VARS" \
    -drive file="$RAW",if=none,id=d0,format=raw,cache=unsafe \
    -device virtio-blk-pci,drive=d0,logical_block_size=4096,physical_block_size=4096 \
    -netdev user,id=n0,hostfwd=tcp::2227-:22 \
    -device virtio-net-pci,netdev=n0 \
    -cdrom "$ISO" \
    -kernel "$KDIR/vmlinuz-linux" -initrd "$KDIR/initramfs-linux.img" \
    -append "archisobasedir=arch archisolabel=${LABEL} console=ttyS0,115200" \
    -serial unix:"$SOCK",server=on,wait=off -display none -monitor none &
QPID=$!

cleanup() {
    kill "$QPID" 2>/dev/null || true
    wait "$QPID" 2>/dev/null || true
    if [ -f "$HTTP_PID_FILE" ]; then
        kill "$(cat "$HTTP_PID_FILE")" 2>/dev/null || true
        rm -f "$HTTP_PID_FILE"
    fi
}
trap cleanup EXIT

python3 - "$SOCK" "$LOG" "$HTTP_PORT" "${INSTALL_TIMEOUT:-3600}" <<'PYEOF'
import re
import socket
import sys
import time

sock_path, log_path, http_port, timeout = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
log = open(log_path, 'wb', buffering=0)

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
for _ in range(120):
    try:
        sock.connect(sock_path)
        break
    except (FileNotFoundError, ConnectionRefusedError):
        time.sleep(0.5)
else:
    sys.exit('ERROR: cannot connect to the QEMU serial socket')

sock.setblocking(False)
buf = b''


def pump(seconds):
    global buf
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            chunk = sock.recv(65536)
        except BlockingIOError:
            time.sleep(0.1)
            continue
        except OSError:
            return False
        if not chunk:
            return False
        log.write(chunk)
        buf += chunk
        if len(buf) > (1 << 20):
            buf = buf[-(1 << 19):]
    return True


def wait_for(patterns, seconds):
    deadline = time.time() + seconds
    while time.time() < deadline:
        for pattern in patterns:
            if pattern in buf:
                return pattern
        if not pump(1):
            return None
    return None


print('==> waiting for the live ISO login prompt', flush=True)
hit = wait_for([b'login:', b']# '], 600)
if hit is None:
    sys.exit('ERROR: no login prompt within 600s')
if hit == b'login:':
    sock.sendall(b'root\n')
    print('==> sent the root login', flush=True)
    if wait_for([b']# ', b'# '], 120) is None:
        sys.exit('ERROR: no shell prompt after login')

# One line only: archinstall consumes terminal input, so later commands must
# not be pre-fed through the serial port.
command = (
    'until curl -fsSL -o /tmp/arch-install.sh '
    f'http://10.0.2.2:{http_port}/arch-install.sh; do sleep 2; done; '
    'bash /tmp/arch-install.sh\n'
)
print('==> starting archinstall', flush=True)
sock.sendall(command.encode())

deadline = time.time() + timeout
match = None
while time.time() < deadline:
    match = re.search(rb'ARCH_INSTALL_RC=([0-9]+)', buf)
    if match:
        break
    if not pump(1):
        match = re.search(rb'ARCH_INSTALL_RC=([0-9]+)', buf)
        break
if match is None:
    tail = buf[-4000:].decode('utf-8', 'replace')
    sys.exit(f'ERROR: install timed out ({timeout}s) or the VM exited early; serial tail:\n{tail}')

print(f'==> install exit code: {match.group(1).decode()}', flush=True)
wait_for([b'reboot: Power down'], 30)
time.sleep(1)
PYEOF

# Give QEMU up to 60s to power off; killing earlier risks a half-written image.
for _ in $(seq 1 60); do
    kill -0 "$QPID" 2>/dev/null || break
    sleep 1
done
if kill -0 "$QPID" 2>/dev/null; then
    echo "WARN: QEMU did not exit within 60s, terminating"
    kill "$QPID" 2>/dev/null || true
fi
wait "$QPID" 2>/dev/null || true

echo "==> QEMU exited; serial tail:"
tail -25 "$LOG"
if grep -q 'ARCH_INSTALL_RC=0' "$LOG"; then
    echo "RESULT: ARCH_INSTALL_OK"
else
    echo "RESULT: ARCH_INSTALL_FAILED"
    exit 1
fi
