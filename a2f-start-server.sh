#!/usr/bin/env bash
set -eu

log() {
  printf '[a2f-entrypoint] %s\n' "$*" >&2
}

wait_for_a2f_ready() {
  local timeout="${A2F_READY_TIMEOUT_SEC:-3600}"
  local deadline=$((SECONDS + timeout))
  local http_url="${A2F_HTTP_READY_URL:-http://127.0.0.1:8000/v1/health/ready}"
  local grpc_host="${A2F_GRPC_HOST:-127.0.0.1}"
  local grpc_port="${A2F_GRPC_PORT:-52000}"
  local last_wait_log=0

  log "waiting for A2F before starting PyWorker: http=${http_url} grpc=${grpc_host}:${grpc_port} timeout=${timeout}s"
  while (( SECONDS < deadline )); do
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
      return 0
    fi
    if (( SECONDS - last_wait_log >= 60 )); then
      log "still waiting for A2F readiness after ${SECONDS}s"
      last_wait_log=$SECONDS
    fi
    sleep "${A2F_READY_POLL_SEC:-5}"
  done

  log "timed out waiting for A2F readiness"
  return 70
}

start_pyworker_after_a2f_boot() {
  local delay="${A2F_PYWORKER_START_DELAY_SEC:-45}"
  log "delaying PyWorker watcher for ${delay}s so NVIDIA A2F boots untouched"
  sleep "$delay"

  wait_for_a2f_ready || exit $?
  log "A2F is ready; installing PyWorker dependencies"
  python3 -m pip install --no-cache-dir --index-url https://pypi.org/simple \
    --target /tmp/pyworker-deps -r /app/requirements.txt
  log "starting Vast PyWorker"
  env \
    WORKER_PORT="${WORKER_PORT:-18000}" \
    PYWORKER_MODEL_SERVER_PORT="${PYWORKER_MODEL_SERVER_PORT:-18000}" \
    PYWORKER_MODEL_SERVER_URL="${PYWORKER_MODEL_SERVER_URL:-http://127.0.0.1}" \
    PYWORKER_MODEL_LOG_FILE="${PYWORKER_MODEL_LOG_FILE:-/var/log/portal/a2f-pyworker.log}" \
    PYTHONPATH="/tmp/pyworker-deps:${PYTHONPATH:-}" \
    python3 /app/worker.py
}

log "stock /opt/nim/start_server.sh path active build=${A2F_WRAPPER_BUILD:-unknown} cwd=$(pwd) LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-} PYTHONPATH=${PYTHONPATH:-}"
start_pyworker_after_a2f_boot &

# This is the stock NVIDIA /opt/nim/start_server.sh behavior.
start_server
