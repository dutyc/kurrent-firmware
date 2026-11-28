#!/bin/bash
# test-initramfs-guard.sh - regression tests for golden_verify_initramfs.
#
# The guard has to match module paths, not bare substrings: a listing that only
# carries the tlshd binary must not satisfy the TLS module check, and the nvme
# binary must not satisfy the nvme module check. Synthetic listings and a fake
# kernel version keep the test independent of the running kernel and root.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
. "$ROOT/golden/shared/golden-common.sh"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/initramfs-guard.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

KV=golden-guard-$$
IMG=$TMP/image
: > "$IMG"

tls_line="usr/lib/modules/$KV/kernel/net/tls/tls.ko"
nvme_line="usr/lib/modules/$KV/kernel/drivers/nvme/host/nvme.ko"

base=$TMP/base
cat > "$base" <<EOF
usr/libexec/nbft-connect
usr/sbin/tlshd
usr/bin/keyctl
usr/sbin/nvme
usr/lib/modules/$KV/kernel/drivers/nvme/host/nvme-tcp.ko
usr/lib/modules/$KV/kernel/drivers/net/virtio_net.ko
usr/lib/modules/$KV/kernel/crypto/gcm.ko
usr/lib/modules/$KV/kernel/crypto/ccm.ko
usr/lib/modules/$KV/kernel/crypto/chacha20poly1305.ko
usr/lib/modules/$KV/kernel/arch/x86/crypto/aesni-intel.ko
usr/lib/modules/$KV/kernel/arch/x86/crypto/ghash-clmulni-intel.ko
EOF

check() { # check <name> <listing> <ok|fail>
    local name=$1 list=$2 expect=$3 rc=0
    ( golden_verify_initramfs "$IMG" "$list" "$KV" test ) >/dev/null 2>&1 || rc=$?
    if [ "$expect" = ok ]; then
        [ "$rc" -eq 0 ] || { echo "FAIL: $name (unexpected rc=$rc)"; exit 1; }
    else
        [ "$rc" -ne 0 ] || { echo "FAIL: $name (guard accepted the listing)"; exit 1; }
    fi
    echo "PASS: $name"
}

{ cat "$base"; echo "$nvme_line"; } > "$TMP/no-tls"
{ cat "$base"; echo "$tls_line"; } > "$TMP/no-nvme"
{ cat "$base"; echo "$nvme_line"; echo "$tls_line"; } > "$TMP/full"

check "tlshd does not satisfy the tls module" "$TMP/no-tls" fail
check "the nvme binary does not satisfy the nvme module" "$TMP/no-nvme" fail
check "a complete listing passes" "$TMP/full" ok

# 3. Standard modprobe configuration files mention iwlwifi/nvidia but are not
#    modules: they must not trip the forbidden checks.
{ cat "$TMP/full"; \
  echo "etc/modprobe.d/iwlwifi.conf"; \
  echo "usr/lib/modprobe.d/nvidia-graphics-drivers.conf"; } > "$TMP/full-conf"
check "modprobe configuration files are not forbidden modules" "$TMP/full-conf" ok

# 4. The wireless and GPU module paths themselves must be rejected.
{ cat "$TMP/full"; \
  echo "lib/modules/$KV/kernel/drivers/net/wireless/intel/iwlwifi/iwlwifi.ko"; } > "$TMP/full-wifi"
check "wireless modules are rejected" "$TMP/full-wifi" fail
{ cat "$TMP/full"; \
  echo "lib/modules/$KV/kernel/drivers/gpu/drm/amd/amdgpu/amdgpu.ko"; } > "$TMP/full-gpu"
check "GPU modules are rejected" "$TMP/full-gpu" fail
echo "test-initramfs-guard: OK"
