#!/usr/bin/env bash
set -eu

log() {
  printf '[a2f-entrypoint] %s\n' "$*" >&2
}

wait_for_a2f_ready() {
  local timeout="${A2F_READY_TIMEOUT_SEC:-3600}"
  local deadline=$((SECONDS + timeout))
  local http_url="${A2F_HTTP_READY_URL:-http://127.0.0.1:8000/v1/health/ready}"

  log "waiting for A2F HTTP readiness: url=${http_url} timeout=${timeout}s"
  while (( SECONDS < deadline )); do
    if python3 - "$http_url" <<'PYREADY' >/dev/null 2>&1
import sys, urllib.request
with urllib.request.urlopen(sys.argv[1], timeout=2) as resp:
    if resp.status < 200 or resp.status >= 300:
        raise SystemExit(1)
PYREADY
    then
      return 0
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
    PYWORKER_MODEL_SERVER_PORT="18002" \
    PYWORKER_MODEL_SERVER_URL="http://127.0.0.1" \
    PYWORKER_MODEL_LOG_FILE="${PYWORKER_MODEL_LOG_FILE:-/var/log/portal/a2f-pyworker.log}" \
    PYTHONPATH="/tmp/pyworker-deps:${PYTHONPATH:-}" \
    python3 /app/worker.py
}

log "wrapper active build=${A2F_WRAPPER_BUILD:-unknown}"

if [ "${NIM_SKIP_A2F_START:-}" = "true" ] || [ "${NIM_SKIP_A2F_START:-}" = "1" ]; then
  unset NIM_SKIP_A2F_START
fi

start_pyworker_after_a2f_boot &

export SERVER_START_SCRIPT_PATH="${SERVER_START_SCRIPT_PATH:-/opt/nim/start_server.sh}"
log "exec NVIDIA A2F startup: /bin/bash -c ${SERVER_START_SCRIPT_PATH}"
exec /bin/bash -c "$SERVER_START_SCRIPT_PATH"
