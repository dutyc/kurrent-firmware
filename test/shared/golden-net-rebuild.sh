#!/bin/bash
# golden-net-rebuild.sh - 宿主重启后测试网络重建(br0/tap0 + NAT)
# 用法: sudo bash golden-net-rebuild.sh
# 说明:
#   - WAN 出口自动探测(默认路由);tap0 owner=当前用户(QEMU 免 root attach)
#   - dnsmasq 容器(br0 接口绑定)在 br0 出现后自愈
set -e

WAN=$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
[ -n "$WAN" ] || { echo "ERROR: 找不到默认路由出口"; exit 1; }
USER_NAME=${SUDO_USER:-$(id -un)}

TAP_OWNER=${TAP_OWNER:-lecreate}

echo "==> br0(192.168.80.2/24)"
ip link add br0 type bridge 2>/dev/null || true
ip addr add 192.168.80.2/24 dev br0 2>/dev/null || true
ip link set br0 up

echo "==> tap0(owner $TAP_OWNER,接入 br0)"
ip link del tap0 2>/dev/null || true
sleep 1
ip tuntap add mode tap dev tap0 user "$TAP_OWNER"
ip link set tap0 master br0 2>/dev/null || true
ip link set tap0 up

echo "==> 转发与 NAT(MASQUERADE -> $WAN)"
sysctl -w net.ipv4.ip_forward=1 >/dev/null
iptables -t nat -C POSTROUTING -s 192.168.80.0/24 -o "$WAN" -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s 192.168.80.0/24 -o "$WAN" -j MASQUERADE
iptables -C FORWARD -i br0 -o "$WAN" -j ACCEPT 2>/dev/null || iptables -A FORWARD -i br0 -o "$WAN" -j ACCEPT
iptables -C FORWARD -i "$WAN" -o br0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -A FORWARD -i "$WAN" -o br0 -m state --state RELATED,ESTABLISHED -j ACCEPT

ip -br link show br0
ip -br addr show br0
ip -br link show tap0
echo "NET_OK(dnsmasq 容器将在下一次自动重启时自愈)"
