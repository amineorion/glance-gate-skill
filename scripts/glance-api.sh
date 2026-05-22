#!/usr/bin/env bash
# glance-api.sh — talk to the glance-gate learning API.
#
# Subcommands:
#   ensure-token              — bootstrap a device token if missing (idempotent)
#   recall  <lang> [opts...]  — fetch strategies for a stack
#   record  <json-body>       — record a successful run (body is JSON on stdin or arg)
#
# Token storage: ${GLANCE_TOKEN_PATH:-~/.glance-gate/token}
# API endpoint:  ${GLANCE_API_URL:-https://api.glance-gate.com}
# Override either for local testing:
#   GLANCE_API_URL=http://localhost:7080 ./scripts/glance-api.sh recall node fastify=true
#
# The script is deliberately small and forgiving. If the API is unreachable, it
# prints a one-line warning to stderr and exits 0 — the skill should treat
# recall/record as best-effort, not load-bearing.

set -euo pipefail

API_URL="${GLANCE_API_URL:-https://api.glance-gate.com}"
TOKEN_PATH="${GLANCE_TOKEN_PATH:-$HOME/.glance-gate/token}"
KEY_PATH="${GLANCE_KEY_PATH:-$HOME/.glance-gate/key}"
TIMEOUT="${GLANCE_API_TIMEOUT:-6}"

# project_id: stable, anonymous identifier for "this project."
# Order of preference:
#   1. $GLANCE_PROJECT_ID (explicit override)
#   2. sha256(`git config --get remote.origin.url`) truncated to 16 hex
#   3. sha256(`git rev-parse --show-toplevel`) truncated to 16 hex
#   4. sha256(`pwd`) truncated to 16 hex
# We hash so the raw URL or path never leaves the box.
compute_project_id() {
  if [ -n "${GLANCE_PROJECT_ID:-}" ]; then
    printf '%s' "$GLANCE_PROJECT_ID"
    return 0
  fi
  local seed
  seed="$(git config --get remote.origin.url 2>/dev/null || true)"
  if [ -z "$seed" ]; then
    seed="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  fi
  if [ -z "$seed" ]; then
    seed="$(pwd 2>/dev/null || echo unknown)"
  fi
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$seed" | shasum -a 256 | awk '{print substr($1, 1, 16)}'
  else
    printf '%s' "$seed" | sha256sum | awk '{print substr($1, 1, 16)}'
  fi
}

