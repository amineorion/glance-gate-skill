#!/usr/bin/env bash
# smoke-test.sh — verify a built image actually starts AND serves traffic.
#
# Required by every glance-gate tier before declaring the build successful.
# A Dockerfile that builds and scans clean but returns 5xx on the first
# request is worse than the original. This script does more than "did
# the container stay up for N seconds":
#
#   - boots the container with a configurable env, optionally on a
#     docker network alongside a Mongo / Postgres / Redis sidecar
#   - sends one or more HTTP probes (`--probe PATH=STATUS`) against
#     the published port and verifies the status code
#   - confirms the process is running as a non-root uid
#   - sends SIGTERM and verifies clean shutdown within a deadline
#   - captures container + sidecar logs to disk for the report
#
# Usage:
#   ./scripts/smoke-test.sh <image> [options]
#
# Common options:
#   --wait <seconds>         settle time before probes (default: 5)
#   --container-port <N>     port inside container (default: from EXPOSE)
#   --probe PATH=STATUS      repeatable; e.g. --probe /api/ping=200
#                            --probe /nonexistent=404
#   --env KEY=VALUE          repeatable; passed to docker run -e
#   --env-file <path>        also passed to docker run --env-file
#   --with-db mongo|postgres|redis
#                            spin up a sidecar on a private network and
#                            inject DATABASE / DATABASE_URL / REDIS_URL.
#                            sidecar name resolves via docker DNS:
#                              mongo://glance-mongo:27017
#                              postgres://glance-postgres:5432
#                              redis://glance-redis:6379
#   --user-check <uid>       confirm `id -u` inside container matches uid
#   --sigterm-deadline <s>   max seconds for graceful SIGTERM exit (default 15)
#   --log <file>             where to write captured logs (default: smoke-<tag>.log)
#
# Exit codes:
#   0  — all checks passed
#   1  — container did not start
#   2  — HTTP probe failed
#   3  — non-root user check failed
#   4  — SIGTERM did not exit cleanly within the deadline
#   64 — bad usage
#   127 — docker not installed
#
# Last line of stdout is always a one-line verdict the orchestrator parses:
#   SMOKE=PASS  image=<tag>  probes=<n>  shutdown_ms=<ms>  uid=<uid>
#   SMOKE=FAIL  reason="<short>"  image=<tag>  log=<file>

set -uo pipefail

IMAGE="${1:-}"
shift || true
if [[ -z "$IMAGE" ]]; then
  cat >&2 <<USAGE
Usage: $0 <image> [options]

Options:
  --wait N                  settle time before probes (default 5)
  --container-port N        port inside container (default: from EXPOSE)
  --probe PATH=STATUS       repeatable HTTP probe
  --env KEY=VALUE           repeatable
  --env-file PATH           passed to docker run
  --with-db mongo|postgres|redis    sidecar DB on a private network
  --user-check UID          confirm container process runs as UID
  --sigterm-deadline N      max graceful-exit seconds (default 15)
  --log PATH                captured logs (default: smoke-<tag>.log)

Last line of stdout:
  SMOKE=PASS  image=<tag>  probes=<n>  shutdown_ms=<ms>  uid=<uid>
  SMOKE=FAIL  reason="<short>"  image=<tag>  log=<file>
USAGE
  exit 64
fi

WAIT_SECONDS=5
CONTAINER_PORT=""
PROBES=()
ENVS=()
ENV_FILE=""
WITH_DB=""
USER_CHECK=""
SIGTERM_DEADLINE=15
LOG_FILE="smoke-${IMAGE//\//_}.log"
LOG_FILE="${LOG_FILE//:/_}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --wait)              WAIT_SECONDS="$2"; shift 2 ;;
    --container-port)    CONTAINER_PORT="$2"; shift 2 ;;
    --probe)             PROBES+=("$2"); shift 2 ;;
    --env)               ENVS+=("-e" "$2"); shift 2 ;;
    --env-file)          ENV_FILE="$2"; shift 2 ;;
    --with-db)           WITH_DB="$2"; shift 2 ;;
    --user-check)        USER_CHECK="$2"; shift 2 ;;
    --sigterm-deadline)  SIGTERM_DEADLINE="$2"; shift 2 ;;
    --log)               LOG_FILE="$2"; shift 2 ;;
    *)                   echo "[smoke] unknown flag: $1" >&2; exit 64 ;;
  esac
done

if ! command -v docker >/dev/null 2>&1; then
  echo "[smoke] docker not in PATH" >&2
  exit 127
