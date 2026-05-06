"""Vast.ai PyWorker readiness shim for NVIDIA Audio2Face-3D NIM.

This worker is intentionally small:
- It assumes the A2F NIM container is running locally in the same worker.
- It polls A2F HTTP health and gRPC TCP readiness.
- It writes an `A2F_READY` log line that Vast's PyWorker SDK uses as on_load.
- It exposes lightweight HTTP routes that Vast can benchmark/probe.

It does not proxy the real A2F gRPC stream. Your existing a2f-wrapper should still
connect to the worker's mapped 52000/tcp port for live gRPC sessions.
"""

from __future__ import annotations

import json
import os
import socket
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

from vastai import BenchmarkConfig, HandlerConfig, LogActionConfig, Worker, WorkerConfig

MODEL_SERVER_URL = os.getenv("PYWORKER_MODEL_SERVER_URL", "http://127.0.0.1")
MODEL_SERVER_PORT = int(os.getenv("PYWORKER_MODEL_SERVER_PORT", "18002"))
MODEL_LOG_FILE = os.getenv("PYWORKER_MODEL_LOG_FILE", "/var/log/portal/a2f-pyworker.log")

A2F_HTTP_READY_URL = os.getenv("A2F_HTTP_READY_URL", "http://127.0.0.1:8000/v1/health/ready")
A2F_GRPC_HOST = os.getenv("A2F_GRPC_HOST", "127.0.0.1")
A2F_GRPC_PORT = int(os.getenv("A2F_GRPC_PORT", "52000"))
A2F_READY_TIMEOUT_SEC = int(os.getenv("A2F_READY_TIMEOUT_SEC", "3600"))
A2F_READY_POLL_SEC = float(os.getenv("A2F_READY_POLL_SEC", "5"))

LOAD_LOG_PREFIX = "A2F_READY"
ERROR_LOG_PREFIX = "A2F_ERROR"
INFO_LOG_PREFIX = "A2F_INFO"

_ready = threading.Event()
_last_status: dict[str, Any] = {
    "ready": False,
    "http_ready": False,
    "grpc_ready": False,
    "message": "starting",
}


def _ensure_log_file() -> None:
    path = Path(MODEL_LOG_FILE)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("", encoding="utf-8")


def _log(prefix: str, event: str, **fields: Any) -> None:
    payload = dict(fields)
    payload["event"] = event
    line = f"{prefix} {json.dumps(payload, separators=(',', ':'), sort_keys=True)}\n"
    with open(MODEL_LOG_FILE, "a", encoding="utf-8") as fh:
        fh.write(line)
        fh.flush()
    print(line, end="", flush=True)


def _check_http_ready(timeout: float = 2.0) -> tuple[bool, str]:
    try:
        req = urllib.request.Request(A2F_HTTP_READY_URL, method="GET")
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read(2048).decode("utf-8", errors="replace")
            ok = 200 <= int(resp.status) < 300
            if not ok:
                return False, f"http_status={resp.status} body={body[:200]}"
            return True, body[:500]
    except urllib.error.HTTPError as exc:
        try:
            body = exc.read(512).decode("utf-8", errors="replace")
        except Exception:
            body = ""
        return False, f"http_error={exc.code} body={body[:200]}"
    except Exception as exc:
        return False, f"http_exception={type(exc).__name__}: {exc}"


def _check_grpc_tcp(timeout: float = 2.0) -> tuple[bool, str]:
    try:
        with socket.create_connection((A2F_GRPC_HOST, A2F_GRPC_PORT), timeout=timeout):
            return True, "tcp_connect_ok"
    except Exception as exc:
        return False, f"grpc_tcp_exception={type(exc).__name__}: {exc}"


def _refresh_status() -> dict[str, Any]:
    http_ok, http_msg = _check_http_ready()
    grpc_ok, grpc_msg = _check_grpc_tcp()
    ready = http_ok
    _last_status.update(
        {
            "ready": ready,
            "http_ready": http_ok,
            "grpc_ready": grpc_ok,
            "http_message": http_msg,
            "grpc_message": grpc_msg,
            "a2f_http_ready_url": A2F_HTTP_READY_URL,
            "a2f_grpc_addr": f"{A2F_GRPC_HOST}:{A2F_GRPC_PORT}",
            "ts": time.time(),
        }
    )
    if ready:
        _ready.set()
    return dict(_last_status)


def _readiness_watcher() -> None:
    started = time.monotonic()
    last_info = 0.0
    while True:
        status = _refresh_status()
        if status["ready"]:
            _log(LOAD_LOG_PREFIX, "Audio2Face NIM is ready", **status)
            return

        now = time.monotonic()
        if now - last_info >= 30:
            last_info = now
            _log(INFO_LOG_PREFIX, "waiting for Audio2Face NIM", **status)

        if now - started > A2F_READY_TIMEOUT_SEC:
            _log(ERROR_LOG_PREFIX, "timed out waiting for Audio2Face NIM", **status)
            return
        time.sleep(A2F_READY_POLL_SEC)


class HealthHandler(BaseHTTPRequestHandler):
    server_version = "A2FVastPyWorker/1.0"

    def log_message(self, fmt: str, *args: Any) -> None:
        return

    def _send_json(self, status_code: int, payload: dict[str, Any]) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _handle(self) -> None:
        status = _refresh_status()
        if self.path in ("/", "/ping", "/health", "/ready", "/v1/health/ready"):
            self._send_json(200 if status["ready"] else 503, status)
            return
        if self.path == "/benchmark":
            self._send_json(200 if status["ready"] else 503, {"ok": status["ready"], **status})
            return
        self._send_json(404, {"error": "not_found", "path": self.path})

    def do_GET(self) -> None:
        self._handle()

    def do_POST(self) -> None:
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)
        self._handle()


def _start_probe_server() -> None:
    server = ThreadingHTTPServer(("127.0.0.1", MODEL_SERVER_PORT), HealthHandler)
    thread = threading.Thread(target=server.serve_forever, name="a2f-probe-server", daemon=True)
    thread.start()
    _log(INFO_LOG_PREFIX, "probe server started", host="127.0.0.1", model_server_port=MODEL_SERVER_PORT, worker_port=os.getenv("WORKER_PORT", ""))


def _workload(_: dict[str, Any]) -> float:
    return 1.0


def main() -> None:
    _ensure_log_file()
    _log(INFO_LOG_PREFIX, "pyworker starting")
    _start_probe_server()
    threading.Thread(target=_readiness_watcher, name="a2f-readiness", daemon=True).start()

    worker_config = WorkerConfig(
        model_server_url=MODEL_SERVER_URL,
        model_server_port=MODEL_SERVER_PORT,
        model_log_file=MODEL_LOG_FILE,
        handlers=[
            HandlerConfig(
                route="/ping",
                allow_parallel_requests=True,
                max_queue_time=3600.0,
                workload_calculator=_workload,
                benchmark_config=BenchmarkConfig(
                    dataset=[{}],
                    runs=1,
                    concurrency=1,
                ),
            ),
        ],
        log_action_config=LogActionConfig(
            on_load=[LOAD_LOG_PREFIX],
            on_error=[ERROR_LOG_PREFIX],
            on_info=[INFO_LOG_PREFIX],
        ),
    )
    Worker(worker_config).run()


if __name__ == "__main__":
    main()
