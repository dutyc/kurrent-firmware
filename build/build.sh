#!/usr/bin/env bash
#
# kurrent-firmware 自动化构建流水线
#
# 流程：获取上游源码（固定基线）-> 应用补丁 -> 嵌入脚本 -> 构建 -> 归档
#
# 用法：
#   ./build/build.sh                 # 默认配置完整构建
#   UPSTREAM_COMMIT=<sha> ./build/build.sh   # 指定上游基线
#   JOBS=8 ./build/build.sh          # 指定并行度
#
# 产物输出到 dist/，附 SHA256SUMS 校验清单。

set -euo pipefail

# ---------------------------------------------------------------- 配置
UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/ipxe/ipxe.git}"
# 补丁基线：必须与 patches/ 下的补丁匹配；升级基线见 patches/README.md
UPSTREAM_COMMIT="${UPSTREAM_COMMIT:-e6e51ccbf17ff40a899c8859fb4e95abd5cfcd57}"

FERRY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE_DIR="${FERRY_ROOT}/.cache"
SRC_DIR="${CACHE_DIR}/ipxe-upstream"
OUT_DIR="${FERRY_ROOT}/dist"
JOBS="${JOBS:-$(nproc)}"

# 构建清单：输出名|make 目标|make 参数
# 仅 UEFI 平台（x86_64-efi）；传统 BIOS 目标（ipxe.lkrn/undionly.kpxe/ipxe.usb）不构建
# 同名目标（bin-x86_64-efi/ipxe.efi）受 EMBED 参数影响，构建前强制删除目标以保证参数生效
BUILD_TARGETS=(
  "pxe-uefi/ipxe.efi|bin-x86_64-efi/ipxe.efi|"
  "pxe-uefi/ipxe-debug.efi|bin-x86_64-efi/ipxe-debug.efi|DEBUG=realtek:3"
  "pxe-uefi/snponly.efi|bin-x86_64-efi/snponly.efi|"
  "pxe-uefi/snponly-debug.efi|bin-x86_64-efi/snponly-debug.efi|DEBUG=realtek:3"
  "direct-uefi/ipxe.efi|bin-x86_64-efi/ipxe.efi|EMBED=embed/auto.ipxe"
  "direct-uefi/ipxe-debug.efi|bin-x86_64-efi/ipxe-debug.efi|EMBED=embed/auto.ipxe DEBUG=realtek:3"
  "direct-uefi/snponly.efi|bin-x86_64-efi/snponly.efi|EMBED=embed/auto.ipxe"
)

log() { echo -e "\033[1;32m[kurrent-firmware]\033[0m $*"; }
die() { echo -e "\033[1;31m[kurrent-firmware]\033[0m ERROR: $*" >&2; exit 1; }

command -v git  >/dev/null || die "缺少 git"
command -v make >/dev/null || die "缺少 make"
command -v gcc  >/dev/null || die "缺少 gcc"

# ------------------------------------------------------------ 1. 上游源码
fetch_source() {
  # 本地源（file:// 或绝对路径）：全克隆，直接检出基线
  local src_is_local=0
  case "${UPSTREAM_URL}" in
    file://*|/*) src_is_local=1 ;;
  esac

  if [[ -d "${SRC_DIR}/.git" ]]; then
    log "上游源码已缓存: ${SRC_DIR}"
  else
    log "获取上游源码: ${UPSTREAM_URL}"
    mkdir -p "${CACHE_DIR}"
    if [[ ${src_is_local} -eq 1 ]]; then
      git clone --no-checkout "${UPSTREAM_URL}" "${SRC_DIR}"
    else
      git clone --filter=blob:none --no-checkout "${UPSTREAM_URL}" "${SRC_DIR}"
    fi
  fi

  log "检出基线: ${UPSTREAM_COMMIT}"
  if [[ ${src_is_local} -eq 1 ]]; then
    git -C "${SRC_DIR}" checkout --force "${UPSTREAM_COMMIT}" \
        || die "无法检出基线 ${UPSTREAM_COMMIT}（本地源缺少该提交？）"
  else
    # 直接以 UPSTREAM_URL 取基线，不依赖缓存 origin（origin 可能已失效）
    git -C "${SRC_DIR}" fetch --depth 1 "${UPSTREAM_URL}" "${UPSTREAM_COMMIT}" \
        || die "无法获取基线 ${UPSTREAM_COMMIT}（上游已重写历史？）"
    git -C "${SRC_DIR}" checkout --force "FETCH_HEAD"
  fi
  git -C "${SRC_DIR}" clean -fdxq
}

# ------------------------------------------------------------------ 2. 补丁
apply_patches() {
  local patch
  for patch in "${FERRY_ROOT}"/patches/*.patch; do
    log "应用补丁: $(basename "${patch}")"
    git -C "${SRC_DIR}" apply --check "${patch}" \
        || die "补丁 $(basename "${patch}") 无法应用到基线 ${UPSTREAM_COMMIT}（见 patches/README.md 升级流程）"
    git -C "${SRC_DIR}" apply "${patch}"
  done

  log "安装嵌入脚本: embed/auto.ipxe"
  mkdir -p "${SRC_DIR}/src/embed"
  cp "${FERRY_ROOT}/embed/auto.ipxe" "${SRC_DIR}/src/embed/auto.ipxe"
}

# ------------------------------------------------------------------ 3. 构建
build_all() {
  local entry name target params
  rm -rf "${OUT_DIR}"
  mkdir -p "${OUT_DIR}"

  for entry in "${BUILD_TARGETS[@]}"; do
    IFS='|' read -r name target params <<< "${entry}"
    log "构建 ${name}  (make ${target} ${params})"
    # 强制重建：同目标多参数构建时 make 不会因命令行变量变化而重建
    rm -f "${SRC_DIR}/src/${target}"
    ( cd "${SRC_DIR}/src" && make "${target}" ${params} -j"${JOBS}" )
    mkdir -p "${OUT_DIR}/$(dirname "${name}")"
    cp "${SRC_DIR}/src/${target}" "${OUT_DIR}/${name}"
  done
}

# ---------------------------------------------------------------- 4. 校验
write_manifest() {
  # 排除 SHA256SUMS 自身：清单哈希须可复现（sha256sum -c 校验通过）
  ( cd "${OUT_DIR}" && find . -type f ! -name SHA256SUMS | sort | xargs sha256sum ) > "${OUT_DIR}/SHA256SUMS"
  log "构建产物清单（${OUT_DIR}）："
  cat "${OUT_DIR}/SHA256SUMS"
}

# ------------------------------------------------------------------ 入口
fetch_source
apply_patches
build_all
write_manifest
log "构建完成 ✓"
