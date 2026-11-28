#!/bin/bash
# golden-image-setup-archlinux.sh - one-shot golden image customization
# (Arch Linux rolling -> NVMe-oF SAN boot golden image)
#
# Implements the A-F stages described in docs/en/distributions.md:
#   A. System and kernel   Arch rolling kernel (ISO 2026.11.01 / 7.3.6,
#                          CONFIG_NVME_TCP_TLS built in); ktls-utils has no
#                          Arch package, so tlshd is built from a pinned
#                          upstream tag and tarball SHA256.
#   B. initramfs           mkinitcpio local hook nbft (NBCT credentials +
#                          kernel-segment TLS); DHCP is done inside the
#                          initramfs by dhcpcd (the kernel ip= parameter
#                          cannot wait for the NIC module, and klibc ipconfig
#                          failed on virtio-net). The native nvmf hook is not
#                          used: it connects without credentials.
#   C. System configuration  fstab (root by UUID, /boot/efi commented),
#                            hostname de-identified.
#   D. GRUB boot parameters  (net.ifnames=0 nbft_auto)
#   E. Disk layout           4K-native GPT + 4K FAT32 ESP + GRUB 2.14
#                            (SAN form, interactive confirmation).
#   F. Statelessness check   no identity hard-coded on disk.
#
# Arch-specific notes:
#   - ext4 root: mature on 4K logical-block disks; mkinitcpio and GRUB use the
#     UUID directly;
#   - mkinitcpio keeps no early KMS and the nbft hook ships only a generic
#     wired NIC set, so the initramfs boots on any of those adapters instead
#     of only the installation VM's virtio hardware;
#   - ktls-utils 1.5.0 reads /etc/tlshd/config (the older /etc/tlshd.conf is
#     still accepted);
#   - the native nvmf hook carries neither NBCT credentials nor TLS-PSK, so
#     this script does not enable it.
#
# Usage (inside the golden image, as root):
#   sudo bash golden/archlinux/golden-image-setup-archlinux.sh
#   sudo bash golden/archlinux/golden-image-setup-archlinux.sh --skip-disk --yes
#
# Options:
#   -d DIR        initramfs-nbft component directory (default: ../../initramfs-nbft
#                 next to the script; when the repository tree is unavailable the
#                 embedded copies are extracted so one file can be copied in)
#   --mkinitcpio-dir DIR  mkinitcpio hook directory (default: mkinitcpio-nbft
#                 next to the script)
#   -k VER        kernel version (default: uname -r)
#   --skip-disk   skip the GPT/ESP rebuild in stage E (ESP content and
#                 grub.cfg are still refreshed)
#   --no-serial   do not add console=ttyS0,115200 to grub.cfg
#   --yes         skip the stage E confirmation
#   --grub-efi F  inject a host-built BOOTX64.EFI (skips the embedded GRUB 2.14)
#   --mirror URL  pacman mirror (default: https://mirrors.tuna.tsinghua.edu.cn/archlinux)
#   --keep-sources  keep the image's pacman sources (do not switch mirrors)
#   --ktls-utils-url URL    ktls-utils source tarball (default: GitHub release)
#   --ktls-utils-sha256 HEX tarball SHA256 (default: the pinned 1.5.0 value)
#   -h, --help    show this help
# ==== END USAGE ====
#
# Idempotent: rerunning is safe (finished steps are skipped; stage E refreshes
# the ESP content). Note: stage E converts the disk to 4K semantics, after
# which 512-byte environments can no longer read it; only SAN (nvmet 4K
# blocks) or 4Kn boot paths remain, which is the intended golden-image form.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
COMPONENT_DIR=
MKINITCPIO_DIR=
KVER=$(uname -r)
CONSOLE=console=ttyS0,115200
GRUB_ARGS="net.ifnames=0 biosdevname=0 nbft_auto"
MENU_LABEL="Arch Linux"
DO_DISK=1
YES=0
GRUB_EFI=
MIRROR="https://mirrors.tuna.tsinghua.edu.cn/archlinux"
KEEP_SOURCES=0
KTLS_UTILS_TAG="ktls-utils-1.5.0"
KTLS_UTILS_COMMIT="d0b4de1ba000fe6baf739e85f17bca33b821a16f"
KTLS_UTILS_SHA256="2a40edd383dc5910c375c36606ed941d013dbf4eaf7b9421b7b5bb09dc194ec4"
KTLS_UTILS_URL="https://codeload.github.com/oracle/ktls-utils/tar.gz/refs/tags/${KTLS_UTILS_TAG}"

