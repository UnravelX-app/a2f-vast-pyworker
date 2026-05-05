# A2F Vast PyWorker

Custom Vast.ai PyWorker readiness shim for NVIDIA Audio2Face-3D NIM.

It does not replace A2F and does not proxy live A2F gRPC. It waits for the local
A2F NIM service to become ready on HTTP `8000` and gRPC `52000`, then emits the
`A2F_READY` log prefix that Vast's serverless worker uses to move out of
`model_loading`.

## Files

- `worker.py` - Vast PyWorker config + local readiness probe server.
- `requirements.txt` - Python dependencies for Vast to install.

## Vast Template

Set this environment variable in your Serverless template:

```text
PYWORKER_REPO=https://github.com/<your-org-or-user>/a2f-vast-pyworker.git
```

Until this folder is pushed to a public Git repo, Vast cannot clone it.

## A2F Docker Options

Use one A2F model per worker group. Example for RTX 4090 Claire:

```text
-p 8000:8000 -p 52000:52000 --gpus all --ipc=host -v /workspace/a2f-cache:/tmp/a2x -e NGC_API_KEY=nvapi-xxx -e NVIDIA_VISIBLE_DEVICES=all -e NVIDIA_DRIVER_CAPABILITIES=compute,utility,video -e NIM_MANIFEST_PROFILE=c761e52b62df2a2a46047aed74dd6e1da8826f3596bec3c197372c7592478f6b -e PERF_A2F_MODEL=claire_v2.3
```

For Mark, change only:

```text
-e PERF_A2F_MODEL=mark_v2.3
```

Leave Docker ENTRYPOINT args and On-start Script empty for the raw NVIDIA NIM
image. The image starts the A2F service itself.

## PyWorker Environment Variables

Defaults are correct for A2F NIM in the same container/network namespace:

```text
A2F_HTTP_READY_URL=http://127.0.0.1:8000/v1/health/ready
A2F_GRPC_HOST=127.0.0.1
A2F_GRPC_PORT=52000
A2F_READY_TIMEOUT_SEC=3600
A2F_READY_POLL_SEC=5
PYWORKER_MODEL_SERVER_PORT=18000
PYWORKER_MODEL_LOG_FILE=/var/log/portal/a2f-pyworker.log
```

## Endpoint Settings

For first serverless test:

```text
Minimum Workers: 1
Max Workers: 1
Max Queue Time: 3600
Target Queue Time: 300
Inactivity timeout: 1800-3600
Disk: 120GB+
```

Once the worker reaches ready reliably, lower Minimum Workers if you want to test
scale-to-zero cold starts.

## Routes

The PyWorker exposes lightweight HTTP routes for Vast's readiness/benchmarking:

- `/benchmark`
- `/health`
- `/ready`

Your production A2F wrapper should still connect to the mapped external
`52000/tcp` port for live gRPC sessions.
