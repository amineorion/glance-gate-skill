#!/usr/bin/env bash
# audit-node-bundle.sh — figure out which glance-gate tier a Node project
# can hit, and emit a markdown fragment the final report includes.
#
# Usage:
#   ./scripts/audit-node-bundle.sh <entry-file> [out.md]
#
# Examples:
#   ./scripts/audit-node-bundle.sh src/main.ts
#   ./scripts/audit-node-bundle.sh services/user-api/src/main.ts /tmp/audit.md
#
# Output:
#   - prints a recommended tier (0 / 1 / 2) on the LAST line of stdout, e.g.
#       RECOMMENDED_TIER=0
#   - writes a human-readable markdown report to $2 (default: bundle-audit.md
#     in the entry's project root).
#
# Tier rubric:
#   Tier 0 — bun --compile --target=bun → FROM scratch
#     * No native `.node` bindings AND
#     * No dynamic import() / require() with non-literal paths AND
#     * No `eval` / `new Function`.
#   Tier 1 — esbuild single-file bundle → distroless
#     * Dynamic imports use bun/node `--external` resolvable packages
#       OR a finite set of literal-string dynamic imports we can static-import
#     * Native bindings exist but can be COPYd surgically.
#   Tier 2 — pnpm/npm deploy + scorched-earth cleanup → distroless
#     * Plugin systems with N workspace packages dynamic-imported at runtime
#       (edorer-style), OR
#     * eval / new Function present.
#
# The audit is deliberately conservative — it never recommends a tier that
# the heuristics can't justify. The orchestrator is free to attempt a
# higher tier than recommended; the audit just sets a sensible default.

set -euo pipefail

ENTRY="${1:-}"
if [[ -z "$ENTRY" ]]; then
  echo "Usage: $0 <entry-file> [out.md]" >&2
  exit 64
fi
if [[ ! -f "$ENTRY" ]]; then
  echo "[audit] entry not found: $ENTRY" >&2
  exit 1
fi

# Resolve project root: walk up from the entry until we find a package.json.
PROJECT_ROOT="$(cd "$(dirname "$ENTRY")" && pwd)"
while [[ "$PROJECT_ROOT" != "/" && ! -f "$PROJECT_ROOT/package.json" ]]; do
  PROJECT_ROOT="$(dirname "$PROJECT_ROOT")"
done
if [[ ! -f "$PROJECT_ROOT/package.json" ]]; then
  echo "[audit] no package.json found walking up from $ENTRY" >&2
  exit 1
fi

OUT="${2:-$PROJECT_ROOT/bundle-audit.md}"
SRC_ROOTS=()
for d in src app lib services packages apps; do
  [[ -d "$PROJECT_ROOT/$d" ]] && SRC_ROOTS+=("$PROJECT_ROOT/$d")
