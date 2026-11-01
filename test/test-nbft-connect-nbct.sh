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
#   E. NBCT entry with tls_trsvcid/tls_psk (kernel-segment TLS handoff):
#      PSK injected into the .nvme keyring, connect moved to the TLS port
#      with --tls and without --dhchap-secret
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

# Shell used to run the consumer.  Override to exercise portability, e.g.
#   SHELL_UNDER_TEST=bash bash test/test-nbft-connect-nbct.sh
SHELL_UNDER_TEST=${SHELL_UNDER_TEST:-dash}

run_connect() { # $1 = sysfs dir
	MOCK_LOG="$MOCK_LOG" NVME="$WORK/mock-nvme" NBFT_SYSFS_PATH="$1" \
		"$SHELL_UNDER_TEST" "$SCRIPT" --connect 2>"$WORK/stderr.log"
}

# --- synthetic NBCT table builder -------------------------------------------
# Entry stride is NBCT_ENTRY_LEN (1152): packed body 1124 + 28 pad.
# Args: $1=tbl $2=traddr $3=trsvcid $4=nqn $5=hostnqn $6=secret \
#       $7=tls_trsvcid $8=tls_psk
build_entry() {
	printf '\000\000\000\000' >> "$1"
	printf '%s' "$2" >> "$1"; head -c $((128 - ${#2})) /dev/zero >> "$1"
	printf '%s' "$3" >> "$1"; head -c $((16 - ${#3})) /dev/zero >> "$1"
	printf '%s' "$4" >> "$1"; head -c $((256 - ${#4})) /dev/zero >> "$1"
	printf '%s' "$5" >> "$1"; head -c $((256 - ${#5})) /dev/zero >> "$1"
	printf '%s' "$6" >> "$1"; head -c $((320 - ${#6})) /dev/zero >> "$1"
	printf '%s' "$7" >> "$1"; head -c $((16 - ${#7})) /dev/zero >> "$1"
	printf '%s' "$8" >> "$1"; head -c $((128 - ${#8})) /dev/zero >> "$1"
	# packed entry body is 1124 bytes; the firmware strides by 1152
	head -c $((1152 - 1124)) /dev/zero >> "$1"
}

# Echo a byte value as its printf octal escape (e.g. 40 -> \050).
oct_byte() { printf "$(printf '\\%03o' "$1")"; }

# Standard 36-byte ACPI header + 4-byte nbct_header for a table of $2 entries.
build_nbct_header() { # $1=tbl $2=count
	local len=$(( 40 + $2 * 1152 ))
	{
		printf 'NBCT'
		oct_byte $((len & 0xff)); oct_byte $(((len >> 8) & 0xff))
		oct_byte $(((len >> 16) & 0xff)); oct_byte $(((len >> 24) & 0xff))
		printf '\001\000'                   # revision 1, checksum 0
		printf 'IPXE00'                     # oem_id
		printf 'NBCTTEST'                   # oem_table_id
		printf '\001\000\000\000'           # oem_revision
		printf 'IPXE'                       # creator_id
		printf '\001\000\000\000'           # creator_revision
		oct_byte "$2"; printf '\000\000\000'  # nbct_header: count + reserved
	} > "$1"
}

build_nbct() { # $1=dir  ->  $1/NBCT with two entries (auth + plain)
	local t="$1/NBCT"
	build_nbct_header "$t" 2
	build_entry "$t" '192.0.2.10' '4420' 'nqn.2026-08.test:disk0' \
		'nqn.2026-08.test:host' '00112233445566778899aabbccddeeff' '' ''
	build_entry "$t" '192.0.2.11' '' 'nqn.2026-08.test:disk1' '' '' '' ''
}

# --- scenario A: NBCT path --------------------------------------------------
mkdir -p "$WORK/a"
build_nbct "$WORK/a"
: > "$MOCK_LOG"
run_connect "$WORK/a" || true   # rc checked via mock log assertions below

check "entry0 connects with host NQN and secret" <<'EOF'
grep -Fq "connect -t tcp -a 192.0.2.10 -s 4420 -n nqn.2026-08.test:disk0 -q nqn.2026-08.test:host --hostid 11111111-2222-3333-4444-555555555555 --dhchap-secret 00112233445566778899aabbccddeeff" "$MOCK_LOG"
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

# --- scenario E: TLS entry (kernel-segment handoff) -------------------------
mkdir -p "$WORK/e"
TLS_PSK_HEX='000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f'
# build_nbct_header truncates/creates the table; build_entry appends to it.
build_nbct_header "$WORK/e/NBCT" 1
build_entry "$WORK/e/NBCT" '192.0.2.20' '4420' 'nqn.2026-08.test:disk0' \
	'nqn.2026-08.test:host' '' '4421' "$TLS_PSK_HEX"

# Fake /proc/keys listing carrying the .nvme keyring (hex serial 1a2b3c4d).
printf '1a2b3c4d I--Q---   1 perm 3f010000  1000 keyring  .nvme: 2\n' \
	> "$WORK/e/keys"
# Fake keyctl records its argv and captures the raw stdin payload.
cat > "$WORK/e/keyctl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$KEYCTL_LOG"
cat > "$KEYCTL_STDIN"
EOF
chmod +x "$WORK/e/keyctl"

: > "$MOCK_LOG"; : > "$WORK/e/keyctl.log"
MOCK_LOG="$MOCK_LOG" NVME="$WORK/mock-nvme" NBFT_SYSFS_PATH="$WORK/e" \
	KEYCTL="$WORK/e/keyctl" KEYS_FILE="$WORK/e/keys" \
	KEYCTL_LOG="$WORK/e/keyctl.log" KEYCTL_STDIN="$WORK/e/stdin.bin" \
	"$SHELL_UNDER_TEST" "$SCRIPT" --connect 2>"$WORK/stderr.log" || true

check "TLS entry connects on the TLS port with --tls and no DH-HMAC-CHAP" <<'EOF'
grep -Fq "connect -t tcp -a 192.0.2.20 -s 4421 -n nqn.2026-08.test:disk0 -q nqn.2026-08.test:host --hostid 11111111-2222-3333-4444-555555555555 --tls" "$MOCK_LOG" \
	&& ! grep -Fq -- "--dhchap-secret" "$MOCK_LOG"
EOF

check "TLS entry injects the PSK under the NVMe0R01 identity into .nvme" <<'EOF'
grep -Fq "padd psk NVMe0R01 nqn.2026-08.test:host nqn.2026-08.test:disk0 0x1a2b3c4d" "$WORK/e/keyctl.log"
EOF

check "injected PSK payload is the raw bytes decoded from the hex field" <<'EOF'
printf '%s' "$TLS_PSK_HEX" | xxd -r -p > "$WORK/e/expected.bin" \
	&& cmp -s "$WORK/e/expected.bin" "$WORK/e/stdin.bin"
EOF

# --- summary ----------------------------------------------------------------
if [ "$fail" -eq 0 ]; then
	echo "test-nbft-connect-nbct: OK"
	exit 0
fi
echo "test-nbft-connect-nbct: FAILED" >&2
exit 1
