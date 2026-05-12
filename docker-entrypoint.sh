#!/usr/bin/env bash
set -Eeuo pipefail

log() {
  printf '[a2f-entrypoint] %s\n' "$*" >&2
}

log_runtime() {
  log "runtime env: build=${A2F_WRAPPER_BUILD:-unknown} cwd=$(pwd) LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-} PYTHONPATH=${PYTHONPATH:-} CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES:-}"
  if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi -L >&2 || true
    nvidia-smi --query-gpu=name,pci.device_id,memory.total,driver_version --format=csv,noheader >&2 || true
  else
    log "nvidia-smi not found"
  fi
}

log_runtime

mkdir -p "$(dirname "${PYWORKER_MODEL_LOG_FILE:-/var/log/portal/a2f-pyworker.log}")" /workspace/a2f-cache

warm_gstreamer_registry() {
  mkdir -p /tmp/xdg-runtime-root /tmp/gstreamer-cache
  chmod 700 /tmp/xdg-runtime-root || true
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/xdg-runtime-root}"
  export GST_REGISTRY="${GST_REGISTRY:-/tmp/gstreamer-cache/registry.bin}"
  export GST_PLUGIN_SCANNER="${GST_PLUGIN_SCANNER:-/usr/lib/x86_64-linux-gnu/gstreamer1.0/gstreamer-1.0/gst-plugin-scanner}"

  local attempts="${GST_WARMUP_ATTEMPTS:-6}"
  local i=1
  while (( i <= attempts )); do
    log "warming GStreamer registry attempt ${i}/${attempts}: GST_REGISTRY=${GST_REGISTRY} GST_PLUGIN_SCANNER=${GST_PLUGIN_SCANNER}"
    if gst-inspect-1.0 --version >/dev/null 2>&1; then
      log "GStreamer registry warm-up succeeded"
      return 0
    fi
    log "GStreamer registry warm-up failed; retrying"
    rm -f "$GST_REGISTRY"
    sleep 2
    i=$((i + 1))
  done

  log "GStreamer registry warm-up failed after ${attempts} attempts"
  return 1
}

warm_gstreamer_registry

wait_for_a2f_ready() {
  local timeout="${A2F_READY_TIMEOUT_SEC:-3600}"
  local deadline=$((SECONDS + timeout))
  local http_url="${A2F_HTTP_READY_URL:-http://127.0.0.1:8000/v1/health/ready}"
  local grpc_host="${A2F_GRPC_HOST:-127.0.0.1}"
  local grpc_port="${A2F_GRPC_PORT:-52000}"

  log "waiting for A2F before starting PyWorker: http=${http_url} grpc=${grpc_host}:${grpc_port} timeout=${timeout}s"
  local last_wait_log=0
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
      log "A2F is ready; starting Vast PyWorker"
      return 0
    fi
    if (( SECONDS - last_wait_log >= 60 )); then
      log "still waiting for A2F readiness after ${SECONDS}s"
      last_wait_log=$SECONDS
    fi
    sleep "${A2F_READY_POLL_SEC:-5}"
  done

  log "timed out waiting for A2F readiness"
  exit 70
}

start_pyworker_when_ready() {
  wait_for_a2f_ready
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

start_pyworker_when_ready &
PYWORKER_WATCHER_PID=$!

if [[ -n "${SERVER_START_SCRIPT_PATH:-}" ]]; then
  log "exec stock NVIDIA A2F start script build=${A2F_WRAPPER_BUILD:-unknown} script=${SERVER_START_SCRIPT_PATH} cwd=$(pwd)"
  unset GST_REGISTRY GST_REGISTRY_FORK GST_PLUGIN_SCANNER GST_DEBUG
  exec /bin/bash -c "$SERVER_START_SCRIPT_PATH"
elif [[ "$#" -gt 0 ]]; then
  log "exec A2F using container args: $*"
  exec "$@"
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
