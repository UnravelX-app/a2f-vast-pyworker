#!/usr/bin/env bash
set -Eeuo pipefail

log() {
  printf '[a2f-entrypoint] %s\n' "$*" >&2
}

shutdown() {
  log "shutdown requested"
  if [[ -n "${PYWORKER_PID:-}" ]] && kill -0 "$PYWORKER_PID" 2>/dev/null; then
    kill "$PYWORKER_PID" 2>/dev/null || true
  fi
  if [[ -n "${A2F_PID:-}" ]] && kill -0 "$A2F_PID" 2>/dev/null; then
    kill "$A2F_PID" 2>/dev/null || true
    wait "$A2F_PID" 2>/dev/null || true
  fi
}
trap shutdown TERM INT

mkdir -p "$(dirname "${PYWORKER_MODEL_LOG_FILE:-/var/log/portal/a2f-pyworker.log}")" /workspace/a2f-cache

# Start A2F NIM. There are two supported modes:
# 1. Set A2F_START_CMD to the original NVIDIA command after inspecting the base image.
# 2. Pass a command as container args; docker-entrypoint will run those args as A2F.
#
# Example A2F_START_CMD value after inspection:
#   A2F_START_CMD='python3 -m inference'
if [[ -n "${A2F_START_CMD:-}" ]]; then
  log "starting A2F using A2F_START_CMD"
  bash -lc "$A2F_START_CMD" &
  A2F_PID=$!
elif [[ "$#" -gt 0 ]]; then
  log "starting A2F using container args: $*"
  "$@" &
  A2F_PID=$!
else
  cat >&2 <<'EOF'
[a2f-entrypoint] ERROR: no A2F startup command configured.
[a2f-entrypoint]
[a2f-entrypoint] Set A2F_START_CMD to the NVIDIA base image command, or pass the
[a2f-entrypoint] command as Docker ENTRYPOINT args.
[a2f-entrypoint]
[a2f-entrypoint] Find it with:
[a2f-entrypoint]   docker inspect nvcr.io/nim/nvidia/audio2face-3d:1.3.16 \
[a2f-entrypoint]     --format '{{json .Config.Entrypoint}} {{json .Config.Cmd}}'
EOF
  exit 64
fi

wait_for_a2f_ready() {
  local timeout="${A2F_READY_TIMEOUT_SEC:-3600}"
  local deadline=$((SECONDS + timeout))
  local http_url="${A2F_HTTP_READY_URL:-http://127.0.0.1:8000/v1/health/ready}"
  local grpc_host="${A2F_GRPC_HOST:-127.0.0.1}"
  local grpc_port="${A2F_GRPC_PORT:-52000}"

  log "waiting for A2F before starting PyWorker: http=${http_url} grpc=${grpc_host}:${grpc_port} timeout=${timeout}s"
  while (( SECONDS < deadline )); do
    if ! kill -0 "$A2F_PID" 2>/dev/null; then
      wait "$A2F_PID"
      local status=$?
      log "A2F exited during startup with status ${status}"
      exit "$status"
    fi

    if python3 - "$http_url" "$grpc_host" "$grpc_port" <<'PYREADY' >/dev/null 2>&1
import socket, sys, urllib.request
url, host, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
with urllib.request.urlopen(url, timeout=2) as resp:
    if resp.status < 200 or resp.status >= 300:
        raise SystemExit(1)
with socket.create_connection((host, port), timeout=2):
    pass
PYREADY
    then
      log "A2F is ready; starting Vast PyWorker"
      return 0
    fi
    sleep "${A2F_READY_POLL_SEC:-5}"
  done

  log "timed out waiting for A2F readiness"
  exit 70
}

wait_for_a2f_ready
python3 /app/worker.py &
PYWORKER_PID=$!

# Keep the wrapper alive while either process is alive. If one exits, stop the
# other and return the failing process exit code where possible.
set +e
while true; do
  if ! kill -0 "$A2F_PID" 2>/dev/null; then
    wait "$A2F_PID"
    status=$?
    log "A2F process exited with status ${status}"
    kill "$PYWORKER_PID" 2>/dev/null || true
    wait "$PYWORKER_PID" 2>/dev/null || true
    exit "$status"
  fi
  if ! kill -0 "$PYWORKER_PID" 2>/dev/null; then
    wait "$PYWORKER_PID"
    status=$?
    log "PyWorker process exited with status ${status}"
    kill "$A2F_PID" 2>/dev/null || true
    wait "$A2F_PID" 2>/dev/null || true
    exit "$status"
  fi
  sleep 2
done