usage() {
  cat <<USAGE >&2
usage: $0 <command> [args]

commands:
  ensure-token
  recall <language> [framework=...] [hasNativeDeps=true|false] [deps=name1,name2,...]
  run    (reads JSON body from stdin OR pass as first arg)
  record (DEPRECATED — single-outcome wrapper, kept for back-compat)
  articles submit <json>   — POST 4 articles (encrypted) after a run
  articles get <lang> [framework=...]   — fetch canonical articles for context

env:
  GLANCE_API_URL    (default: https://api.glance-gate.com)
  GLANCE_TOKEN_PATH (default: ~/.glance-gate/token)
  GLANCE_API_TIMEOUT (default: 6 seconds)
  GLANCE_PROJECT_ID (override project id; default: hash of git remote/path)
USAGE
  exit 64
}

require_curl() {
  if ! command -v curl >/dev/null 2>&1; then
    echo "[glance-api] curl is required" >&2
    exit 127
  fi
}

ensure_token() {
  require_curl
  if [ -s "$TOKEN_PATH" ] && [ -s "$KEY_PATH" ]; then
    echo "$TOKEN_PATH + $KEY_PATH already present" >&2
    return 0
  fi
  mkdir -p "$(dirname "$TOKEN_PATH")" "$(dirname "$KEY_PATH")"
  local resp
  if ! resp="$(curl -sS --max-time "$TIMEOUT" -X POST "$API_URL/v1/auth/device" 2>/dev/null)"; then
    echo "[glance-api] could not reach $API_URL — skipping token bootstrap" >&2
    return 0
  fi
  local token enc_key
  token="$(printf '%s' "$resp" | python3 -c "import json, sys; print(json.load(sys.stdin).get('token',''))" 2>/dev/null || true)"
  enc_key="$(printf '%s' "$resp" | python3 -c "import json, sys; print(json.load(sys.stdin).get('encryptionKey',''))" 2>/dev/null || true)"
  if [ -z "$token" ]; then
    echo "[glance-api] auth response had no token: $resp" >&2
    return 0
  fi
  # 0600 — both are bearer credentials
  ( umask 077 && printf '%s' "$token"   > "$TOKEN_PATH" )
  ( umask 077 && printf '%s' "$enc_key" > "$KEY_PATH" )
  echo "wrote token and encryption key to ~/.glance-gate/" >&2
}

# encrypt_payload <plaintext-json-string>
#   prints JSON envelope: {"enc":{"v":1,"iv":...,"ct":...,"mac":...}}
#   uses AES-256-CBC + HMAC-SHA256 (encrypt-then-MAC) over the device's master key.
encrypt_payload() {
  local plain="$1"
  if [ ! -s "$KEY_PATH" ]; then
    echo "[glance-api] no encryption key on disk; falling back to plain body" >&2
    printf '%s' "$plain"
    return 0
  fi
  GLANCE_MASTER_B64="$(cat "$KEY_PATH")" \
  GLANCE_PLAIN="$plain" \
  python3 - <<'PY'
import base64, hashlib, hmac, json, os, secrets, subprocess, sys
master_b64 = os.environ.get("GLANCE_MASTER_B64", "")
plain = os.environ.get("GLANCE_PLAIN", "")
master = base64.b64decode(master_b64)
if len(master) != 32:
    sys.stderr.write("[glance-api] master key wrong size\n")
    print(plain); sys.exit(0)
enc_key = hashlib.sha256(master + b"glance:enc").digest()
mac_key = hashlib.sha256(master + b"glance:mac").digest()
iv = secrets.token_bytes(16)
proc = subprocess.run(
    ["openssl", "enc", "-aes-256-cbc",
     "-K", enc_key.hex(),
     "-iv", iv.hex(),
     "-nosalt"],
    input=plain.encode("utf-8"),
    capture_output=True,
    check=True,
)
ct = proc.stdout
tag = hmac.new(mac_key, iv + ct, hashlib.sha256).digest()
env = {"enc": {
    "v": 1,
    "iv": base64.b64encode(iv).decode(),
    "ct": base64.b64encode(ct).decode(),
    "mac": base64.b64encode(tag).decode(),
}}
print(json.dumps(env))
PY
}

read_token() {
  if [ -s "$TOKEN_PATH" ]; then
    cat "$TOKEN_PATH"
  else
    return 1
  fi
}

cmd_recall() {
  require_curl
  local language="${1:-}"
  shift || true
  if [ -z "$language" ]; then
    echo "[glance-api] recall: language required" >&2
    exit 64
  fi
  local query="language=$language"
  # auto-inject projectId unless caller already passed one
  local has_pid=0
  for kv in "$@"; do
    case "$kv" in
      projectId=*) has_pid=1 ;;
    esac
    query="$query&$kv"
  done
  if [ "$has_pid" -eq 0 ]; then
    local pid
    pid="$(compute_project_id)"
    query="$query&projectId=$pid"
  fi
  local token
  if ! token="$(read_token)"; then
    ensure_token
    if ! token="$(read_token)"; then
      echo '{"error":"no token; api unreachable","matchCount":0,"strategies":[]}' >&2
      return 0
    fi
  fi
  if ! curl -sS --max-time "$TIMEOUT" \
       -H "Authorization: Bearer $token" \
       "$API_URL/v1/recall?$query"; then
    echo "[glance-api] recall failed (network or server)" >&2
    echo '{"error":"unreachable","matchCount":0,"strategies":[]}'
    return 0
  fi
  echo  # trailing newline
}

cmd_record() {
  require_curl
  local body
  # Prefer the positional arg if given. Otherwise read from stdin if it's piped.
  # The previous logic used `[ -t 0 ]` first, which produced an empty body when
  # the caller piped output elsewhere (because stdin then appears non-terminal).
  if [ "$#" -ge 1 ] && [ -n "$1" ]; then
    body="$1"
  elif [ ! -t 0 ]; then
    body="$(cat)"
  else
    echo "[glance-api] record: pass JSON via stdin or as the first arg" >&2
    exit 64
  fi
  # Auto-inject projectId if the body doesn't already have one.
  if ! printf '%s' "$body" | grep -q '"projectId"'; then
    local pid
    pid="$(compute_project_id)"
    # Inject `,"projectId":"…"` before the closing brace. Resilient to whitespace.
    body="$(printf '%s' "$body" | python3 -c "
import sys, json
b = json.load(sys.stdin)
b['projectId'] = '$pid'
print(json.dumps(b))
")"
  fi
  local token
  if ! token="$(read_token)"; then
    ensure_token
    if ! token="$(read_token)"; then
      echo '{"error":"no token; record skipped"}' >&2
      return 0
    fi
  fi
  if ! curl -sS --max-time "$TIMEOUT" \
       -X POST \
       -H "Authorization: Bearer $token" \
       -H 'Content-Type: application/json' \
       --data "$body" \
       "$API_URL/v1/record"; then
    echo "[glance-api] record failed (network or server)" >&2
    echo '{"error":"unreachable","recorded":false}'
    return 0
  fi
  echo
}

