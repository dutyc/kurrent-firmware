#!/usr/bin/env bash
# Verify a Secure Boot build.
#
# Usage: tools/verify-sb.sh <signing-cert.pem> [output-dir] [boot-ca.pem]
#
#   output-dir defaults to dist/secureboot.
#   boot-ca.pem, when given, is checked against manifest boot_ca_sha256.
#
# Checks:
#   - every *.efi in output-dir is named *-sb.efi (no unsigned artifact mixed in)
#   - every *-sb.efi carries a valid signature from the signing certificate
#   - SHA256SUMS matches the files on disk
#   - manifest.json fields are consistent with the artifact and certificate:
#     artifact_sha256, artifact_size, signer, boot_ca_sha256 (optional), tofu=false
#   - no private key or PEM material is present in output-dir
set -euo pipefail

usage() {
  echo "usage: $(basename "$0") <signing-cert.pem> [output-dir] [boot-ca.pem]" >&2
  exit 2
}

[[ $# -ge 1 && $# -le 3 ]] || usage
CERT="$1"
DIR="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/dist/secureboot}"
BOOT_CA="${3:-}"

for tool in find sort sbverify openssl python3 sha256sum; do
  command -v "$tool" >/dev/null || { echo "verify-sb: missing $tool" >&2; exit 1; }
done

[[ -f "$CERT" ]] || { echo "verify-sb: missing signing certificate: $CERT" >&2; exit 1; }
openssl x509 -in "$CERT" -noout >/dev/null 2>&1 \
  || { echo "verify-sb: not a PEM certificate: $CERT" >&2; exit 1; }
[[ -d "$DIR" ]] || { echo "verify-sb: missing output dir: $DIR" >&2; exit 1; }

if [[ -n "$BOOT_CA" ]]; then
  openssl x509 -in "$BOOT_CA" -noout >/dev/null 2>&1 \
    || { echo "verify-sb: not a PEM certificate: $BOOT_CA" >&2; exit 1; }
fi

# Any .efi that is not a signed profile artifact means an unsigned build was
# mixed into the output directory.
UNSIGNED="$(find "$DIR" -type f -name '*.efi' ! -name '*-sb.efi' | sort)"
if [[ -n "$UNSIGNED" ]]; then
  echo "verify-sb: unsigned EFI artifact(s) in $DIR:" >&2
  echo "$UNSIGNED" >&2
  exit 1
fi

mapfile -t EFIS < <(find "$DIR" -type f -name '*-sb.efi' | sort)
[[ ${#EFIS[@]} -gt 0 ]] || { echo "verify-sb: no signed EFI artifacts in $DIR" >&2; exit 1; }

for efi in "${EFIS[@]}"; do
  echo "== $efi"
  sbverify --cert "$CERT" "$efi"
done

[[ -f "$DIR/SHA256SUMS" ]] || { echo "verify-sb: missing SHA256SUMS" >&2; exit 1; }
( cd "$DIR" && sha256sum -c SHA256SUMS )

if find "$DIR" -type f \( -name '*.key' -o -name '*.pem' \) | grep -q .; then
  echo "verify-sb: private key material found in output directory" >&2
  exit 1
fi

expected_signer="$(openssl x509 -in "$CERT" -noout -subject -nameopt RFC2253 | sed 's/^subject=//')"
expected_ca_fp=""
if [[ -n "$BOOT_CA" ]]; then
  expected_ca_fp="$(openssl x509 -in "$BOOT_CA" -noout -fingerprint -sha256 | sed 's/^.*=//' | tr -d ':')"
fi

python3 - "$DIR" "$expected_signer" "$expected_ca_fp" <<'PY'
import hashlib
import json
import os
import sys

directory, expected_signer, expected_ca_fp = sys.argv[1:4]


def fail(message):
    print(f"verify-sb: {message}", file=sys.stderr)
    sys.exit(1)


manifest_path = os.path.join(directory, "manifest.json")
try:
    with open(manifest_path, encoding="utf-8") as handle:
        manifest = json.load(handle)
except FileNotFoundError:
    fail("missing manifest.json")
except json.JSONDecodeError as exc:
    fail(f"manifest.json is not valid JSON: {exc}")

required = ("artifact", "artifact_sha256", "artifact_size", "signer", "tofu")
missing = [key for key in required if key not in manifest]
if missing:
    fail("manifest.json missing keys: " + ", ".join(missing))

artifact = manifest["artifact"]
if not isinstance(artifact, str) or os.path.basename(artifact) != artifact:
    fail("manifest artifact must be a plain file name")
if not artifact.endswith("-sb.efi"):
    fail(f"manifest artifact {artifact!r} is not a *-sb.efi")

artifact_path = os.path.join(directory, artifact)
if not os.path.isfile(artifact_path):
    fail(f"manifest artifact missing: {artifact}")

digest = hashlib.sha256()
with open(artifact_path, "rb") as handle:
    for chunk in iter(lambda: handle.read(1 << 20), b""):
        digest.update(chunk)
actual_sha = digest.hexdigest()
if manifest["artifact_sha256"] != actual_sha:
    fail(
        "artifact_sha256 mismatch: "
        f"manifest {manifest['artifact_sha256']!r} != actual {actual_sha!r}"
    )

actual_size = os.path.getsize(artifact_path)
if manifest["artifact_size"] != actual_size:
    fail(
        "artifact_size mismatch: "
        f"manifest {manifest['artifact_size']!r} != actual {actual_size!r}"
    )

if manifest["signer"] != expected_signer:
    fail(
        "signer mismatch: "
        f"manifest {manifest['signer']!r} != certificate {expected_signer!r}"
    )

if manifest["tofu"] is not False:
    fail(f"tofu must be false, manifest has {manifest['tofu']!r}")

if expected_ca_fp:
    if "boot_ca_sha256" not in manifest:
        fail("manifest.json missing boot_ca_sha256")
    normalize = lambda value: str(value).replace(":", "").strip().upper()
    if normalize(manifest["boot_ca_sha256"]) != normalize(expected_ca_fp):
        fail(
            "boot_ca_sha256 mismatch: "
            f"manifest {manifest['boot_ca_sha256']!r} != boot CA {expected_ca_fp!r}"
        )

print(f"verify-sb: manifest OK ({artifact})")
PY

echo "verify-sb: OK (${#EFIS[@]} artifact(s))"
