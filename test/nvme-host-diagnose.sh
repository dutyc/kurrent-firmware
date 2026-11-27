#!/bin/bash
# Host-side NVMe-oF DH-HMAC-CHAP connect diagnosis.
# Run with: sudo bash test/nvme-host-diagnose.sh
#
# Captures: existing controllers, dyndbg traces (nvme_core/nvme_auth/nvme_tcp/
# nvme_fabrics/nvmet/nvmet_tcp), the exact connect argstr (nvme-cli -v), and the
# kernel log delta around the failed connect.

NQN="nqn.2026-07.com.kurrent:test"
HOSTNQN="nqn.2014-08.org.ipxe:ipxe"
KEY="DHHC-1:01:MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWYOtVl3"

# Self-check the DHHC-1 key before attempting the connect.  Both kernel sides
# (host nvme_auth_generate_key, target nvmet_setup_auth) hardcode a 10-byte
# "DHHC-1:XX:" prefix skip (secret+10); any other prefix length silently
# truncates the payload and fails with "base64 key decoding error -1".
# extract_key() also rejects wrong CRC32 with "key crc mismatch".
python3 - "$KEY" <<'PYEOF'
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
rc=$?
if [ $rc -ne 0 ]; then
	echo "ERROR: DHHC-1 key validation failed (rc=$rc)" >&2
	exit 1
fi

echo "==> [1/6] Existing controllers (EADDRINUSE check)"
ls /sys/class/nvme/ 2>/dev/null || echo "  (none)"
nvme list-subsys 2>/dev/null | grep -E "nvme|NQN" | head -20 || true

echo "==> [2/6] Debugfs / dyndbg"
if [ ! -d /sys/kernel/debug ]; then
	echo "  mounting debugfs"
	mount -t debugfs none /sys/kernel/debug
fi
for m in nvme_core nvme_auth nvme_tcp nvme_fabrics nvmet nvmet_tcp; do
	echo "module $m +p" > /sys/kernel/debug/dynamic_debug/control 2>/dev/null \
		&& echo "  enabled: $m" || echo "  SKIP: $m (not loaded / no debug)"
done

echo "==> [3/6] Flush dmesg"
dmesg -c > /dev/null

echo "==> [4/6] nvme connect (verbose)"
nvme connect -v -t tcp -n "$NQN" -a 127.0.0.1 -s 4420 \
	--hostnqn "$HOSTNQN" --dhchap-secret "$KEY"
echo "rc=$?"

echo "==> [5/6] dmesg delta (last 80 lines)"
dmesg | tail -80

echo "==> [6/6] Controllers after attempt"
ls /sys/class/nvme/ 2>/dev/null || echo "  (none)"
