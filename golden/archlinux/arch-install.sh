#!/bin/bash
# arch-install.sh - unattended install entry point inside the archiso live environment.
#
# Usage (inside the live ISO):
#   bash arch-install.sh
#
# The host serves archinstall.json over HTTP (see run-archlinux-install.sh).
# Every exit path must print ARCH_INSTALL_RC=<rc> and power off: the host
# serial wait uses that marker, otherwise it can only time out. The EXIT trap
# preserves set -e semantics while still emitting the marker.
set -euo pipefail

BASE=${BASE:-http://10.0.2.2:8011}
MIRROR=${MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/archlinux}

finish() {
    local rc=$?
    trap - EXIT
    echo "==> archinstall exit code $rc"
    echo "ARCH_INSTALL_RC=$rc"
    sync
    poweroff -f
    exit "$rc"
}
trap finish EXIT

printf 'Server = %s/$repo/os/$arch\n' "$MIRROR" > /etc/pacman.d/mirrorlist

echo "==> download the archinstall configuration"
curl -fsSL --retry 5 --retry-delay 2 "$BASE/archinstall.json" -o /tmp/archinstall.json

echo "==> archinstall --silent starts"
archinstall --config /tmp/archinstall.json --silent \
    --skip-version-check --skip-wifi-check --skip-ntp --skip-wkd
