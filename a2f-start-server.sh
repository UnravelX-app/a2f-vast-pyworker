#!/usr/bin/env bash
set -eu

log() {
  printf '[a2f-entrypoint] %s\n' "$*" >&2
}

dump_a2f_diagnostics() {
  python3 - <<'PYDIAG' >&2 || log "diagnostic snapshot failed"
import os
import socket

KEYWORDS = ("start_server", "a2f", "audio2face", "nim", "grpc", "python")
INTERESTING_PORTS = {8000, 52000, 18000}
TCP_STATES = {
    "01": "ESTABLISHED",
    "02": "SYN_SENT",
    "03": "SYN_RECV",
    "04": "FIN_WAIT1",
    "05": "FIN_WAIT2",
    "06": "TIME_WAIT",
    "07": "CLOSE",
    "08": "CLOSE_WAIT",
    "09": "LAST_ACK",
    "0A": "LISTEN",
}


def read_text(path):
    try:
        with open(path, "rb") as fh:
            return fh.read()
    except OSError:
        return b""


def process_rows():
    rows = []
    for name in os.listdir("/proc"):
        if not name.isdigit():
            continue
        pid = int(name)
        cmd = read_text(f"/proc/{pid}/cmdline").replace(b"\0", b" ").decode("utf-8", "replace").strip()
        comm = read_text(f"/proc/{pid}/comm").decode("utf-8", "replace").strip()
        haystack = f"{comm} {cmd}".lower()
        if any(keyword in haystack for keyword in KEYWORDS):
            rows.append((pid, comm, cmd or comm))
    return sorted(rows)


def socket_owners():
    owners = {}
    for name in os.listdir("/proc"):
        if not name.isdigit():
            continue
        pid = int(name)
        comm = read_text(f"/proc/{pid}/comm").decode("utf-8", "replace").strip()
        fd_dir = f"/proc/{pid}/fd"
        try:
            fds = os.listdir(fd_dir)
        except OSError:
            continue
        for fd in fds:
            try:
                target = os.readlink(f"{fd_dir}/{fd}")
            except OSError:
                continue
            if target.startswith("socket:[") and target.endswith("]"):
                inode = target[8:-1]
                owners.setdefault(inode, set()).add(f"{pid}/{comm}")
    return owners


def decode_ipv4(hex_addr):
    try:
        return socket.inet_ntop(socket.AF_INET, bytes.fromhex(hex_addr)[::-1])
    except OSError:
        return hex_addr


def tcp_rows(path, family, owners):
    rows = []
    try:
        with open(path, "r", encoding="utf-8") as fh:
            lines = fh.readlines()[1:]
    except OSError:
        return rows
    for line in lines:
        fields = line.split()
        if len(fields) < 10:
            continue
        local, state, inode = fields[1], fields[3], fields[9]
        addr_hex, port_hex = local.split(":")
        port = int(port_hex, 16)
        if state != "0A" and port not in INTERESTING_PORTS:
            continue
        if family == "tcp4":
            addr = decode_ipv4(addr_hex)
        else:
            addr = addr_hex
        owner = ",".join(sorted(owners.get(inode, ()))) or "-"
        rows.append((port, family, addr, TCP_STATES.get(state, state), owner))
    return rows


print("diagnostic: process snapshot")
rows = process_rows()
if rows:
    for pid, comm, cmd in rows:
        print(f"  pid={pid} comm={comm} cmd={cmd[:260]}")
else:
    print("  no matching A2F/NIM/gRPC/python processes found")

print("diagnostic: listening tcp ports")
owners = socket_owners()
rows = tcp_rows("/proc/net/tcp", "tcp4", owners) + tcp_rows("/proc/net/tcp6", "tcp6", owners)
if rows:
    for port, family, addr, state, owner in sorted(rows):
        marker = " *" if port in INTERESTING_PORTS else ""
        print(f"  {family} {addr}:{port} {state} owner={owner}{marker}")
else:
    print("  no tcp listeners found")
PYDIAG
}

wait_for_a2f_ready() {
  local timeout="${A2F_READY_TIMEOUT_SEC:-3600}"
  local deadline=$((SECONDS + timeout))
  local grpc_host="${A2F_GRPC_HOST:-127.0.0.1}"
  local grpc_port="${A2F_GRPC_PORT:-52000}"
  local last_wait_log=0

  log "waiting for A2F gRPC before starting PyWorker: grpc=${grpc_host}:${grpc_port} timeout=${timeout}s"
  while (( SECONDS < deadline )); do
    if python3 - "$grpc_host" "$grpc_port" <<'PYREADY' >/dev/null 2>&1
import socket, sys
host, port = sys.argv[1], int(sys.argv[2])
with socket.create_connection((host, port), timeout=2):
    pass
PYREADY
    then
      return 0
    fi
    if (( SECONDS - last_wait_log >= 60 )); then
      log "still waiting for A2F readiness after ${SECONDS}s"
      dump_a2f_diagnostics
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

start_native_a2f_pipeline() {
  local delay="${A2F_NATIVE_START_DELAY_SEC:-0}"
  if [ "$delay" != "0" ]; then
    log "delaying native A2F pipeline for ${delay}s"
    sleep "$delay"
  fi

  log "starting NVIDIA native A2F pipeline: /usr/local/bin/a2f_pipeline.run"
  exec /usr/local/bin/a2f_pipeline.run \
    --deployment-config /apps/configs/deployment_config.yaml \
    --stylization-config /apps/configs/stylization_config.yaml \
    --advanced-config /apps/configs/advanced_config.yaml
}

log "wrapper active build=${A2F_WRAPPER_BUILD:-unknown} cwd=$(pwd) LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-} PYTHONPATH=${PYTHONPATH:-}"
export NIM_USE_MODEL_MANIFEST_V0=False
log "forcing NIM_USE_MODEL_MANIFEST_V0=${NIM_USE_MODEL_MANIFEST_V0}"

terminate_children() {
  log "received shutdown; stopping child processes"
  kill "${pyworker_pid:-}" "${nim_pid:-}" "${a2f_pid:-}" 2>/dev/null || true
}

trap terminate_children INT TERM

start_pyworker_after_a2f_boot &
pyworker_pid=$!

log "starting NVIDIA A2F startup script unchanged: /opt/nim/start_server.sh"
/opt/nim/start_server.sh &
nim_pid=$!

start_native_a2f_pipeline &
a2f_pid=$!

while true; do
  if ! kill -0 "$nim_pid" 2>/dev/null; then
    set +e
    wait "$nim_pid"
    status=$?
    set -e
    log "NVIDIA NIM startup script exited status=${status}"
    kill "$pyworker_pid" "$a2f_pid" 2>/dev/null || true
    exit "$status"
  fi

  if ! kill -0 "$a2f_pid" 2>/dev/null; then
    set +e
    wait "$a2f_pid"
    status=$?
    set -e
    log "NVIDIA native A2F pipeline exited status=${status}"
    kill "$pyworker_pid" "$nim_pid" 2>/dev/null || true
    exit "$status"
  fi

  if ! kill -0 "$pyworker_pid" 2>/dev/null; then
    set +e
    wait "$pyworker_pid"
    status=$?
    set -e
    log "PyWorker watcher exited status=${status}"
    kill "$nim_pid" "$a2f_pid" 2>/dev/null || true
    exit "$status"
  fi

  sleep 2
done
