#!/usr/bin/env bash
# make-sbom.sh — generate an SPDX SBOM for an image, prefer Syft → Trivy
# Usage: ./make-sbom.sh <tag> [output-file]
set -euo pipefail

TAG="${1:-}"
OUT="${2:-sbom.spdx.json}"

if [[ -z "$TAG" ]]; then
  echo "Usage: $0 <tag> [output-file]" >&2
  exit 64
fi

if command -v syft >/dev/null 2>&1; then
  echo "[sbom] using syft  : $TAG → $OUT"
  syft "$TAG" -o spdx-json="$OUT"
elif command -v trivy >/dev/null 2>&1; then
  echo "[sbom] using trivy : $TAG → $OUT"
  trivy image --format spdx-json --output "$OUT" "$TAG"
else
  echo "[sbom] no SBOM generator found. install one:" >&2
  echo "       syft:  brew install syft  (or: https://github.com/anchore/syft)" >&2
  echo "       trivy: brew install aquasecurity/trivy/trivy" >&2
  exit 127
fi

BYTES="$(wc -c < "$OUT" | tr -d ' ')"
echo "[sbom] wrote $BYTES bytes to $OUT"