INITRD_SRC_TEMPLATE="/boot/initramfs-linux.img"
INITRD_ESP_NAME_TEMPLATE="initramfs-linux.img"
VMLINUZ_SRC_TEMPLATE="/boot/vmlinuz-linux"
VMLINUZ_ESP_NAME_TEMPLATE="vmlinuz-linux"
IDENTITY_DIRS=(/etc/mkinitcpio.conf /etc/pacman.d/mirrorlist /etc/tlshd)
GRUB_CFG=/boot/grub/grub.cfg
GRUB_MKIMAGE=grub-mkimage
GRUB_MKCONFIG=grub-mkconfig
MKFS_FAT_OPTS="-S 4096"
PHASE_C_NETWORKD=0
PHASE_E_LVM_FALLBACK=0
PHASE_E_LVM_PARAM=0

# ==== EMBEDDED initramfs-nbft components ====
# 由 golden/shared/embed-components.py 从 initramfs-nbft/ 与
# golden/archlinux/mkinitcpio-nbft/ 生成(勿手改); 仓库组件目录不可用时
# 释放到临时目录使用,使本脚本可单文件分发到母盘运行。
EMBED_B64_CONNECT=''
EMBED_B64_MKINITCPIO_INSTALL=''
EMBED_B64_MKINITCPIO_HOOK=''
EMBED_B64_BOOTX64=''
# ==== END EMBEDDED ====

# ==== EMBEDDED golden-common.sh ====
EMBED_B64_COMMON=''
# ==== END EMBEDDED golden-common ====

GOLDEN_COMMON="$SCRIPT_DIR/../shared/golden-common.sh"
if [ -f "$GOLDEN_COMMON" ]; then
    . "$GOLDEN_COMMON"
else
    echo "    repository shared library unavailable, extracting the embedded copy..."
    GOLDEN_COMMON_DIR=$(mktemp -d /tmp/golden-common.XXXXXX)
    printf '%s' "$EMBED_B64_COMMON" | base64 -d > "$GOLDEN_COMMON_DIR/golden-common.sh"
    . "$GOLDEN_COMMON_DIR/golden-common.sh"
    GOLDEN_TMP_DIRS+=("$GOLDEN_COMMON_DIR")
fi

arch_release_embedded_components() {
    [ -n "$EMBED_B64_CONNECT" ] || {
        echo "ERROR: no embedded components (run bash golden/shared/embed-components.py)" >&2
        return 1
    }
    [ -n "$EMBED_B64_MKINITCPIO_INSTALL" ] && [ -n "$EMBED_B64_MKINITCPIO_HOOK" ] || {
        echo "ERROR: no embedded mkinitcpio hooks (run bash golden/shared/embed-components.py)" >&2
        return 1
    }
    local d
    d=$(mktemp -d /tmp/nbft-components.XXXXXX)
    echo "$EMBED_B64_CONNECT" | base64 -d > "$d/nbft-connect"
    mkdir -p "$d/mkinitcpio/install" "$d/mkinitcpio/hooks"
    echo "$EMBED_B64_MKINITCPIO_INSTALL" | base64 -d > "$d/mkinitcpio/install/nbft"
    echo "$EMBED_B64_MKINITCPIO_HOOK" | base64 -d > "$d/mkinitcpio/hooks/nbft"
    chmod 0755 "$d/nbft-connect" "$d/mkinitcpio/install/nbft" "$d/mkinitcpio/hooks/nbft"
    printf '%s\n' "$d"
}

# Options private to this script are consumed here; everything else (shared
# flags such as -d/--yes/--mirror) is passed through to golden_init.
GOLDEN_ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
    --mkinitcpio-dir) MKINITCPIO_DIR=$2; shift 2 ;;
    --ktls-utils-url) KTLS_UTILS_URL=$2; shift 2 ;;
    --ktls-utils-sha256) KTLS_UTILS_SHA256=$2; shift 2 ;;
    *) GOLDEN_ARGS+=("$1"); shift ;;
    esac
done

