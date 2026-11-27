#!/bin/bash
# test-golden-esp.sh - regression test for the ESP volid check in
# test/shared/golden-common.sh
#
# Usage: bash test/shared/test-golden-esp.sh
#
# esp_is_4k_volid must accept a 4K FAT32 boot sector whose volume id sits at
# the FAT32 BPB offset 0x43, and must reject the same id at 0x27 (the FAT12/16
# offset). Writing at 0x27 corrupts the FAT32 sectors field and EDK2 refuses
# to mount the ESP.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail=0

# shellcheck source=test/shared/golden-common.sh
. "$ROOT/test/shared/golden-common.sh"

python3 - "$TMP" <<'PYEOF'
import struct, sys
d = sys.argv[1]
for name, offset in (("good", 0x43), ("legacy", 0x27), ("bad-size", 0x43)):
    b = bytearray(512)
    struct.pack_into("<H", b, 11, 4096)
    if name == "bad-size":
        struct.pack_into("<H", b, 11, 512)
    struct.pack_into("<I", b, offset, 0x855B91DF)
    open(f"{d}/{name}", "wb").write(b)
PYEOF

if esp_is_4k_volid "$TMP/good"; then
    echo "PASS: FAT32 volid at 0x43 is accepted"
else
    echo "FAIL: FAT32 volid at 0x43 is rejected" >&2
    fail=1
fi
if esp_is_4k_volid "$TMP/legacy"; then
    echo "FAIL: volid at 0x27 (FAT12/16 offset) must not pass the FAT32 check" >&2
    fail=1
else
    echo "PASS: volid at 0x27 is rejected"
fi
if esp_is_4k_volid "$TMP/bad-size"; then
    echo "FAIL: a 512-byte-sector ESP must not pass the 4K check" >&2
    fail=1
else
    echo "PASS: 512-byte sectors are rejected"
fi

[ "$fail" = 0 ] && echo "test-golden-esp: OK" || echo "test-golden-esp: FAILED" >&2
exit "$fail"
