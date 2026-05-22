#!/usr/bin/env bash
# measure-image.sh — print size, layer count, top layers, and reduction vs baseline
# Usage: ./measure-image.sh <tag> [baseline-tag]
set -euo pipefail

TAG="${1:-}"
BASELINE="${2:-}"

if [[ -z "$TAG" ]]; then
  echo "Usage: $0 <tag> [baseline-tag]" >&2
  exit 64
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "[measure] docker not found in PATH" >&2
  exit 127
fi

if ! docker image inspect "$TAG" >/dev/null 2>&1; then
  echo "[measure] image not found: $TAG" >&2
  exit 1
fi

SIZE_BYTES="$(docker image inspect "$TAG" --format '{{.Size}}')"
SIZE_MB="$(awk -v b="$SIZE_BYTES" 'BEGIN { printf "%.2f", b / (1024*1024) }')"
# Count history rows. Under BuildKit/manifests, IDs are mostly "<missing>" — so we
# count *all* non-empty rows rather than filtering them out.
LAYER_COUNT="$(docker history --format '{{.CreatedBy}}' "$TAG" 2>/dev/null | grep -cv '^$' || true)"

echo "[measure] image       : $TAG"
echo "[measure] total size  : ${SIZE_MB} MB"
echo "[measure] layer count : ${LAYER_COUNT}"

echo "[measure] top 5 layers by size:"
docker history --no-trunc --format '{{.Size}}\t{{.CreatedBy}}' "$TAG" \
  | sort -rh \
  | head -5 \
  | awk -F '\t' '{ printf "  %10s  %s\n", $1, substr($2, 1, 80) }'

if [[ -n "$BASELINE" ]]; then
  if ! docker image inspect "$BASELINE" >/dev/null 2>&1; then
    echo "[measure] baseline not found: $BASELINE (skipping delta)" >&2
    exit 0
  fi
  BASELINE_BYTES="$(docker image inspect "$BASELINE" --format '{{.Size}}')"
  BASELINE_MB="$(awk -v b="$BASELINE_BYTES" 'BEGIN { printf "%.2f", b / (1024*1024) }')"
  DELTA_PCT="$(awk -v o="$BASELINE_BYTES" -v n="$SIZE_BYTES" \
    'BEGIN { if (o == 0) { print "n/a" } else { printf "%.1f", (1 - n / o) * 100 } }')"
  echo "[measure] baseline    : ${BASELINE_MB} MB"
  echo "[measure] reduction   : ${DELTA_PCT}%"
  if awk -v d="$DELTA_PCT" 'BEGIN { exit !(d >= 25) }'; then
    echo "[measure] PASS (>= 25% reduction)"
  else
    echo "[measure] BELOW TARGET (target is >= 25% reduction)"
  fi
fi
