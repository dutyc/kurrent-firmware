#!/bin/bash
# fwtest-boot.sh - 隔离网桥上的 PXE 冷启动（iPXE → NVMe/TCP TLS → GRUB → 内核 → initramfs）
#
# 用法:
#   bash test/shared/fwtest-boot.sh --nqn <subnqn> --secret <DHHC-1:..> --psk <hex> \
#       [--serial FILE] [--pcap FILE] [--timeout 600] [--tap tap0fw]
#
# 前置:
#   sudo bash test/shared/fwtest-net.sh setup        （隔离桥 br-fwtest + tap0fw）
#   sudo bash test/shared/fwtest-nvmet-tls.sh setup ...（目标端 TLS 端口）
#   docker 可用（dnsmasq 容器以 host 网络监听 br-fwtest）
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
CACHE=$ROOT/.cache
NQN= SECRET= PSK=
SERIAL=$CACHE/fwtest/boot.serial
PCAP=$CACHE/fwtest/boot.pcap
TIMEOUT=${TIMEOUT:-600}
TAP=${TAP:-tap0fw}
BR=${BR:-br-fwtest}
HOSTIP=${HOSTIP:-192.168.81.1}
TRSVCID=${TRSVCID:-4421}
MAC=${MAC:-52:54:00:81:00:01}
HOSTNQN=${HOSTNQN:-nqn.2014-08.org.ipxe:ipxe}
# 可选 snaplen：设 PCAP_MAXLEN=160 只留首部+握手前缀，抓包体积从数百 MB 降到数 MB
PCAP_MAXLEN=${PCAP_MAXLEN:-}
MAXLEN_OPT=
[ -n "$PCAP_MAXLEN" ] && MAXLEN_OPT=",maxlen=$PCAP_MAXLEN"

while [ $# -gt 0 ]; do
    case "$1" in
    --nqn) NQN=$2; shift 2 ;;
    --secret) SECRET=$2; shift 2 ;;
    --psk) PSK=$2; shift 2 ;;
    --serial) SERIAL=$2; shift 2 ;;
    --pcap) PCAP=$2; shift 2 ;;
    --timeout) TIMEOUT=$2; shift 2 ;;
    --tap) TAP=$2; shift 2 ;;
    *) echo "未知参数: $1" >&2; exit 1 ;;
    esac
done
[ -n "$NQN" ] && [ -n "$SECRET" ] && [ -n "$PSK" ] || {
    echo "用法: $0 --nqn <subnqn> --secret <dhhc> --psk <hex>" >&2; exit 1
}

mkdir -p "$CACHE/fwtest/tftp" "$(dirname "$SERIAL")" "$(dirname "$PCAP")"
cp -f "$ROOT/dist/pxe-uefi/snponly.efi" "$CACHE/fwtest/tftp/snponly.efi"

cat > "$CACHE/fwtest/tftp/boot.ipxe" <<EOF
#!ipxe
set hostnqn ${HOSTNQN}
set root-path nvme://${HOSTIP}:${TRSVCID}/${NQN}?secret=${SECRET}&tls_psk=${PSK}&tls_trsvcid=${TRSVCID}
echo Booting \${root-path}
sanboot \${root-path} || goto failed
:failed
echo SANBOOT FAILED
shell
EOF

cat > "$CACHE/fwtest/dnsmasq.conf" <<EOF
# 不需要 DNS：宿主 53 端口可能被系统解析器占用，验收只做 DHCP+TFTP
port=0
interface=${BR}
bind-interfaces
dhcp-range=192.168.81.50,192.168.81.100,255.255.255.0,12h
dhcp-option=3,${HOSTIP}
dhcp-option=6,${HOSTIP}
enable-tftp
tftp-root=/var/tftp
dhcp-match=set:efi64,option:client-arch,7
dhcp-match=set:efi64,option:client-arch,9
dhcp-boot=tag:efi64,snponly.efi
dhcp-userclass=set:ipxe,iPXE
dhcp-boot=tag:ipxe,boot.ipxe
log-dhcp
EOF

ip -br addr show "$BR" | grep -q "${HOSTIP%/*}" || {
    echo "ERROR: 网桥 $BR ($HOSTIP) 不存在；先运行 sudo bash test/shared/fwtest-net.sh setup" >&2
    exit 1
}
ip link show "$TAP" >/dev/null 2>&1 || {
    echo "ERROR: $TAP 不存在；先运行 sudo bash test/shared/fwtest-net.sh setup" >&2
    exit 1
}

docker rm -f fwtest-dnsmasq >/dev/null 2>&1 || true
docker run -d --name fwtest-dnsmasq --net=host --cap-add NET_ADMIN --cap-add NET_RAW \
    -v "$CACHE/fwtest/dnsmasq.conf:/etc/dnsmasq.conf:ro" \
    -v "$CACHE/fwtest/tftp:/var/tftp:ro" \
    4km3/dnsmasq:latest >/dev/null
sleep 1
docker ps --filter name=fwtest-dnsmasq --format '{{.Names}} {{.Status}}'

VARS=$CACHE/fwtest/OVMF_VARS.fd
[ -f "$VARS" ] || cp /usr/share/OVMF/OVMF_VARS_4M.fd "$VARS"
rm -f "$SERIAL" "$PCAP"
export TMPDIR=$CACHE/fwtest/tmpqemu
mkdir -p "$TMPDIR"

echo "==> PXE 冷启动（串口 $SERIAL，抓包 $PCAP）"
set +e
timeout "$TIMEOUT" qemu-system-x86_64 \
    -machine q35,accel=kvm -cpu host -m 2048 \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
    -drive if=pflash,format=raw,file="$VARS" \
    -netdev tap,id=net0,ifname="$TAP",script=no,downscript=no \
    -device e1000,netdev=net0,mac="$MAC" \
    -object filter-dump,id=f1,netdev=net0,file="$PCAP"${MAXLEN_OPT} \
    -serial file:"$SERIAL" -display none -monitor none -boot n
rc=$?
set -e

echo "==> QEMU 退出码=$rc（124=超时，正常：系统到达登录提示后由 timeout 结束）"
tail -30 "$SERIAL" || true
if grep -qE 'login: ' "$SERIAL"; then
    echo "RESULT: LOGIN_PROMPT_REACHED"
else
    echo "RESULT: NO_LOGIN_PROMPT"
fi