cmd_run() {
  require_curl
  local body
  if [ "$#" -ge 1 ] && [ -n "$1" ]; then
    body="$1"
  elif [ ! -t 0 ]; then
    body="$(cat)"
  else
    echo "[glance-api] run: pass JSON via stdin or as the first arg" >&2
    exit 64
  fi
  # Auto-inject projectId if the body doesn't already have one.
  if ! printf '%s' "$body" | grep -q '"projectId"'; then
    local pid
    pid="$(compute_project_id)"
    body="$(printf '%s' "$body" | python3 -c "
import sys, json
b = json.load(sys.stdin)
b['projectId'] = '$pid'
print(json.dumps(b))
")"
  fi
  local token
  if ! token="$(read_token)"; then
    ensure_token
    if ! token="$(read_token)"; then
      echo '{"error":"no token; run skipped"}' >&2
      return 0
    fi
  fi
  if ! curl -sS --max-time "$TIMEOUT" \
       -X POST \
       -H "Authorization: Bearer $token" \
       -H 'Content-Type: application/json' \
       --data "$body" \
       "$API_URL/v1/run"; then
    echo "[glance-api] run failed (network or server)" >&2
    echo '{"error":"unreachable","recorded":false}'
    return 0
  fi
  echo
}

cmd_articles_submit() {
  require_curl
  local body
  if [ "$#" -ge 1 ] && [ -n "$1" ]; then
    body="$1"
  elif [ ! -t 0 ]; then
    body="$(cat)"
  else
    echo "[glance-api] articles submit: pass JSON via stdin or first arg" >&2
    exit 64
  fi
  # Auto-inject projectId if not in body.
  if ! printf '%s' "$body" | grep -q '"projectId"'; then
    local pid
    pid="$(compute_project_id)"
    body="$(GLANCE_BODY="$body" GLANCE_PID="$pid" python3 -c '
import json, os
b = json.loads(os.environ["GLANCE_BODY"])
b["projectId"] = os.environ["GLANCE_PID"]
print(json.dumps(b))')"
  fi
  local token
  if ! token="$(read_token)"; then
    ensure_token
    if ! token="$(read_token)"; then
      echo '{"error":"no token; articles submit skipped"}' >&2
      return 0
    fi
  fi
  # Encrypt the payload before sending.
  local envelope
  envelope="$(encrypt_payload "$body")"
  if ! curl -sS --max-time "$TIMEOUT" \
       -X POST \
       -H "Authorization: Bearer $token" \
       -H 'Content-Type: application/json' \
       --data "$envelope" \
       "$API_URL/v1/articles"; then
    echo "[glance-api] articles submit failed" >&2
    echo '{"error":"unreachable","submitted":0}'
    return 0
  fi
  echo
}

cmd_articles_get() {
  require_curl
  local language="${1:-}"
  shift || true
  if [ -z "$language" ]; then
    echo "[glance-api] articles get: language required" >&2
    exit 64
  fi
  local query="language=$language"
  local has_pid=0
  for kv in "$@"; do
    case "$kv" in projectId=*) has_pid=1 ;; esac
    query="$query&$kv"
  done
  if [ "$has_pid" -eq 0 ]; then
    local pid
    pid="$(compute_project_id)"
    query="$query&projectId=$pid"
  fi
  local token
  if ! token="$(read_token)"; then
    ensure_token
    if ! token="$(read_token)"; then
      echo '{"error":"no token","articles":{}}' >&2
      return 0
    fi
  fi
  if ! curl -sS --max-time "$TIMEOUT" \
       -H "Authorization: Bearer $token" \
       "$API_URL/v1/articles?$query"; then
    echo "[glance-api] articles get failed" >&2
    echo '{"error":"unreachable","articles":{}}'
    return 0
  fi
  echo
}

cmd_articles() {
  local sub="${1:-}"
  shift || true
  case "$sub" in
    submit) cmd_articles_submit "$@" ;;
    get)    cmd_articles_get "$@" ;;
    *)      echo "[glance-api] articles {submit|get}" >&2; exit 64 ;;
  esac
}

main() {
  local sub="${1:-}"
  shift || true
  case "$sub" in
    ensure-token) ensure_token ;;
    recall)       cmd_recall "$@" ;;
    run)          cmd_run "$@" ;;
    record)       cmd_record "$@" ;;
    articles)     cmd_articles "$@" ;;
    -h|--help|help|"") usage ;;
    *) echo "[glance-api] unknown subcommand: $sub" >&2; usage ;;
  esac
}

main "$@"
