#!/usr/bin/env bash
#
# kurrent-firmware Secure Boot (L2) build pipeline
#
# Reuses the normal patch set and applies patches/secureboot/0001-no-tofu.patch
# (TOFU disabled), embeds the three static Secure Boot scripts, pins the boot
# CA and signs the result.
#
# Keep the source fetch/apply flow in sync with build/build.sh: when that
# pipeline changes, update this script as well.
#
# Required:
#   SB_KEY=/path/to/artifact-signing.key   (offline; keep outside the repo)
#   SB_CERT=/path/to/artifact-signing.crt  (enrolled in UEFI db)
#   BOOT_CA_CERT=/path/to/boot-ca.crt      (CA:TRUE; pinned via TRUST=)
#
# Optional:
#   BOOT_HTTPS_PORT=4443                   (default; 1-65535)
#   CONTROLLER_IP=192.0.2.10               (IPv4 only; default: DHCP next-server)
#   KURRENT_SB_SRC_DIR, KURRENT_SB_OUT_DIR, UPSTREAM_URL, UPSTREAM_COMMIT, JOBS
#   KURRENT_SB_ALLOW_CUSTOM_OUT=1          (required to rm -rf OUT_DIR outside dist/)
#
# Output: dist/secureboot/snponly-sb.efi,
#         dist/secureboot/{pxe-uefi,direct-uefi}/snponly-sb.efi,
#         manifest.json, SHA256SUMS.

set -euo pipefail

UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/ipxe/ipxe.git}"
UPSTREAM_COMMIT="${UPSTREAM_COMMIT:-e6e51ccbf17ff40a899c8859fb4e95abd5cfcd57}"
FERRY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="${KURRENT_SB_SRC_DIR:-${FERRY_ROOT}/.cache/ipxe-sb}"
OUT_DIR="${KURRENT_SB_OUT_DIR:-${FERRY_ROOT}/dist/secureboot}"
JOBS="${JOBS:-$(nproc)}"
BOOT_HTTPS_PORT="${BOOT_HTTPS_PORT:-4443}"
CONTROLLER_IP="${CONTROLLER_IP:-}"

log() { echo -e "\033[1;32m[secureboot]\033[0m $*"; }
die() { echo -e "\033[1;31m[secureboot] ERROR: $*" >&2; exit 1; }

command -v git >/dev/null || die "缺少 git"
command -v make >/dev/null || die "缺少 make"
command -v gcc >/dev/null || die "缺少 gcc"
command -v sbsign >/dev/null || die "缺少 sbsign（sbsigntool）"
command -v sbverify >/dev/null || die "缺少 sbverify（sbsigntool）"
command -v openssl >/dev/null || die "缺少 openssl"
command -v python3 >/dev/null || die "缺少 python3"
command -v realpath >/dev/null || die "缺少 realpath（coreutils）"

[[ -n "${SB_KEY:-}" && -f "${SB_KEY}" ]] || die "SB_KEY missing or not a file"
[[ -n "${SB_CERT:-}" && -f "${SB_CERT}" ]] || die "SB_CERT missing or not a file"
[[ -n "${BOOT_CA_CERT:-}" && -f "${BOOT_CA_CERT}" ]] || die "BOOT_CA_CERT missing or not a file"

# Canonicalise all paths before any cd: TRUST=/CERT= are handed to make from
# inside $SRC_DIR/src, where relative paths would resolve incorrectly.
SB_KEY="$(realpath "$SB_KEY")"
SB_CERT="$(realpath "$SB_CERT")"
BOOT_CA_CERT="$(realpath "$BOOT_CA_CERT")"
SRC_DIR="$(realpath -m "$SRC_DIR")"
OUT_DIR="$(realpath -m "$OUT_DIR")"

