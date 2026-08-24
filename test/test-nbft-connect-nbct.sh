#!/usr/bin/env bash
# Unit test for nbft-connect --connect: the NBCT credentials path and the
# NBFT fallback, driven by a mock nvme binary that records its argv.
#
# Usage: bash test/test-nbft-connect-nbct.sh
#
# Scenarios:
#   A. NBCT table present: one connect per entry, authenticated entries
#      carrying -q/--dhchap-secret, unauthenticated ones without them
#   B. No NBCT, NBFT present: falls back to `nvme connect-all --nbft`
#   C. Neither table: no-op, exit 0
#   D. NBCT entry missing traddr/nqn: warned, skipped, later entries still
#      attempted, overall exit code non-zero
set -e

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/initramfs-nbft/nbft-connect
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fail=0
check() { # $1 = description, stdin = assertion (must be true)
	local desc=$1
	if eval "$(cat)"; then
		echo "PASS: $desc"
	else
		echo "FAIL: $desc" >&2
		fail=1
	fi
}

# --- mock nvme --------------------------------------------------------------
MOCK_LOG=$WORK/mock.log
cat > "$WORK/mock-nvme" <<'EOF'
#!/bin/sh
echo "$*" >> "$MOCK_LOG"
# A modern nvme-cli advertises --nbft in connect-all help; the version
# gate in nbft-connect keys on that.
if [ "$1" = "connect-all" ] && [ "$2" = "--help" ]; then
	echo "  --nbft                use the ACPI NBFT table"
fi
exit 0
EOF
chmod +x "$WORK/mock-nvme"

run_connect() { # $1 = sysfs dir
	MOCK_LOG="$MOCK_LOG" NVME="$WORK/mock-nvme" NBFT_SYSFS_PATH="$1" \
		dash "$SCRIPT" --connect 2>"$WORK/stderr.log"
}

# --- synthetic NBCT table builder -------------------------------------------
build_entry() { # $1=tbl $2=traddr $3=trsvcid $4=nqn $5=hostnqn $6=secret
	printf '\000\000\000\000' >> "$1"
	printf '%s' "$2" >> "$1"; head -c $((128 - ${#2})) /dev/zero >> "$1"
	printf '%s' "$3" >> "$1"; head -c $((16 - ${#3})) /dev/zero >> "$1"
	printf '%s' "$4" >> "$1"; head -c $((256 - ${#4})) /dev/zero >> "$1"
	printf '%s' "$5" >> "$1"; head -c $((256 - ${#5})) /dev/zero >> "$1"
	printf '%s' "$6" >> "$1"; head -c $((320 - ${#6})) /dev/zero >> "$1"
	# packed entry body is 980 bytes; the firmware strides by 1024
	head -c $((1024 - 980)) /dev/zero >> "$1"
}

build_nbct() { # $1=dir  ->  $1/NBCT with two entries (auth + plain)
	local t="$1/NBCT"
	{
		printf 'NBCT'
		printf '\050\010\000\000'           # length 2088 (le32)
		printf '\001\000'                   # revision 1, checksum 0
		printf 'IPXE00'                     # oem_id
		printf 'NBCTTEST'                   # oem_table_id
		printf '\001\000\000\000'           # oem_revision
		printf 'IPXE'                       # creator_id
		printf '\001\000\000\000'           # creator_revision
		printf '\002\000\000\000'           # nbct_header: count=2
	} > "$t"
	build_entry "$t" '192.0.2.10' '4420' 'nqn.2026-08.test:disk0' \
		'nqn.2026-08.test:host' '00112233445566778899aabbccddeeff'
	build_entry "$t" '192.0.2.11' '' 'nqn.2026-08.test:disk1' '' ''
}

# --- scenario A: NBCT path --------------------------------------------------
mkdir -p "$WORK/a"
build_nbct "$WORK/a"
: > "$MOCK_LOG"
run_connect "$WORK/a" || true   # rc checked via mock log assertions below

check "entry0 connects with host NQN and secret" <<'EOF'
grep -Fq "connect -t tcp -a 192.0.2.10 -s 4420 -n nqn.2026-08.test:disk0 -q nqn.2026-08.test:host --dhchap-secret 00112233445566778899aabbccddeeff" "$MOCK_LOG"
EOF

check "entry1 (unauthenticated) connects without secret options" <<'EOF'
grep -Fq "connect -t tcp -a 192.0.2.11 -s 4420 -n nqn.2026-08.test:disk1" "$MOCK_LOG" && ! grep -Fq -- "--dhchap-secret" <(grep "disk1" "$MOCK_LOG")
EOF

check "no connect-all --nbft fallback when NBCT present" <<'EOF'
! grep -Fq "connect-all" "$MOCK_LOG"
EOF

# --- scenario B: NBFT fallback ----------------------------------------------
mkdir -p "$WORK/b"
: > "$WORK/b/NBFT"
: > "$MOCK_LOG"
run_connect "$WORK/b" || true

check "falls back to connect-all --nbft without NBCT" <<'EOF'
grep -Fq "connect-all --nbft" "$MOCK_LOG"
EOF

# --- scenario C: no tables --------------------------------------------------
mkdir -p "$WORK/c"
: > "$MOCK_LOG"
rc=0
run_connect "$WORK/c" || rc=$?

check "no tables: exit 0 and no nvme invocation" <<'EOF'
[ "$rc" -eq 0 ] && [ ! -s "$MOCK_LOG" ]
EOF

# --- scenario D: incomplete entry skipped -----------------------------------
mkdir -p "$WORK/d"
build_nbct "$WORK/d"
# Corrupt entry0's traddr (all-NUL) to make it incomplete.
dd if=/dev/zero of="$WORK/d/NBCT" bs=1 seek=44 count=128 conv=notrunc \
	2>/dev/null
: > "$MOCK_LOG"
rc=0
run_connect "$WORK/d" || rc=$?

check "incomplete entry skipped, later entry still connected" <<'EOF'
grep -Fq "connect -t tcp -a 192.0.2.11" "$MOCK_LOG" && ! grep -Fq "192.0.2.10" "$MOCK_LOG"
EOF

check "incomplete entry yields non-zero exit" <<'EOF'
[ "$rc" -ne 0 ]
EOF

check "incomplete entry is warned about" <<'EOF'
grep -Fq "NBCT entry 0 incomplete" "$WORK/stderr.log"
EOF

# --- summary ----------------------------------------------------------------
if [ "$fail" -eq 0 ]; then
	echo "test-nbft-connect-nbct: OK"
	exit 0
fi
echo "test-nbft-connect-nbct: FAILED" >&2
exit 1