# Resolve the component trees before golden_init so its own resolution (which
# only knows the initramfs-nbft layout) does not extract the wrong set.
if [ -z "${COMPONENT_DIR:-}" ]; then
    if [ -f "$SCRIPT_DIR/../../initramfs-nbft/nbft-connect" ]; then
        COMPONENT_DIR=$(cd "$SCRIPT_DIR/../../initramfs-nbft" && pwd)
    fi
fi
if [ -z "${MKINITCPIO_DIR:-}" ]; then
    if [ -f "$SCRIPT_DIR/mkinitcpio-nbft/install/nbft" ] \
       && [ -f "$SCRIPT_DIR/mkinitcpio-nbft/hooks/nbft" ]; then
        MKINITCPIO_DIR=$SCRIPT_DIR/mkinitcpio-nbft
    fi
fi
if [ -z "${COMPONENT_DIR:-}" ] || [ -z "${MKINITCPIO_DIR:-}" ]; then
    echo "    repository component tree unavailable, extracting the embedded copies..."
    EMBED_ROOT=$(arch_release_embedded_components) || exit 1
    COMPONENT_DIR=$EMBED_ROOT
    MKINITCPIO_DIR=$EMBED_ROOT/mkinitcpio
    GOLDEN_TMP_DIRS+=("$EMBED_ROOT")
fi

golden_init "${GOLDEN_ARGS[@]}"

# ---------------------------------------------------------------- A ----------
phase_a() {
    log "[A] system and kernel (Arch rolling, kernel $KVER)"
    apply_sources
    pacman -S --needed --noconfirm nvme-cli jq keyutils grub efibootmgr \
        dosfstools e2fsprogs iproute2 dhcpcd python3
    # nvme-cli/archinstall may seed an instance host NQN and host id on first
    # use; the host NQN must come from the NBCT table on every boot, so the
    # golden image must not carry them.
    rm -f /etc/nvme/hostnqn /etc/nvme/hostid /etc/nvme/discovery.conf
    install_tlshd
    verify_kernel_tls
    # Kernel-segment TLS tooling: fail loudly instead of silently dropping to
    # plaintext.
    [ -x /usr/sbin/tlshd ] || { echo "ERROR: ktls-utils/tlshd missing; kernel-stage TLS unavailable"; exit 1; }
    [ -x /usr/bin/keyctl ] || { echo "ERROR: keyutils/keyctl missing; TLS-PSK injection unavailable"; exit 1; }
}

apply_sources() {
    if [ "$KEEP_SOURCES" = 1 ]; then
        echo "    keeping the image's pacman sources (--keep-sources)"
        return
    fi
    echo "    switching pacman sources -> $MIRROR"
    printf 'Server = %s/$repo/os/$arch\n' "$MIRROR" > /etc/pacman.d/mirrorlist
    pacman -Syy --noconfirm >/dev/null
    echo "    pacman database refreshed"
}

install_tlshd() {
    if pacman -Si ktls-utils >/dev/null 2>&1; then
        pacman -S --needed --noconfirm ktls-utils
        echo "    ktls-utils installed from the Arch repositories"
        return
    fi
    build_ktls_utils
}

