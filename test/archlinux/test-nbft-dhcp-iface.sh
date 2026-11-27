#!/bin/bash
# test-nbft-dhcp-iface.sh - stub test for DHCP interface selection in hooks/nbft
# (no VM)
#
# Usage: bash test/archlinux/test-nbft-dhcp-iface.sh [dash|bash]
#
# Method: rewrite the absolute paths in the hook to a temporary directory, mock
# /sys/class/net, ip and dhcpcd, and assert candidate order and per-interface
# attempts: NBFT_IFACE_0 -> carrier=1 -> remaining non-lo interfaces, tried one
# by one until IPv4 is obtained.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
HOOK_SRC=$ROOT/test/archlinux/mkinitcpio-nbft/hooks/nbft
RUN_SHELL=${1:-dash}
fail=0

new_env() {
    local tmp iface
    tmp=$(mktemp -d)
    mkdir -p "$tmp/sys/net" "$tmp/usr/bin" "$tmp/bin" "$tmp/var-lib-dhcpcd"
    : > "$tmp/tty"; : > "$tmp/kmsg"; : > "$tmp/leases"; : > "$tmp/dhcpcd.log"
    for iface in "$@"; do mkdir -p "$tmp/sys/net/$iface"; done
    cat > "$tmp/bin/ip" <<EOF
#!/bin/bash
if [ "\$1" = "-4" ] && [ "\$2" = "addr" ] && [ "\$3" = "show" ]; then
    dev=\${@: -1}
    grep -qx "\$dev" "$tmp/leases" && echo "    inet 10.0.0.2/24 scope global \$dev"
    exit 0
fi
if [ "\$1" = "-4" ] && [ "\$3" = "addr" ]; then
    while read -r l; do echo "\$l UP 10.0.0.2/24"; done < "$tmp/leases"
fi
exit 0
EOF
    cat > "$tmp/usr/bin/dhcpcd" <<EOF
#!/bin/bash
dev=\${@: -1}
echo "\$dev" >> "$tmp/dhcpcd.log"
[ "\$dev" = "\${STUB_LEASE_ON:-}" ] && echo "\$dev" >> "$tmp/leases"
exit 0
EOF
    chmod 755 "$tmp/bin/ip" "$tmp/usr/bin/dhcpcd"
    sed -e "s|/sys/class/net|$tmp/sys/net|g" \
        -e "s|/usr/bin/dhcpcd|$tmp/usr/bin/dhcpcd|g" \
        -e "s|/dev/kmsg|$tmp/kmsg|g" \
        -e "s|/var/lib/dhcpcd|$tmp/var-lib-dhcpcd|g" \
        -e "s|/dev/ttyS0|$tmp/tty|g" \
        "$HOOK_SRC" | sed -E "s|>+ *$tmp/tty|>> $tmp/tty|g" > "$tmp/nbft"
    printf '%s\n' "$tmp"
}

run_case() { # name expected_candidates expected_attempts lease_on NBFT_IFACE_0 iface...
    local name=$1 want_cand=$2 want_try=$3 lease=$4 nbft0=$5 tmp iface n carrier got_cand got_try
    shift 5
    tmp=$(new_env $(printf '%s\n' "$@" | cut -d: -f1))
    for iface in "$@"; do
        n=${iface%%:*}; carrier=${iface#*:}
        [ "$carrier" = "$iface" ] && carrier=
        [ -n "$carrier" ] && echo "$carrier" > "$tmp/sys/net/$n/carrier"
    done
    PATH="$tmp/bin:$PATH" STUB_LEASE_ON="$lease" NBFT_IFACE_0="$nbft0" \
        "$RUN_SHELL" -c "sleep() { :; }; . '$tmp/nbft'; run_dhcp" </dev/null >/dev/null 2>&1
    got_cand=$(sed -n 's/^nbft: DHCP candidates: //p' "$tmp/tty" | sed 's/ *$//')
    got_try=$(tr '\n' ' ' < "$tmp/dhcpcd.log" | sed 's/ *$//')
    if [ "$got_cand" = "$want_cand" ] && [ "$got_try" = "$want_try" ]; then
        echo "PASS: $name (candidates [$got_cand], attempts [$got_try])"
    else
        echo "FAIL: $name" >&2
        echo "  expected candidates [$want_cand], got [$got_cand]" >&2
        echo "  expected attempts [$want_try], got [$got_try]" >&2
        fail=1
    fi
    rm -rf "$tmp"
}

sh -n "$HOOK_SRC" || { echo "FAIL: $HOOK_SRC fails the syntax check" >&2; exit 1; }
echo "== syntax check passed ($RUN_SHELL, sh -n)"

# lo always has carrier=1, confirming it is never a candidate.
run_case "carrier=1 before enumeration order" "eth1 eth0 eth2" "eth1 eth0" eth0 "" lo:1 eth0:0 eth1:1 eth2
run_case "NBFT_IFACE_0 has top priority" "eth2 eth1 eth0" "eth2" eth2 eth2 lo:1 eth0:0 eth1:1 eth2:0
run_case "single NIC keeps the original behaviour" "eth0" "eth0" eth0 "" lo:1 eth0:1
run_case "no carrier data: enumeration order, try each" "eth0 eth1 eth2" "eth0 eth1 eth2" eth2 "" lo:1 eth0:0 eth1:0 eth2:0
run_case "no lease anywhere: do not guess success" "eth0 eth1" "eth0 eth1" "" "" lo:1 eth0:0 eth1:0
run_case "lo only: no DHCP attempt" "" "" eth0 "" lo:1

[ "$fail" = 0 ] && echo "test-nbft-dhcp-iface: OK" || echo "test-nbft-dhcp-iface: FAILED" >&2
exit "$fail"
