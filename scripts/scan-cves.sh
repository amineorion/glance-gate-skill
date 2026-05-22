#!/usr/bin/env bash
# scan-cves.sh — scan an image for CVEs, prefer Trivy → Grype → Docker Scout
# Usage: ./scan-cves.sh <tag> [output-file]
set -euo pipefail

TAG="${1:-}"
OUT="${2:-/dev/stdout}"

if [[ -z "$TAG" ]]; then
  echo "Usage: $0 <tag> [output-file]" >&2
  exit 64
fi

SCANNER=""
if command -v trivy >/dev/null 2>&1; then
  SCANNER="trivy"
elif command -v grype >/dev/null 2>&1; then
  SCANNER="grype"
elif docker scout version >/dev/null 2>&1; then
  SCANNER="docker-scout"
else
  echo "[scan] no scanner found. install one:" >&2
  echo "       trivy:  brew install aquasecurity/trivy/trivy  (or: https://aquasecurity.github.io/trivy)" >&2
  echo "       grype:  brew install grype                     (or: https://github.com/anchore/grype)" >&2
  echo "       scout:  docker scout (built-in on recent Docker Desktop)" >&2
  exit 127
fi

echo "[scan] using scanner : $SCANNER"
echo "[scan] image         : $TAG"
echo "[scan] output        : $OUT"

case "$SCANNER" in
  trivy)
    trivy image \
      --severity CRITICAL,HIGH,MEDIUM,LOW \
      --no-progress \
      --format table \
      "$TAG" | tee "$OUT"
    # Counts summary
    CRIT="$(trivy image --severity CRITICAL --quiet --format json "$TAG" 2>/dev/null | grep -c '"VulnerabilityID"' || true)"
    HIGH="$(trivy image --severity HIGH     --quiet --format json "$TAG" 2>/dev/null | grep -c '"VulnerabilityID"' || true)"
    echo "[scan] summary       : CRITICAL=$CRIT  HIGH=$HIGH"
    ;;
  grype)
    grype "$TAG" -o table | tee "$OUT"
    CRIT="$(grype "$TAG" -o json 2>/dev/null | grep -c '"severity": "Critical"' || true)"
    HIGH="$(grype "$TAG" -o json 2>/dev/null | grep -c '"severity": "High"' || true)"
    echo "[scan] summary       : CRITICAL=$CRIT  HIGH=$HIGH"
    ;;
  docker-scout)
    docker scout cves "$TAG" | tee "$OUT"
    ;;
esac
