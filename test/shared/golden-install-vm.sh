# shellcheck shell=bash
#golden-install-vm.sh - host-side helpers for the unattended installer runs.
#
# Shared by test/almalinux10/run-almalinux10-install.sh and
# test/opensuse-leap16/run-leap16-install.sh. Only the installer input differs
# (kickstart vs Agama profile, kernel/initrd paths); the VM scaffolding is the
# same and lives here.

install_vm_ssh_key() { # $1 key path, $2 comment/tag
    local key=$1 tag=$2
    [ -f "$key.pub" ] && return 0
    echo "    generating one-time installer SSH key: $key"
    ssh-keygen -q -t ed25519 -N '' -C "$tag" -f "$key"
}

install_vm_extract_iso() { # $1 iso, $2 out dir, then src:dst pairs
    local iso=$1 kdir=$2 pair src dst
    shift 2
    if [ $# -eq 0 ]; then
        echo "ERROR: install_vm_extract_iso needs at least one src:dst pair" >&2
        return 1
    fi
    for pair in "$@"; do
        src=${pair%%:*}
        dst=$kdir/${pair#*:}
        [ -f "$dst" ] && continue
        echo "    extracting $src from $iso"
        xorriso -osirrox on -indev "$iso" -extract "$src" "$dst" >/dev/null
    done
}

install_vm_serve_http() { # $1 cache dir, $2 document root, $3 port
    local cache=$1 docroot=$2 port=$3
    curl -fsS "http://127.0.0.1:$port/" >/dev/null 2>&1 && return 0
    echo "    serving $docroot on :$port"
    ( cd "$docroot" && setsid python3 -m http.server "$port" --bind 0.0.0.0 \
        > "$cache/vm/ks-http.log" 2>&1 < /dev/null & )
    sleep 1
}

install_vm_prepare_target() { # $1 raw disk, $2 OVMF vars
    local raw=$1 vars=$2
    if [ ! -f "$raw" ]; then
        echo "    creating 10G sparse 4K-logical target disk: $raw"
        truncate -s 10G "$raw"
    fi
    [ -f "$vars" ] || cp /usr/share/OVMF/OVMF_VARS_4M.fd "$vars"
}
