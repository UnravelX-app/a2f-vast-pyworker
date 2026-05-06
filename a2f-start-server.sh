#!/usr/bin/env bash
set -eu

log() {
  printf '[a2f-entrypoint] %s\n' "$*" >&2
}

dump_a2f_diagnostics() {
  python3 - <<'PYDIAG' >&2 || log "diagnostic snapshot failed"
import os
import socket

KEYWORDS = ("start_server", "a2f", "audio2face", "nim", "grpc", "python", "triton")
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
    print("  no matching A2F/NIM/gRPC/python/triton processes found")

print("diagnostic: listening tcp ports")
owners = socket_owners()
rows = tcp_rows("/proc/net/tcp", "tcp4", owners) + tcp_rows("/proc/net/tcp6", "tcp6", owners)
if rows:
    for port, family, addr, state, owner in sorted(rows):
        marker = " *" if port in INTERESTING_PORTS else ""
        print(f"  {family} {addr}:{port} {state} owner={owner}{marker}")
else:
    print("  no tcp listeners found")

import urllib.request, urllib.error, subprocess

print("diagnostic: a2f http health")
try:
    with urllib.request.urlopen("http://127.0.0.1:8000/v1/health/ready", timeout=2) as resp:
        body = resp.read(512).decode("utf-8", "replace")
        print(f"  status={resp.status} body={body[:400]}")
except urllib.error.HTTPError as exc:
    try:
        body = exc.read(512).decode("utf-8", "replace")
    except Exception:
        body = ""
    print(f"  http_error={exc.code} body={body[:400]}")
except Exception as exc:
    print(f"  error={type(exc).__name__}: {exc}")

print("diagnostic: gpu visibility")
try:
    r = subprocess.run(
        ["nvidia-smi", "--query-gpu=index,name,memory.free,memory.total,driver_version", "--format=csv,noheader"],
        capture_output=True, text=True, timeout=5,
    )
    if r.returncode == 0:
        for line in r.stdout.strip().splitlines():
            print(f"  gpu: {line.strip()}")
    else:
        print(f"  nvidia-smi rc={r.returncode} stderr={r.stderr[:200]}")
except Exception as exc:
    print(f"  nvidia-smi error={type(exc).__name__}: {exc}")

print("diagnostic: cuda init")
try:
    import ctypes
    lib = ctypes.CDLL("libcuda.so.1")
    rc = lib.cuInit(0)
    print(f"  cuInit rc={rc} (0=OK, 100=NO_DEVICE, 999=not_initialized)")
except Exception as exc:
    print(f"  libcuda error={type(exc).__name__}: {exc}")

print("diagnostic: triton workspace logs")
import glob as _glob
for pattern in ("/opt/nim/workspace/logs/*.log", "/opt/nim/workspace/logs/*.txt",
                "/tmp/triton*.log", "/tmp/a2f*.log"):
    for fpath in _glob.glob(pattern):
        try:
            with open(fpath, "rb") as fh:
                tail = fh.read()[-1500:]
            print(f"  {fpath} (last 1500 bytes):")
            for ln in tail.decode("utf-8", "replace").splitlines()[-30:]:
                print(f"    {ln}")
        except Exception as exc:
            print(f"  {fpath} read error: {exc}")
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

check_gpu_accessible() {
  log "checking GPU/CUDA accessibility"
  if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi -L >&2 || log "WARNING: nvidia-smi -L failed"
  else
    log "WARNING: nvidia-smi not found — GPU driver may be inaccessible"
  fi
  python3 - <<'PYCUDA' >&2 || log "WARNING: CUDA cuInit failed — no GPU visible inside container; Triton will fail to start on port 52000; check that the VAST.ai template passes --gpus all / --runtime=nvidia"
import ctypes, sys
try:
    lib = ctypes.CDLL("libcuda.so.1")
    rc = lib.cuInit(0)
    if rc == 0:
        print("[a2f-entrypoint] CUDA cuInit OK — GPU accessible to Triton", file=sys.stderr)
    else:
        print(f"[a2f-entrypoint] CUDA cuInit rc={rc} (100=NO_DEVICE) — Triton will not find a GPU", file=sys.stderr)
        sys.exit(1)
except OSError as exc:
    print(f"[a2f-entrypoint] cannot load libcuda.so.1: {exc} — GPU not accessible", file=sys.stderr)
    sys.exit(1)
PYCUDA
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

log "wrapper active build=${A2F_WRAPPER_BUILD:-unknown} cwd=$(pwd) LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-} PYTHONPATH=${PYTHONPATH:-} NIM_USE_MODEL_MANIFEST_V0=${NIM_USE_MODEL_MANIFEST_V0:-<unset>} NIM_SKIP_A2F_START=${NIM_SKIP_A2F_START:-<unset>} NIM_DISABLE_MODEL_DOWNLOAD=${NIM_DISABLE_MODEL_DOWNLOAD:-<unset>} NVIDIA_DRIVER_CAPABILITIES=${NVIDIA_DRIVER_CAPABILITIES:-<unset>} CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES:-<unset>}"

if [ "${NIM_SKIP_A2F_START:-}" = "true" ] || [ "${NIM_SKIP_A2F_START:-}" = "1" ]; then
  log "unsetting NIM_SKIP_A2F_START so NVIDIA start_server can launch gRPC on 52000"
  unset NIM_SKIP_A2F_START
fi

check_gpu_accessible

start_pyworker_after_a2f_boot &
pyworker_pid=$!

export SERVER_START_SCRIPT_PATH="${SERVER_START_SCRIPT_PATH:-/opt/nim/start_server.sh}"
log "exec NVIDIA A2F startup exactly like base image: /bin/bash -c ${SERVER_START_SCRIPT_PATH}"
exec /bin/bash -c "$SERVER_START_SCRIPT_PATH"
