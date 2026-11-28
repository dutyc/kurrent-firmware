#!/bin/bash
# test-arch-install-exit-path.sh - stub test for the arch-install.sh exit path
# (no real installation)
#
# Usage: bash test/archlinux/test-arch-install-exit-path.sh
#
# Asserts that whatever exit code archinstall or curl returns, the script
# prints ARCH_INSTALL_RC=<rc> and runs sync + poweroff -f (the host serial
# wait converges on that marker; otherwise it can only time out). The success
# path keeps its semantics.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SRC=$ROOT/golden/archlinux/arch-install.sh
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail=0

sed "s|/etc/pacman.d/mirrorlist|$TMP/mirrorlist|" "$SRC" > "$TMP/arch-install.sh"

STUBS='
archinstall() { echo "STUB archinstall $*"; return "${STUB_ARCHINSTALL_RC:-0}"; }
curl() { echo "STUB curl $*"; return "${STUB_CURL_RC:-0}"; }
poweroff() { echo "STUB poweroff $*"; }
sync() { echo "STUB sync"; }
export BASE=http://stub-host MIRROR=http://stub-mirror
'

run_case() { # name expected_rc archinstall_rc curl_rc
    local name=$1 want=$2 arc=$3 crc=$4 out got
    out=$(bash -c "${STUBS}STUB_ARCHINSTALL_RC=$arc STUB_CURL_RC=$crc . '$TMP/arch-install.sh'" 2>&1)
    got=$(sed -n 's/^ARCH_INSTALL_RC=//p' <<<"$out")
    if [ "$got" = "$want" ] && grep -q '^STUB poweroff -f$' <<<"$out" \
        && grep -q '^STUB sync$' <<<"$out"; then
        echo "PASS: $name (ARCH_INSTALL_RC=$got, sync + poweroff)"
    else
        echo "FAIL: $name" >&2
        echo "  expected ARCH_INSTALL_RC=$want, got [${got:-<missing>}]" >&2
        sed 's/^/  | /' <<<"$out" >&2
        fail=1
    fi
}

bash -n "$SRC" || { echo "FAIL: $SRC fails the syntax check" >&2; exit 1; }
echo "== syntax check passed (bash -n)"

run_case "success path" 0 0 0
run_case "archinstall returns 1" 1 1 0
run_case "archinstall returns 23 (no usable disk)" 23 23 0
run_case "config download fails (curl 22)" 22 0 22

echo "== control: the old form (set -e aborts on a non-zero archinstall)"
out=$(bash -c "${STUBS}STUB_ARCHINSTALL_RC=1
set -euo pipefail
archinstall --config /tmp/archinstall.json --silent
rc=\$?
echo \"ARCH_INSTALL_RC=\$rc\"
poweroff -f" 2>&1)
if grep -q '^ARCH_INSTALL_RC=' <<<"$out" || grep -q '^STUB poweroff' <<<"$out"; then
    echo "FAIL: the control form must not emit the marker or power off" >&2
    fail=1
else
    echo "PASS: the control form emits no ARCH_INSTALL_RC and does not power off (the old timeout bug)"
fi

[ "$fail" = 0 ] && echo "test-arch-install-exit-path: OK" || echo "test-arch-install-exit-path: FAILED" >&2
exit "$fail"
