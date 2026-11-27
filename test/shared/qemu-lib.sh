# shellcheck shell=bash
# qemu-lib.sh - shared QEMU/OVMF scaffolding for the test/run-qemu-*.sh rounds.
#
# Sourced after the caller has set ROOT. Each round keeps its own firmware,
# ESP, variable store, devices and serial backend; this library only owns the
# setup that must be identical everywhere:
#   - OVMF code/template paths and the variable-store copy
#   - the FAT ESP hand-off directory check
#   - the private TMPDIR
#   - the common QEMU argument groups
#
# Callers build their command line as:
#   qemu_prepare "$ESP" "$VARS"
#   qemu_std_args "$VARS" 1024
#   qemu_fat_args "$ESP"
#   qemu_net_args 52:54:00:12:34:56
#   exec timeout 120 qemu-system-x86_64 "${QEMU_STD[@]}" "${QEMU_FAT[@]}" "${QEMU_NET[@]}" ...

DIAG=${DIAG:-$ROOT/diag}
OVMF_CODE=${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}
OVMF_VARS_TEMPLATE=${OVMF_VARS_TEMPLATE:-/usr/share/OVMF/OVMF_VARS_4M.fd}

qemu_require() {
    command -v qemu-system-x86_64 >/dev/null || {
        echo "ERROR: qemu-system-x86_64 not found" >&2
        exit 1
    }
    [ -f "$OVMF_CODE" ] || { echo "ERROR: $OVMF_CODE missing" >&2; exit 1; }
    mkdir -p "$DIAG"
    export TMPDIR="$DIAG/tmpqemu"
    mkdir -p "$TMPDIR"
}

qemu_check_firmware() { # $1 ESP directory carrying EFI/BOOT/BOOTX64.EFI
    [ -e "$1/EFI/BOOT/BOOTX64.EFI" ] || {
        echo "ERROR: $1/EFI/BOOT/BOOTX64.EFI missing (see the script header)" >&2
        exit 1
    }
}

qemu_ensure_vars() { # $1 variable store, optional $2 template
    local vars=$1 template=${2:-$OVMF_VARS_TEMPLATE}
    [ -e "$vars" ] || cp "$template" "$vars"
}

qemu_reset_vars() { # $1 variable store, optional $2 template
    local vars=$1 template=${2:-$OVMF_VARS_TEMPLATE}
    rm -f "$vars"
    cp "$template" "$vars"
}

qemu_prepare() { # $1 ESP directory, $2 variable store, optional $3 template
    local esp=$1 vars=$2 template=${3:-$OVMF_VARS_TEMPLATE}
    qemu_require
    mkdir -p "$esp"
    qemu_check_firmware "$esp"
    qemu_ensure_vars "$vars" "$template"
}

qemu_std_args() { # $1 variable store, $2 memory MiB
    QEMU_STD=(
        -machine q35,accel=kvm -cpu host -m "$2"
        -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE"
        -drive if=pflash,format=raw,file="$1"
    )
}

qemu_fat_args() { # $1 FAT directory
    QEMU_FAT=(-drive "file=fat:rw:$1,format=raw,media=disk,cache=unsafe")
}

qemu_net_args() { # $1 MAC, optional $2 pcap path
    QEMU_NET=(
        -netdev user,id=net0
        -device "e1000,netdev=net0,mac=$1"
    )
    if [ -n "${2:-}" ]; then
        QEMU_NET+=(-object "filter-dump,id=f1,netdev=net0,file=$2")
    fi
}