openssl x509 -in "$BOOT_CA_CERT" -noout >/dev/null 2>&1 || die "BOOT_CA_CERT is not a PEM certificate"
openssl x509 -in "$BOOT_CA_CERT" -noout -ext basicConstraints 2>/dev/null \
  | grep -q 'CA:TRUE' || die "BOOT_CA_CERT must be a CA certificate (basicConstraints CA:TRUE)"
openssl x509 -in "$SB_CERT" -noout >/dev/null 2>&1 || die "SB_CERT is not a PEM certificate"

[[ "$BOOT_HTTPS_PORT" =~ ^[0-9]+$ ]] || die "BOOT_HTTPS_PORT must be numeric"
[[ "$BOOT_HTTPS_PORT" =~ ^[1-9][0-9]*$ ]] && (( 10#$BOOT_HTTPS_PORT <= 65535 )) \
  || die "BOOT_HTTPS_PORT must be between 1 and 65535"

if [[ -n "$CONTROLLER_IP" ]]; then
  octet_re='(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])'
  [[ "$CONTROLLER_IP" =~ ^${octet_re}(\.${octet_re}){3}$ ]] \
    || die "CONTROLLER_IP must be an IPv4 literal"
  CONTROLLER_EXPR="$CONTROLLER_IP"
  CONTROLLER_DESC="$CONTROLLER_IP (fixed)"
else
  CONTROLLER_EXPR='${next-server}'
  CONTROLLER_DESC='${next-server} (DHCP)'
fi

# Refuse to clean or remove anything outside the repository's own cache/dist
# trees unless the caller explicitly opts in.
DIST_ROOT="${FERRY_ROOT}/dist"
CACHE_ROOT="${FERRY_ROOT}/.cache"
if [[ "$OUT_DIR" != "$DIST_ROOT"/* ]]; then
  [[ "${KURRENT_SB_ALLOW_CUSTOM_OUT:-0}" == "1" ]] \
    || die "OUT_DIR outside ${DIST_ROOT} requires KURRENT_SB_ALLOW_CUSTOM_OUT=1"
fi
if [[ "$SRC_DIR" != "$CACHE_ROOT"/* ]]; then
  origin="$(git -C "$SRC_DIR" remote get-url origin 2>/dev/null || true)"
  [[ "$origin" == "$UPSTREAM_URL" ]] \
    || die "SRC_DIR outside ${CACHE_ROOT} must have origin ${UPSTREAM_URL}"
fi

prepare_source() {
  if [[ -d "$SRC_DIR/.git" ]]; then
    log "复用上游源码缓存: $SRC_DIR"
  else
    log "获取上游源码: $UPSTREAM_URL"
    mkdir -p "$(dirname "$SRC_DIR")"
    git clone --filter=blob:none --no-checkout "$UPSTREAM_URL" "$SRC_DIR"
  fi
  log "检出基线: $UPSTREAM_COMMIT"
  git -C "$SRC_DIR" fetch --depth 1 "$UPSTREAM_URL" "$UPSTREAM_COMMIT" >/dev/null 2>&1 \
    || git -C "$SRC_DIR" cat-file -e "$UPSTREAM_COMMIT^{commit}" \
    || die "无法获取基线 $UPSTREAM_COMMIT"
  git -C "$SRC_DIR" checkout --force "$UPSTREAM_COMMIT"
  git -C "$SRC_DIR" clean -fdxq

  local patch
  for patch in "$FERRY_ROOT"/patches/*.patch; do
    log "应用补丁: $(basename "$patch")"
    git -C "$SRC_DIR" apply --check "$patch" || die "补丁无法应用: $(basename "$patch")"
    git -C "$SRC_DIR" apply "$patch"
  done
  for patch in "$FERRY_ROOT"/patches/secureboot/*.patch; do
    log "应用 Secure Boot 叠加补丁: $(basename "$patch")"
    git -C "$SRC_DIR" apply --check "$patch" || die "补丁无法应用: $(basename "$patch")"
    git -C "$SRC_DIR" apply "$patch"
  done
}

render_embed() {
  local src="$FERRY_ROOT/embed/secureboot"
  local dst="$SRC_DIR/src/embed/secureboot"
  mkdir -p "$dst"
  cp "$src/auto.ipxe" "$dst/auto.ipxe"
  sed -e "s|@BOOT_HTTPS_PORT@|$BOOT_HTTPS_PORT|g" \
      -e "s|@CONTROLLER_EXPR@|$CONTROLLER_EXPR|g" \
      "$src/sb-boot.ipxe.cfg" > "$dst/sb-boot.ipxe.cfg"
  cp "$src/sb-menu.ipxe" "$dst/sb-menu.ipxe"
}

build_and_sign() {
  local target="bin-x86_64-efi/snponly.efi"
  local embed="embed/secureboot/auto.ipxe,embed/secureboot/sb-boot.ipxe.cfg,embed/secureboot/sb-menu.ipxe"
  log "构建 $target（EMBED 多脚本 + TRUST/CERT=boot CA）"
  rm -f "$SRC_DIR/src/$target"
  # TRUST pins the CA fingerprint; CERT embeds the CA certificate so the chain
  # can be built even though TLS servers normally omit the root certificate.
  ( cd "$SRC_DIR/src" && make "$target" EMBED="$embed" \
      TRUST="$BOOT_CA_CERT" CERT="$BOOT_CA_CERT" -j"$JOBS" )

  rm -rf "$OUT_DIR"
  mkdir -p "$OUT_DIR/pxe-uefi" "$OUT_DIR/direct-uefi"
  local unsigned="$SRC_DIR/src/$target"
  local signed="$OUT_DIR/snponly-sb.efi"
  sbsign --key "$SB_KEY" --cert "$SB_CERT" --output "$signed" "$unsigned"
  sbverify --cert "$SB_CERT" "$signed"
  cp "$signed" "$OUT_DIR/pxe-uefi/snponly-sb.efi"
  cp "$signed" "$OUT_DIR/direct-uefi/snponly-sb.efi"
}

write_manifest() {
  local signer ca_fp artifact_sha size
  signer="$(openssl x509 -in "$SB_CERT" -noout -subject -nameopt RFC2253 | sed 's/^subject=//')"
  ca_fp="$(openssl x509 -in "$BOOT_CA_CERT" -noout -fingerprint -sha256 | sed 's/^.*=//' | tr -d ':')"
  artifact_sha="$(sha256sum "$OUT_DIR/snponly-sb.efi" | awk '{print $1}')"
  size="$(stat -c '%s' "$OUT_DIR/snponly-sb.efi")"
  python3 - "$OUT_DIR" "$UPSTREAM_COMMIT" "$BOOT_HTTPS_PORT" "$CONTROLLER_DESC" \
    "$signer" "$ca_fp" "$artifact_sha" "$size" <<'PY'
import datetime, json, os, sys
(out, upstream, port, controller, signer, ca_fp, artifact_sha, size) = sys.argv[1:]
doc = {
    "profile": "secureboot",
    "upstream_commit": upstream,
    "boot_https_port": int(port),
    "controller": controller,
    "artifact": "snponly-sb.efi",
    "artifact_sha256": artifact_sha,
    "artifact_size": int(size),
    "signer": signer,
    "boot_ca_sha256": ca_fp,
    "built_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "tofu": False,
}
with open(os.path.join(out, "manifest.json"), "w", encoding="utf-8") as fh:
    json.dump(doc, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
  ( cd "$OUT_DIR" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum ) > "$OUT_DIR/SHA256SUMS"
  log "产物: $OUT_DIR"
  cat "$OUT_DIR/SHA256SUMS"
}

prepare_source
render_embed
build_and_sign
write_manifest
log "Secure Boot 构建完成 ✓（port=$BOOT_HTTPS_PORT, controller=$CONTROLLER_DESC）"
