#!/bin/bash
# fwtest-net.sh - 隔离验收网桥（br-fwtest + tap0fw），供 PXE 冷启动使用
#
# 用法: sudo bash test/shared/fwtest-net.sh setup|teardown
# 说明: 独立 192.168.81.0/24，不与生产 br0(192.168.80.0/24) 冲突；
#       tap 归调用用户所有，QEMU 免 root 接入。
set -euo pipefail

BR=${BR:-br-fwtest}
TAP=${TAP:-tap0fw}
HOST_CIDR=${HOST_CIDR:-192.168.81.1/24}
OWNER=${SUDO_USER:-${OWNER:-lecreate}}

[ "$(id -u)" = 0 ] || { echo "ERROR: 请以 root 运行" >&2; exit 1; }

case "${1:-}" in
setup)
    ip link add "$BR" type bridge 2>/dev/null || true
    ip addr add "$HOST_CIDR" dev "$BR" 2>/dev/null || true
    ip link set "$BR" up

    ip link del "$TAP" 2>/dev/null || true
    sleep 1
    ip tuntap add mode tap dev "$TAP" user "$OWNER"
    ip link set "$TAP" master "$BR"
    ip link set "$TAP" up

    ip -br addr show "$BR"
    ip -br link show "$TAP"
    ;;
teardown)
    ip link del "$TAP" 2>/dev/null || true
    ip link del "$BR" 2>/dev/null || true
    echo "teardown OK"
    ;;
*)
    echo "用法: $0 setup|teardown" >&2
    exit 1
    ;;
esac