fi
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "[smoke] image not found: $IMAGE" >&2
  echo "SMOKE=FAIL  reason=\"image not built\"  image=$IMAGE"
  exit 1
fi

# Auto-detect container port from EXPOSE if caller didn't say.
if [[ -z "$CONTAINER_PORT" ]]; then
  CONTAINER_PORT="$(docker image inspect "$IMAGE" \
    --format '{{range $p, $_ := .Config.ExposedPorts}}{{println $p}}{{end}}' \
    | head -1 | sed 's|/.*||' || true)"
fi

# Sidecar networking. When --with-db is set, both containers share a
# user-defined bridge so `mongo://glance-mongo:27017` etc. resolve.
NET_FLAG=()
SIDECAR=""
NETWORK_NAME=""
if [[ -n "$WITH_DB" ]]; then
  NETWORK_NAME="glance-smoke-$$"
  docker network create "$NETWORK_NAME" >/dev/null 2>&1 || true
  NET_FLAG=(--network "$NETWORK_NAME")
  case "$WITH_DB" in
    mongo)
      SIDECAR="glance-mongo"
      docker run -d --rm --name "$SIDECAR" --network "$NETWORK_NAME" mongo:7 >/dev/null 2>&1
      ENVS+=("-e" "DATABASE=mongodb://$SIDECAR:27017/glance_smoke")
      ENVS+=("-e" "MONGO_URL=mongodb://$SIDECAR:27017/glance_smoke")
      ENVS+=("-e" "MONGODB_URI=mongodb://$SIDECAR:27017/glance_smoke")
      ;;
    postgres)
      SIDECAR="glance-postgres"
      docker run -d --rm --name "$SIDECAR" --network "$NETWORK_NAME" \
        -e POSTGRES_PASSWORD=smoke -e POSTGRES_DB=glance_smoke postgres:16-alpine >/dev/null 2>&1
      ENVS+=("-e" "DATABASE_URL=postgres://postgres:smoke@$SIDECAR:5432/glance_smoke")
      ;;
    redis)
      SIDECAR="glance-redis"
      docker run -d --rm --name "$SIDECAR" --network "$NETWORK_NAME" redis:7-alpine >/dev/null 2>&1
      ENVS+=("-e" "REDIS_URL=redis://$SIDECAR:6379")
      ;;
    *) echo "[smoke] unsupported --with-db: $WITH_DB" >&2; exit 64 ;;
  esac
  # Give the sidecar a moment to accept connections.
  sleep 4
fi

PORT_FLAG=()
if [[ -n "$CONTAINER_PORT" ]]; then
  PORT_FLAG=(-p "${CONTAINER_PORT}")
fi

CONTAINER_NAME="glance-smoke-app-$$"
echo "[smoke] image            : $IMAGE"
echo "[smoke] container        : $CONTAINER_NAME"
echo "[smoke] container port   : ${CONTAINER_PORT:-<none exposed>}"
echo "[smoke] sidecar          : ${SIDECAR:-<none>}"
echo "[smoke] probes           : ${#PROBES[@]}"
echo "[smoke] log              : $LOG_FILE"

