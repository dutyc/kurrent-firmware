#!/usr/bin/env bash
# Repository gates shared by CI and local runs.
#
# Usage: bash test/ci-gates.sh <layout|syntax|shellcheck|embed|boot|pcap|replay|build>
#
#   layout      test/ holds tests and fixtures only; golden/ holds provisioning
#   syntax      bash -n / sh -n for every tracked shell script
#   `shellcheck`  ShellCheck at error severity on the same set
#   embed       every EMBED_B64_* payload matches its repository source
#   boot        initramfs TLS wiring: config path shipped, kTLS ciphers added
#   pcap        pcap flow aggregation tests (synthetic captures, no real pcap)
#   replay      apply patches 0001.. in order to the pinned upstream commit
#               and compare reference/ byte for byte
#   build       full build/build.sh and verify dist/SHA256SUMS
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

list_scripts() {
    local f
    while IFS= read -r -d '' f; do
        head -1 "$f" 2>/dev/null | grep -qE '^#!.*(bash|/sh)' && printf '%s\n' "$f"
    done < <(git ls-files -z)
}

gate_layout() {
    local rc=0 bad n
    bad=$(find test \( \
        -path 'test/*/golden-image-setup-*.sh' \
        -o -path 'test/*/mkinitcpio-nbft*' \
        -o -path 'test/shared/golden-common.sh' \
        -o -path 'test/shared/embed-components.py' \
        -o -path 'test/shared/assets/BOOTX64*' \) -print)
    if [ -n "$bad" ]; then
        echo "ERROR: golden image provisioning assets found under test/:" >&2
        printf '%s\n' "$bad" >&2
        rc=1
    fi
    # test/ is split by purpose; reject stray top-level entries in both levels.
    local entry
    for entry in test/*; do
        [ -e "$entry" ] || continue
        case "${entry#test/}" in
        README.md|ci-gates.sh|archlinux|shared|manual|test-nbft-connect-nbct.sh) ;;
        *)
            echo "ERROR: unexpected test/ entry: $entry" >&2
            rc=1
            ;;
        esac
    done
    for entry in test/manual/*; do
        [ -e "$entry" ] || continue
        case "${entry#test/manual/}" in
        README.md|ak|auth|nbft|nvs|tofu) ;;
        *)
            echo "ERROR: unexpected test/manual/ entry: $entry" >&2
            rc=1
            ;;
        esac
    done
    n=$(find golden -maxdepth 2 -type f -name 'golden-image-setup-*.sh' | wc -l)
    [ "$n" -eq 8 ] || {
        echo "ERROR: expected 8 golden-image-setup scripts under golden/, found $n" >&2
        rc=1
    }
    [ "$rc" = 0 ] && echo "layout: OK ($n golden image scripts)"
    return "$rc"
}

gate_syntax() {
    local f rc=0
    while IFS= read -r f; do
        case "$(head -1 "$f")" in
        *bash*) bash -n "$f" || rc=1 ;;
        *) sh -n "$f" || rc=1 ;;
        esac
    done < <(list_scripts)
    [ "$rc" = 0 ] && echo "syntax: OK ($(list_scripts | wc -l) scripts)"
    return "$rc"
}

gate_shellcheck() {
    command -v shellcheck >/dev/null || {
        echo "ERROR: shellcheck not installed" >&2
        exit 1
    }
    # shellcheck disable=SC2046
    shellcheck --severity=error --shell=bash $(list_scripts)
    echo "shellcheck (error): OK"
}

gate_embed() {
    python3 test/shared/verify-embed.py
}

gate_boot() {
    # Cache the checks that must hold for kernel-segment TLS to work in an
    # initramfs: tlshd has to be told where the hook put its config, and the
    # AEAD modules used by kTLS have to be present (the kernel cannot load
    # them from the root filesystem before root is mounted).
    local rc=0 hook=initramfs-nbft/initramfs/hooks/nbft
    local localtop=initramfs-nbft/initramfs/scripts/local-top/nbft
    grep -q -- 'tlshd -c /etc/tlshd/config' "$localtop" || {
        echo "ERROR: $localtop does not pass the shipped tlshd config" >&2
        rc=1
    }
    grep -q -- 'cp -a /etc/tlshd/config' "$hook" || {
        echo "ERROR: $hook does not ship /etc/tlshd/config" >&2
        rc=1
    }
    local m
    for m in gcm ccm chacha20poly1305 ghash-generic; do
        grep -q -- " ${m} " "$hook" || {
            echo "ERROR: $hook does not add the kTLS cipher $m" >&2
            rc=1
        }
    done
    grep -q -- 'instmods gcm ccm chacha20poly1305 ghash_generic' golden/shared/golden-common.sh || {
        echo "ERROR: dracut hook does not add the kTLS ciphers" >&2
        rc=1
    }
    # Arch runs mkinitcpio hooks instead; the same kernel-stage TLS contract
    # applies there.
    local arch_install=golden/archlinux/mkinitcpio-nbft/install/nbft
    local arch_hook=golden/archlinux/mkinitcpio-nbft/hooks/nbft
    grep -q -- 'add_file /etc/tlshd/config' "$arch_install" || {
        echo "ERROR: $arch_install does not ship /etc/tlshd/config" >&2
        rc=1
    }
    for m in gcm ccm chacha20poly1305 ghash_generic aesni_intel; do
        grep -q -- " $m " "$arch_install" || {
            echo "ERROR: $arch_install does not add the kTLS cipher $m" >&2
            rc=1
        }
    done
    grep -q -- 'tlshd -c /etc/tlshd/config' "$arch_hook" || {
        echo "ERROR: $arch_hook does not pass the shipped tlshd config" >&2
        rc=1
    }
    grep -q -- 'keyctl session -' "$arch_hook" || {
        echo "ERROR: $arch_hook does not run tlshd and the connect step in one session" >&2
        rc=1
    }
    bash test/shared/test-golden-esp.sh || rc=1
    [ "$rc" = 0 ] && echo "boot components: OK"
    return "$rc"
}

gate_pcap() {
    python3 test/shared/test_pcap_flows.py
    echo "pcap flows: OK"
}

gate_replay() {
    local url commit src patch ref rel
    url=$(sed -n 's/^UPSTREAM_URL="\${UPSTREAM_URL:-\(.*\)}"$/\1/p' build/build.sh)
    commit=$(sed -n 's/^UPSTREAM_COMMIT="\${UPSTREAM_COMMIT:-\(.*\)}"$/\1/p' build/build.sh)
    [ -n "$url" ] && [ -n "$commit" ] || {
        echo "ERROR: cannot read UPSTREAM_URL/UPSTREAM_COMMIT from build/build.sh" >&2
        exit 1
    }
    REPLAY_TMP=$(mktemp -d "${TMPDIR:-/tmp}/ipxe-replay.XXXXXX")
    trap 'rm -rf "${REPLAY_TMP:-}"' EXIT
    src=$REPLAY_TMP
    echo "replay: $url @ $commit"
    git clone --filter=blob:none --no-checkout "$url" "$src" >/dev/null
    git -C "$src" fetch --depth 1 "$url" "$commit" >/dev/null
    git -C "$src" checkout --force FETCH_HEAD
    git -C "$src" clean -fdxq
    for patch in "$ROOT"/patches/*.patch; do
        git -C "$src" apply --check "$patch"
        git -C "$src" apply "$patch"
    done
    echo "replay: $(ls "$ROOT"/patches/*.patch | wc -l) patches applied"
    local n=0
    while IFS= read -r -d '' ref; do
        rel=${ref#reference/}
        cmp -s "$ref" "$src/$rel" || {
            echo "ERROR: reference/$rel differs from the replayed tree" >&2
            exit 1
        }
        n=$((n + 1))
    done < <(find reference -type f -print0)
    echo "replay: reference/ matches ($n files)"
}

gate_build() {
    bash build/build.sh
    ( cd dist && sha256sum -c SHA256SUMS )
}

case "${1:-}" in
layout) gate_layout ;;
syntax) gate_syntax ;;
shellcheck) gate_shellcheck ;;
embed) gate_embed ;;
boot) gate_boot ;;
pcap) gate_pcap ;;
replay) gate_replay ;;
build) gate_build ;;
*)
    echo "usage: $0 <layout|syntax|shellcheck|embed|boot|pcap|replay|build>" >&2
    exit 1
    ;;
esac
