#!/bin/bash
# run-archlinux-setup.sh - boot the installed Arch golden image and run the
# customization script over SSH
#
# Usage:
#   bash golden/archlinux/run-archlinux-setup.sh [--skip-disk] [--yes] [other setup options]
#
# Prerequisite: run-archlinux-install.sh has produced .cache/vm/archlinux.raw
# and the SSH key. The customization script is piped over stdin, so the guest
# needs no repository checkout; the ktls-utils tarball is served over HTTP.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
CACHE=$ROOT/.cache
RAW=${RAW:-$CACHE/vm/archlinux.raw}
VARS=$CACHE/vm/archlinux-OVMF_VARS.fd
LOG=${LOG:-$CACHE/vm/archlinux-setup.serial}
SETUP_LOG=${SETUP_LOG:-$CACHE/vm/archlinux-setup.log}
HTTP_PORT=${HTTP_PORT:-8012}
HTTP_PID_FILE=$CACHE/archsetup/http-$HTTP_PORT.pid
SSH_KEY=$CACHE/ssh/archlinux
SCRIPT=$ROOT/golden/archlinux/golden-image-setup-archlinux.sh
SSH_PORT=${SSH_PORT:-2227}

[ -f "$RAW" ] || { echo "ERROR: missing target disk $RAW (run run-archlinux-install.sh first)" >&2; exit 1; }
[ -f "$SSH_KEY" ] || { echo "ERROR: missing SSH key $SSH_KEY" >&2; exit 1; }
[ -f "$SCRIPT" ] || { echo "ERROR: missing setup script $SCRIPT" >&2; exit 1; }

mkdir -p "$CACHE/archsetup" "$CACHE/vm"
KTLS_ARG=
if [ -f "$CACHE/ktls-utils-1.5.0.tar.gz" ]; then
    cp -f "$CACHE/ktls-utils-1.5.0.tar.gz" "$CACHE/archsetup/"
    KTLS_ARG="--ktls-utils-url http://10.0.2.2:$HTTP_PORT/ktls-utils-1.5.0.tar.gz"
else
    echo "WARN: $CACHE/ktls-utils-1.5.0.tar.gz missing; the guest uses the default source"
fi

if curl -fsS "http://127.0.0.1:$HTTP_PORT/" >/dev/null 2>&1; then
    echo "ERROR: port $HTTP_PORT is already in use; retry with HTTP_PORT=..." >&2
    exit 1
fi
python3 -m http.server "$HTTP_PORT" --bind 0.0.0.0 --directory "$CACHE/archsetup" \
    > "$CACHE/vm/arch-setup-http.log" 2>&1 < /dev/null &
echo $! > "$HTTP_PID_FILE"
sleep 1

rm -f "$LOG"
echo "==> starting the installed Arch VM (serial $LOG)"
qemu-system-x86_64 \
    -machine q35,accel=kvm -cpu host -m 3072 -smp 2 \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
    -drive if=pflash,format=raw,file="$VARS" \
    -drive file="$RAW",if=none,id=d0,format=raw,cache=unsafe \
    -device virtio-blk-pci,drive=d0,logical_block_size=4096,physical_block_size=4096 \
    -netdev user,id=n0,hostfwd=tcp::${SSH_PORT}-:22 \
    -device virtio-net-pci,netdev=n0 \
    -serial file:"$LOG" -display none -monitor none &
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

SSH=(ssh -i "$SSH_KEY" -p "$SSH_PORT" -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 \
    -o ServerAliveInterval=30 root@127.0.0.1)

echo "==> waiting for SSH on the installed system"
ready=0
for _ in $(seq 1 120); do
    if "${SSH[@]}" true 2>/dev/null; then
        ready=1
        break
    fi
    if ! kill -0 "$QPID" 2>/dev/null; then
        echo "ERROR: VM exited early; serial tail:" >&2
        tail -30 "$LOG" >&2 || true
        exit 1
    fi
    sleep 2
done
[ "$ready" = 1 ] || { echo "ERROR: SSH not ready within 240s" >&2; tail -30 "$LOG" >&2; exit 1; }

echo "==> running the setup script (root inside the guest)"
set +e
"${SSH[@]}" "bash -s -- $KTLS_ARG $*" \
    < "$SCRIPT" 2>&1 | tee "$SETUP_LOG"
rc=${PIPESTATUS[0]}
set -e

echo "==> setup script exit code: $rc"
if [ "$rc" != 0 ]; then
    # Sync before a hard kill so written packages and files are not lost.
    "${SSH[@]}" 'sync' 2>/dev/null || true
fi
if [ "$rc" = 0 ]; then
    echo "==> powering off"
    "${SSH[@]}" 'sync; poweroff -f' 2>/dev/null || true
    sleep 3
fi
tail -20 "$SETUP_LOG" || true
exit "$rc"
