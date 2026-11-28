#!/bin/bash
# build-grub-efi.sh - obtain the pinned GRUB 2.14 BOOTX64 image for the golden
# image setup scripts.
#
# Modes:
#   (default)       download the released asset and verify its SHA-256
#   --from-file F   use a local image after verifying the pinned SHA-256
#   --rebuild       extract the pinned grub-efi-amd64-bin deb and rebuild with
#                   the host grub-mkimage
#
# The result is written to dist/grub/BOOTX64-2.14-generic.EFI. All inputs,
# versions and the module list live in grub-efi.lock. Downloads honour
# HTTPS_PROXY. No root and no container are required.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
# shellcheck source=grub-efi.lock
. "$HERE/grub-efi.lock"

OUT="$REPO/dist/grub/$GRUB_EFI_NAME"
RELEASE_URL="https://github.com/dutyc/kurrent-firmware/releases/download/$GRUB_RELEASE_TAG/$GRUB_RELEASE_ASSET"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/grub-efi.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

usage() {
    sed -n '2,/^set -euo pipefail/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d'
    exit "${1:-0}"
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

proxy_args() {
    PROXY=()
    if [ -n "${HTTPS_PROXY:-}" ]; then
        PROXY=(--proxy "$HTTPS_PROXY")
    fi
}

fetch() {
    local url=$1 dest=$2
    proxy_args
    echo "downloading $url"
    curl -fL --retry 3 --retry-delay 2 "${PROXY[@]+"${PROXY[@]}"}" -o "$dest" "$url" ||
        die "download failed: $url"
}

verify_efi() {
    local file=$1 size sha
    [ -f "$file" ] || die "image not found: $file"
    size=$(wc -c <"$file")
    [ "$size" -eq "$GRUB_EFI_SIZE" ] ||
        die "$file is $size bytes, expected $GRUB_EFI_SIZE"
    sha=$(sha256sum "$file" | awk '{print $1}')
    [ "$sha" = "$GRUB_EFI_SHA256" ] ||
        die "$file sha256 $sha, expected $GRUB_EFI_SHA256"
}

verify_deb() {
    local file=$1 sha
    [ -f "$file" ] || die "package not found: $file"
    sha=$(sha256sum "$file" | awk '{print $1}')
    [ "$sha" = "$GRUB_DEB_SHA256" ] ||
        die "$file sha256 $sha, expected $GRUB_DEB_SHA256"
}

install_image() {
    local file=$1
    mkdir -p "$(dirname "$OUT")"
    install -m 0644 "$file" "$OUT"
    echo "GRUB EFI: $OUT"
    echo "sha256: $GRUB_EFI_SHA256"
}

mode=release
from_file=
while [ $# -gt 0 ]; do
    case "$1" in
    --from-file)
        [ $# -ge 2 ] || die "--from-file needs a path"
        mode=file
        from_file=$2
        shift 2
        ;;
    --rebuild)
        mode=rebuild
        shift
        ;;
    -h | --help)
        usage
        ;;
    *)
        die "unknown argument: $1"
        ;;
    esac
done

case "$mode" in
release)
    fetch "$RELEASE_URL" "$TMP/$GRUB_EFI_NAME"
    verify_efi "$TMP/$GRUB_EFI_NAME"
    install_image "$TMP/$GRUB_EFI_NAME"
    ;;
file)
    verify_efi "$from_file"
    install_image "$from_file"
    ;;
rebuild)
    deb=${GRUB_DEB:-"$REPO/dist/grub/$GRUB_DEB_NAME"}
    if [ ! -f "$deb" ]; then
        fetch "$GRUB_DEB_URL" "$TMP/$GRUB_DEB_NAME"
        verify_deb "$TMP/$GRUB_DEB_NAME"
        mkdir -p "$(dirname "$deb")"
        install -m 0644 "$TMP/$GRUB_DEB_NAME" "$deb"
    fi
    verify_deb "$deb"

    ver=$(grub-mkimage --version 2>/dev/null | awk 'NR == 1 { print $NF }')
    case "$ver" in
    "$GRUB_MKIMAGE_VERSION_PREFIX"*) ;;
    *) die "grub-mkimage $ver does not match ${GRUB_MKIMAGE_VERSION_PREFIX}x" ;;
    esac

    dpkg-deb -x "$deb" "$TMP/root"
    moddir="$TMP/root/usr/lib/grub/x86_64-efi"
    [ -f "$moddir/kernel.img" ] || die "kernel.img missing from $deb"

    # Word splitting is intended: the module list is a fixed space-separated set.
    # shellcheck disable=SC2086
    grub-mkimage -d "$moddir" -O x86_64-efi -o "$TMP/$GRUB_EFI_NAME" \
        -p /EFI/BOOT $GRUB_MODULES
    verify_efi "$TMP/$GRUB_EFI_NAME"
    install_image "$TMP/$GRUB_EFI_NAME"
    ;;
esac