cleanup() {
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  [[ -n "$SIDECAR" ]] && docker rm -f "$SIDECAR" >/dev/null 2>&1 || true
  [[ -n "$NETWORK_NAME" ]] && docker network rm "$NETWORK_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Launch app.
RUN_ARGS=(-d --name "$CONTAINER_NAME" "${NET_FLAG[@]}" "${ENVS[@]}" "${PORT_FLAG[@]}")
[[ -n "$ENV_FILE" ]] && RUN_ARGS+=(--env-file "$ENV_FILE")
RUN_ARGS+=("$IMAGE")

if ! docker run "${RUN_ARGS[@]}" >/dev/null; then
  echo "[smoke] docker run rejected" >&2
  echo "SMOKE=FAIL  reason=\"docker run rejected\"  image=$IMAGE"
  exit 1
fi

# Capture rolling logs.
docker logs -f "$CONTAINER_NAME" >"$LOG_FILE" 2>&1 &
LOGGER_PID=$!

# Wait the settle window, then verify still alive.
sleep "$WAIT_SECONDS"

if ! docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null | grep -q true; then
  EXIT_CODE="$(docker inspect -f '{{.State.ExitCode}}' "$CONTAINER_NAME" 2>/dev/null || echo '?')"
  echo "[smoke] container exited during wait window (exit=$EXIT_CODE)" >&2
  tail -30 "$LOG_FILE" >&2 || true
  kill "$LOGGER_PID" 2>/dev/null || true
  echo "SMOKE=FAIL  reason=\"container exited\"  exit_code=$EXIT_CODE  image=$IMAGE  log=$LOG_FILE"
  exit 1
fi

# Optional: confirm process uid.
if [[ -n "$USER_CHECK" ]]; then
  ACTUAL_UID="$(docker exec "$CONTAINER_NAME" id -u 2>/dev/null || echo unknown)"
  if [[ "$ACTUAL_UID" != "$USER_CHECK" ]]; then
    echo "[smoke] uid mismatch: container=$ACTUAL_UID expected=$USER_CHECK" >&2
    kill "$LOGGER_PID" 2>/dev/null || true
    echo "SMOKE=FAIL  reason=\"uid $ACTUAL_UID != $USER_CHECK\"  image=$IMAGE  log=$LOG_FILE"
    exit 3
  fi
fi

# Resolve the host-bound port for HTTP probes.
HOST_BOUND_PORT=""
if [[ -n "$CONTAINER_PORT" ]]; then
  HOST_BOUND_PORT="$(docker port "$CONTAINER_NAME" "$CONTAINER_PORT" 2>/dev/null | head -1 | awk -F: '{print $NF}')"
fi

# Run probes.
PROBE_COUNT="${#PROBES[@]}"
PROBE_PASSED=0
for probe in "${PROBES[@]}"; do
  PATH_PART="${probe%%=*}"
  EXPECT_PART="${probe##*=}"
  if [[ -z "$HOST_BOUND_PORT" ]]; then
    echo "[smoke] cannot probe $PATH_PART — no container port published" >&2
    kill "$LOGGER_PID" 2>/dev/null || true
    echo "SMOKE=FAIL  reason=\"no host port for probes\"  image=$IMAGE  log=$LOG_FILE"
    exit 2
  fi
  URL="http://127.0.0.1:${HOST_BOUND_PORT}${PATH_PART}"
  ACTUAL="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$URL" || echo 000)"
  if [[ "$ACTUAL" != "$EXPECT_PART" ]]; then
    echo "[smoke] probe FAIL: $PATH_PART got $ACTUAL, expected $EXPECT_PART" >&2
    tail -20 "$LOG_FILE" >&2 || true
    kill "$LOGGER_PID" 2>/dev/null || true
    echo "SMOKE=FAIL  reason=\"probe $PATH_PART $ACTUAL!=$EXPECT_PART\"  image=$IMAGE  log=$LOG_FILE"
    exit 2
  fi
  echo "[smoke] probe PASS: $PATH_PART => $ACTUAL"
  PROBE_PASSED=$((PROBE_PASSED + 1))
done

# Graceful SIGTERM.
SHUTDOWN_MS=""
if [[ "$SIGTERM_DEADLINE" -gt 0 ]]; then
  START_NS="$(date +%s%N)"
  docker kill --signal=SIGTERM "$CONTAINER_NAME" >/dev/null 2>&1 || true
  for ((i = 0; i < SIGTERM_DEADLINE; i++)); do
    running="$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null || echo gone)"
    if [[ "$running" != "true" ]]; then break; fi
    sleep 1
  done
  END_NS="$(date +%s%N)"
  SHUTDOWN_MS=$(( (END_NS - START_NS) / 1000000 ))
  running="$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null || echo gone)"
  if [[ "$running" == "true" ]]; then
    echo "[smoke] SIGTERM ignored — container still running after ${SIGTERM_DEADLINE}s" >&2
    kill "$LOGGER_PID" 2>/dev/null || true
    echo "SMOKE=FAIL  reason=\"SIGTERM timeout\"  image=$IMAGE  log=$LOG_FILE"
    exit 4
  fi
  EXIT_CODE="$(docker inspect -f '{{.State.ExitCode}}' "$CONTAINER_NAME" 2>/dev/null || echo 0)"
  echo "[smoke] SIGTERM clean exit: ${SHUTDOWN_MS}ms (exit=$EXIT_CODE)"
fi

kill "$LOGGER_PID" 2>/dev/null || true
ACTUAL_UID_OUT="${USER_CHECK:-?}"
echo "[smoke] PASS"
echo "SMOKE=PASS  image=$IMAGE  probes=$PROBE_PASSED  shutdown_ms=${SHUTDOWN_MS:-skipped}  uid=$ACTUAL_UID_OUT  log=$LOG_FILE"
exit 0