build_ktls_utils() {
    # tlshd has no version option; a marker written at install time keeps
    # reruns idempotent.
    local state=/usr/lib/ktls-utils.golden-version
    if [ -x /usr/sbin/tlshd ] && [ "$(cat "$state" 2>/dev/null)" = "$KTLS_UTILS_TAG" ]; then
        echo "    tlshd is already ${KTLS_UTILS_TAG}, skipping the build"
        return
    fi
    echo "    building ktls-utils ${KTLS_UTILS_TAG} (no Arch package; pinned commit ${KTLS_UTILS_COMMIT})"
    pacman -S --needed --noconfirm base-devel autoconf automake libtool pkgconf \
        gnutls libnl glib2 libyaml keyutils
    local work=/var/tmp/ktls-utils-build src
    rm -rf "$work"
    mkdir -p "$work"
    curl -fL --retry 3 --connect-timeout 20 -o "$work/ktls-utils.tar.gz" "$KTLS_UTILS_URL" || {
        echo "ERROR: cannot download the ktls-utils source: $KTLS_UTILS_URL" >&2
        echo "       use --ktls-utils-url <reachable mirror URL> instead" >&2
        exit 1
    }
    echo "$KTLS_UTILS_SHA256  $work/ktls-utils.tar.gz" | sha256sum -c - >/dev/null || {
        echo "ERROR: ktls-utils tarball SHA256 mismatch" >&2; exit 1
    }
    tar -xzf "$work/ktls-utils.tar.gz" -C "$work"
    src=$(find "$work" -mindepth 1 -maxdepth 1 -type d -name 'ktls-utils-*' | head -n 1)
    [ -n "$src" ] || { echo "ERROR: ktls-utils source directory not found"; exit 1; }
    (
        cd "$src"
        ./autogen.sh
        ./configure --prefix=/usr --sysconfdir=/etc --with-systemd
        make -j"$(nproc)"
        make install
    )
    [ -x /usr/sbin/tlshd ] || { echo "ERROR: ktls-utils installed without /usr/sbin/tlshd"; exit 1; }
    # A wrong prefix can leave /usr/etc/tlshd behind; the canonical path is /etc/tlshd.
    rm -rf /usr/etc/tlshd
    echo "$KTLS_UTILS_TAG" > "$state"
    echo "    ktls-utils ${KTLS_UTILS_TAG} installed"
}

verify_kernel_tls() {
    local conf= c sym deps
    for c in "/boot/config-$KVER" "/usr/lib/modules/$KVER/config"; do
        [ -f "$c" ] && conf=$c && break
    done
    if [ -z "$conf" ] && [ -r /proc/config.gz ]; then
        conf=/proc/config.gz
    fi
    if [ -n "$conf" ]; then
        for sym in CONFIG_NVME_TCP_TLS CONFIG_NVME_AUTH CONFIG_NVME_KEYRING CONFIG_TLS CONFIG_NET_HANDSHAKE CONFIG_KEYS; do
            if [ "$conf" = /proc/config.gz ]; then
                # grep -q would exit early and zcat would take SIGPIPE under
                # pipefail; consume the whole stream instead.
                zcat "$conf" | grep -E "^${sym}=[ym]$" >/dev/null || {
                    echo "ERROR: $conf lacks $sym (kernel-stage NVMe/TCP TLS unavailable)"; exit 1
                }
            else
                grep -qE "^${sym}=[ym]$" "$conf" || {
                    echo "ERROR: $conf lacks $sym (kernel-stage NVMe/TCP TLS unavailable)"; exit 1
                }
            fi
        done
        echo "    kernel TLS capability OK ($conf): CONFIG_NVME_TCP_TLS / CONFIG_NVME_AUTH / CONFIG_NVME_KEYRING / CONFIG_TLS"
        return
    fi
    # The Arch kernel package ships no config; verify TLS capability through
    # the module graph: nvme_tcp only depends on nvme-keyring when
    # CONFIG_NVME_TCP_TLS is enabled.
    deps=$(modinfo -F depends nvme_tcp 2>/dev/null) || {
        echo "ERROR: nvme_tcp module not found"; exit 1
    }
    echo "$deps" | tr ',' '\n' | grep -qx 'nvme-keyring' || {
        echo "ERROR: nvme_tcp does not depend on nvme-keyring (CONFIG_NVME_TCP_TLS disabled?)"; exit 1
    }
    for sym in nvme_auth nvme_keyring tls; do
        modinfo -F name "$sym" >/dev/null 2>&1 || {
            echo "ERROR: kernel module $sym missing (kernel-stage TLS unavailable)"; exit 1
        }
    done
    echo "    kernel TLS capability OK (no kernel config): nvme_tcp depends=$deps; nvme_auth/nvme_keyring/tls modules present"
}