done
# If nothing matched, fall back to entry's dir.
if [[ ${#SRC_ROOTS[@]} -eq 0 ]]; then
  SRC_ROOTS+=("$(dirname "$ENTRY")")
fi

# Build a `grep -r` arg list once.
GREP_ROOTS=()
for r in "${SRC_ROOTS[@]}"; do GREP_ROOTS+=("$r"); done

# Package manager detection.
PKG_MANAGER="npm"
[[ -f "$PROJECT_ROOT/pnpm-lock.yaml" ]] && PKG_MANAGER="pnpm"
[[ -f "$PROJECT_ROOT/yarn.lock"       ]] && PKG_MANAGER="yarn"
[[ -f "$PROJECT_ROOT/bun.lockb"       ]] && PKG_MANAGER="bun"
[[ -f "$PROJECT_ROOT/bun.lock"        ]] && PKG_MANAGER="bun"

# --- Signal 1: dynamic imports with non-literal arguments.
# Catches  import(`./plugins/${name}`)  and  require(varName)  but NOT
# import('./x') with a static string. Strip // line comments and /* */
# block comments BEFORE grepping so `// dynamic import via import(x)`
# inside a doc comment doesn't inflate the count.
DYN_IMPORTS_RAW="$(
  find "${GREP_ROOTS[@]}" \
       \( -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.mjs' -o -name '*.cjs' \) \
       -type f 2>/dev/null \
  | while read -r f; do
      # Strip /* … */ (greedy across lines) then // … to end of line,
      # then re-emit with file:line prefix. Comments removed reduce
      # false positives without losing useful signal.
      python3 - "$f" <<'PY' 2>/dev/null || true
import re, sys
path = sys.argv[1]
with open(path, 'r', errors='replace') as fh:
    src = fh.read()
src = re.sub(r'/\*.*?\*/', '', src, flags=re.S)
out = []
for i, line in enumerate(src.splitlines(), 1):
    # Strip // comments but respect strings naively. Good enough for
    # the heuristic: a false positive only nudges the tier down.
    line_no_cmt = re.sub(r'//.*$', '', line)
    if 'import(' in line_no_cmt or 'require(' in line_no_cmt:
        print(f'{path}:{i}:{line_no_cmt}')
PY
    done
)"

# Filter to non-literal call sites: keep lines whose argument isn't a single
# quoted string literal. We're lenient — a few false positives don't change
# the recommendation, but missing a real dynamic import does.
DYN_IMPORTS_NONLITERAL="$(printf '%s\n' "$DYN_IMPORTS_RAW" \
  | awk '
    {
      line = $0
      # Find "import(" or "require(" and capture everything from just past
      # the open paren to the first close paren on the same line.
      if (!match(line, /(import|require)\(/)) next
      after = substr(line, RSTART + RLENGTH)
      # Naïve first-`)` cut. Good enough for the heuristic — multi-line
      # imports are rare in real code, and a false positive only nudges
      # the tier recommendation down (more conservative), never up.
      sub(/\).*$/, "", after)
      # Drop trailing args (second positional arg to import()).
      sub(/,.*$/, "", after)
      gsub(/^[ \t]+/, "", after); gsub(/[ \t]+$/, "", after)
      # Pure literal-string forms — skip.
      if (after ~ /^"[^"$\\]*"$/)             next
      if (after ~ /^'\''[^'\''$\\]*'\''$/)    next
      if (after ~ /^`[^`$\\]*`$/)             next
      print
    }' || true)"

DYN_COUNT="$(printf '%s\n' "$DYN_IMPORTS_NONLITERAL" | grep -cv '^$' || true)"

# --- Signal 2: eval / new Function.
EVAL_HITS="$(grep -rEn --include='*.ts' --include='*.tsx' --include='*.js' --include='*.mjs' --include='*.cjs' \
    -e '\beval\(' -e 'new[ \t]+Function\(' \
    "${GREP_ROOTS[@]}" 2>/dev/null || true)"
EVAL_COUNT="$(printf '%s\n' "$EVAL_HITS" | grep -cv '^$' || true)"

# --- Signal 3: native bindings (.node files inside node_modules).
NATIVE_BINDINGS="$(find "$PROJECT_ROOT/node_modules" -maxdepth 6 -name '*.node' -type f 2>/dev/null \
  | sed -E "s|$PROJECT_ROOT/node_modules/||" \
  | awk -F/ '{
      # @scope/name  OR  name
      if ($1 ~ /^@/) print $1 "/" $2
      else           print $1
    }' \
  | sort -u || true)"
NATIVE_COUNT="$(printf '%s\n' "$NATIVE_BINDINGS" | grep -cv '^$' || true)"

# --- Signal 4: workspace plugins (dependency entries pointing at workspace:*).
WORKSPACE_PLUGINS="$(python3 - <<PY 2>/dev/null || true
import json, sys
with open("$PROJECT_ROOT/package.json") as f:
    pkg = json.load(f)
deps = pkg.get("dependencies", {}) | pkg.get("devDependencies", {})
ws = [k for k, v in deps.items() if isinstance(v, str) and v.startswith("workspace:")]
print("\n".join(sorted(ws)))
PY
)"
WS_COUNT="$(printf '%s\n' "$WORKSPACE_PLUGINS" | grep -cv '^$' || true)"

# --- Signal 5: Prisma. Ships a per-platform .node engine binary loaded
# at runtime via dlopen — blocks Tier 0 (bun-compile) until Prisma 5.7+,
# and requires `apt install openssl` in the builder for autodetect to
# pick the right openssl ABI (1.1 vs 3.0).
PRISMA_DETECTED=0
PRISMA_VERSION=""
if [[ -f "$PROJECT_ROOT/package.json" ]] && grep -q '@prisma/client' "$PROJECT_ROOT/package.json" 2>/dev/null; then
  PRISMA_DETECTED=1
  PRISMA_VERSION="$(python3 - <<PY 2>/dev/null || true
import json
with open("$PROJECT_ROOT/package.json") as f:
    pkg = json.load(f)
deps = {**(pkg.get("dependencies") or {}), **(pkg.get("devDependencies") or {})}
print(deps.get("@prisma/client", "?"))
PY
)"
fi
# Also detect by schema file.
if [[ -z "$PRISMA_VERSION" ]] && find "$PROJECT_ROOT/src" "$PROJECT_ROOT/prisma" -maxdepth 3 -name "schema.prisma" 2>/dev/null | head -1 | grep -q .; then
  PRISMA_DETECTED=1
fi

# --- Signal 6: Nx workspace. The repo's own Dockerfile likely assumes
# a host-side `nx build` already ran — won't work inside `docker build`
# without a builder stage that runs Nx first.
NX_DETECTED=0
if [[ -f "$PROJECT_ROOT/nx.json" ]] || grep -q '"nx"' "$PROJECT_ROOT/package.json" 2>/dev/null; then
  NX_DETECTED=1
fi

# --- Heuristic: pick the tier.
TIER=0
TIER_REASON="no dynamic imports, no native bindings, no eval — clean bundle target"
if [[ "$EVAL_COUNT" -gt 0 ]]; then
  TIER=2
  TIER_REASON="$EVAL_COUNT eval()/new Function() call site(s) — cannot statically bundle"
elif [[ "$PRISMA_DETECTED" -eq 1 ]]; then
  TIER=1
  TIER_REASON="Prisma detected (${PRISMA_VERSION:-version unknown}) — bun-compile blocked by the runtime-loaded engine binary; bundle JS, surgical COPY of node_modules/{@prisma,.prisma}/client"
elif [[ "$DYN_COUNT" -gt 5 ]]; then
  TIER=2
  TIER_REASON="$DYN_COUNT non-literal dynamic import/require — plugin-style runtime, bundling unsafe"
elif [[ "$NATIVE_COUNT" -gt 0 && "$DYN_COUNT" -gt 0 ]]; then
  TIER=1
  TIER_REASON="$NATIVE_COUNT native binding(s) + $DYN_COUNT dynamic import(s) — bundle + surgical externals"
elif [[ "$NATIVE_COUNT" -gt 0 ]]; then
  TIER=1
  TIER_REASON="$NATIVE_COUNT native binding(s) — bundle JS, COPY native packages, distroless runtime"
elif [[ "$DYN_COUNT" -gt 0 ]]; then
  TIER=1
  TIER_REASON="$DYN_COUNT dynamic import(s) — bundle as ESM with externals, distroless runtime"
fi

# --- Emit markdown.
{
  echo "## Bundle audit"
  echo
  echo "- Entry: \`$ENTRY\`"
  echo "- Project root: \`$PROJECT_ROOT\`"
  echo "- Package manager: \`$PKG_MANAGER\`"
  echo "- Workspace deps: $WS_COUNT"
  echo "- Native bindings: $NATIVE_COUNT"
  echo "- Non-literal dynamic imports: $DYN_COUNT"
  echo "- eval / new Function: $EVAL_COUNT"
  if [[ "$PRISMA_DETECTED" -eq 1 ]]; then
    echo "- Prisma: detected (${PRISMA_VERSION:-version unknown})"
  fi
  if [[ "$NX_DETECTED" -eq 1 ]]; then
    echo "- Nx workspace: detected"
  fi
  echo
  echo "### Recommended tier: **$TIER**"
  echo
  echo "$TIER_REASON"
  echo

  if [[ "$NATIVE_COUNT" -gt 0 ]]; then
    echo "### Native bindings"
    echo
    printf '%s\n' "$NATIVE_BINDINGS" | awk 'NF{print "- `" $0 "`"}'
    echo
  fi

  if [[ "$DYN_COUNT" -gt 0 ]]; then
    echo "### Non-literal dynamic imports (first 20)"
    echo
    printf '%s\n' "$DYN_IMPORTS_NONLITERAL" | head -20 | awk 'NF{print "- `" $0 "`"}'
    if [[ "$DYN_COUNT" -gt 20 ]]; then
      echo
      echo "(+ $((DYN_COUNT - 20)) more)"
    fi
    echo
  fi

  if [[ "$EVAL_COUNT" -gt 0 ]]; then
    echo "### eval / new Function call sites"
    echo
    printf '%s\n' "$EVAL_HITS" | awk 'NF{print "- `" $0 "`"}'
    echo
  fi

  if [[ "$WS_COUNT" -gt 0 ]]; then
    echo "### Workspace plugins (workspace:* deps)"
    echo
    printf '%s\n' "$WORKSPACE_PLUGINS" | awk 'NF{print "- `" $0 "`"}'
    echo
    echo "If these are loaded via dynamic import, generate a static plugin"
    echo "manifest (\`plugins.generated.ts\`) that re-exports all of them and"
    echo "import THAT from the entry. Then the bundler can see the whole graph."
    echo
  fi

  if [[ "$PRISMA_DETECTED" -eq 1 ]]; then
    echo "### Prisma checklist"
    echo
    echo "- **Builder must include \`openssl\`** so Prisma autodetects the"
    echo "  \`linux-arm64-openssl-3.0.x\` engine. Without it Prisma silently"
    echo "  picks 1.1.x and fails to load on \`distroless/nodejs20-debian12\`"
    echo "  (libssl3 only). \`apt-get install -y --no-install-recommends openssl ca-certificates\`."
    echo "- **Externalize the engine** from esbuild:"
    echo "  \`--external:@prisma/client --external:.prisma/client\`."
    echo "- **Surgical COPY** onto the runtime stage:"
    echo "  \`COPY --from=build /repo/node_modules/@prisma/client /app/node_modules/@prisma/client\`"
    echo "  \`COPY --from=build /repo/node_modules/.prisma/client /app/node_modules/.prisma/client\`."
    echo "- **Tier 0 is blocked** until Prisma ≥ 5.7 (the version that"
    echo "  ships \`linux-musl-arm64-openssl-3.0.x\` engines). Log as"
    echo "  user_action_required."
    echo
  fi

  if [[ "$NX_DETECTED" -eq 1 ]]; then
    echo "### Nx workspace checklist"
    echo
    echo "- The repo's own Dockerfile likely expects a host-side"
    echo "  \`nx docker-build <app>\` (Nx pre-builds \`dist/<app>\` and"
    echo "  passes it to docker). That doesn't compose cleanly inside a"
    echo "  hermetic \`docker build\`."
    echo "- Bake the Nx build into the builder stage. Then bundle"
    echo "  \`dist/<app>/main.js\` (or \`src/main.ts\` directly) with esbuild."
    echo
  fi
} > "$OUT"

echo "[audit] entry        : $ENTRY"
echo "[audit] project root : $PROJECT_ROOT"
echo "[audit] pkg manager  : $PKG_MANAGER"
echo "[audit] dyn imports  : $DYN_COUNT"
echo "[audit] eval calls   : $EVAL_COUNT"
echo "[audit] native bind. : $NATIVE_COUNT"
echo "[audit] workspaces   : $WS_COUNT"
echo "[audit] prisma       : $PRISMA_DETECTED"
echo "[audit] nx           : $NX_DETECTED"
echo "[audit] report       : $OUT"
echo "RECOMMENDED_TIER=$TIER"
