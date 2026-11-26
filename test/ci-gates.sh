#!/usr/bin/env bash
# Repository gates shared by CI and local runs.
#
# Usage: bash test/ci-gates.sh <syntax|shellcheck|embed|replay|build>
#
#   syntax      bash -n / sh -n for every tracked shell script
#   static-gate  ShellCheck at error severity on the same set
#   embed       every EMBED_B64_* payload matches its repository source
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
syntax) gate_syntax ;;
shellcheck) gate_shellcheck ;;
embed) gate_embed ;;
replay) gate_replay ;;
build) gate_build ;;
*)
    echo "usage: $0 <syntax|shellcheck|embed|replay|build>" >&2
    exit 1
    ;;
esac