# ---------------------------------------------------------------- B ----------
phase_b() {
    log "[B] initramfs seed module (mkinitcpio nbft: NBCT credentials + kernel TLS + DHCP)"
    [ -f "$COMPONENT_DIR/nbft-connect" ] || {
        echo "ERROR: missing component $COMPONENT_DIR/nbft-connect (see -d)"; exit 1
    }
    [ -f "$MKINITCPIO_DIR/install/nbft" ] && [ -f "$MKINITCPIO_DIR/hooks/nbft" ] || {
        echo "ERROR: missing mkinitcpio hook (see --mkinitcpio-dir)"; exit 1
    }
    grep -q -- '--hostid' "$COMPONENT_DIR/nbft-connect" || {
        echo "ERROR: nbft-connect lacks the hostid fix; update the component"; exit 1
    }
    install -Dm0755 "$COMPONENT_DIR/nbft-connect" /usr/local/sbin/nbft-connect
    install -Dm0644 "$MKINITCPIO_DIR/install/nbft" /etc/initcpio/install/nbft
    install -Dm0644 "$MKINITCPIO_DIR/hooks/nbft" /etc/initcpio/hooks/nbft
    golden_install_tlshd_config

    configure_mkinitcpio
    mkinitcpio -P
    verify_initramfs
}

configure_mkinitcpio() {
    python3 - <<'PYEOF'
import re, shutil, time
path = '/etc/mkinitcpio.conf'
text = open(path).read()
m = re.search(r'^HOOKS=\(([^)]*)\)\s*$', text, re.M)
if not m:
    raise SystemExit('ERROR: no HOOKS= line in /etc/mkinitcpio.conf')
old = m.group(1).split()
removed = ('autodetect', 'net', 'kms', 'nbft', 'keyboard', 'keymap',
           'consolefont', 'block')
hooks = [h for h in old if h not in removed]
if 'filesystems' in hooks:
    hooks.insert(hooks.index('filesystems'), 'nbft')
else:
    hooks.append('nbft')
new_line = 'HOOKS=(' + ' '.join(hooks) + ')'
if new_line == m.group(0).strip() and not any(h in old for h in removed):
    print('    HOOKS already compliant')
    raise SystemExit(0)
shutil.copy(path, f"{path}.golden-{time.strftime('%Y%m%d%H%M%S')}.bak")
text = text[:m.start()] + new_line + text[m.end():]
open(path, 'w').write(text)
print('    HOOKS:', ' '.join(hooks), '(wired NICs only, no early KMS)')
PYEOF
}

verify_initramfs() {
    local img=/boot/initramfs-linux.img n size listing
    [ -f "$img" ] || { echo "ERROR: $img missing"; exit 1; }
    listing=$(lsinitcpio "$img" 2>/dev/null) || {
        echo "ERROR: lsinitcpio failed for $img"; exit 1
    }
    # Module files use hyphens (nvme-tcp.ko), modprobe names underscores; accept
    # either. Built-in modules appear in modules.builtin instead of the image.
    for pat in nbft-connect tlshd keyctl dhcpcd virtio_net 'nvme[-_]tcp' 'nvme[-_]auth' \
        'nvme[-_]keyring' 'net/tls/tls' hooks/nbft libnss_files gcm \
        chacha20poly1305 'aesni[-_]intel'; do
        n=$(printf '%s\n' "$listing" | grep -Ec "$pat" || true)
        if [ "$n" -eq 0 ] && grep -qE "$pat" "/usr/lib/modules/$KVER/modules.builtin" 2>/dev/null; then
            echo "    $pat built into the kernel"
            continue
        fi
        [ "$n" -gt 0 ] || { echo "ERROR: $pat not found in $img"; exit 1; }
        echo "    $img contains $pat ($n entries)"
    done
    # The early cpio is uncompressed and crosses the network byte by byte, so
    # GPU and wireless/USB/WAN drivers must stay out.
    for pat in nvidia amdgpu iwlwifi ath10k ath11k rtw89 brcmfmac \
        '/drivers/net/wireless/' '/drivers/net/usb/' '/drivers/net/wan/'; do
        n=$(printf '%s\n' "$listing" | grep -Ec "$pat" || true)
        [ "$n" -eq 0 ] || { echo "ERROR: $img contains $pat ($n entries)"; exit 1; }
    done
    size=$(stat -c %s "$img")
    echo "    initramfs size $((size / 1024 / 1024)) MiB ($size bytes)"
    [ "$size" -le $((120 * 1024 * 1024)) ] || {
        echo "ERROR: $img is $size bytes, above the 120 MiB limit"; exit 1
    }
}

main() {
    log "Arch Linux golden image customization starts (kernel $KVER)"
    phase_a
    phase_b
    phase_c
    phase_d
    phase_e
    phase_f "${IDENTITY_DIRS[@]}"
    log "done."
}

main
