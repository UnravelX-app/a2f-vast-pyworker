FROM nvcr.io/nim/nvidia/audio2face-3d:1.3.16

USER root

# NVIDIA/DeepStream-based images can abort in GLib/GStreamer when newer GLib
# libs live only under /usr/local and the runtime linker cache misses them.
# Put those libs in the standard path and refresh ldconfig before A2F starts.
RUN if [ -d /usr/local/lib/x86_64-linux-gnu ]; then \
        cp -a /usr/local/lib/x86_64-linux-gnu/. /usr/lib/x86_64-linux-gnu/ && ldconfig; \
    else \
        ldconfig; \
    fi

WORKDIR /app

COPY requirements.txt /app/requirements.txt
RUN python3 -m pip install --no-cache-dir --index-url https://pypi.org/simple -r /app/requirements.txt

COPY worker.py /app/worker.py
COPY docker-entrypoint.sh /app/docker-entrypoint.sh
RUN chmod +x /app/docker-entrypoint.sh \
    && mkdir -p /var/log/portal /workspace/a2f-cache

ENV PYTHONUNBUFFERED=1 \
    LD_LIBRARY_PATH=/usr/lib/x86_64-linux-gnu:/usr/local/lib/x86_64-linux-gnu \
    GST_REGISTRY_FORK=no \
    GST_REGISTRY_UPDATE=no \
    PYWORKER_MODEL_SERVER_URL=http://127.0.0.1 \
    WORKER_PORT=18000 \
    PYWORKER_MODEL_SERVER_PORT=18000 \
    PYWORKER_MODEL_LOG_FILE=/var/log/portal/a2f-pyworker.log \
    A2F_HTTP_READY_URL=http://127.0.0.1:8000/v1/health/ready \
    A2F_GRPC_HOST=127.0.0.1 \
    A2F_GRPC_PORT=52000 \
    A2F_READY_TIMEOUT_SEC=3600 \
    A2F_READY_POLL_SEC=5 \
    A2F_START_CMD='/bin/bash -c "$SERVER_START_SCRIPT_PATH"'

EXPOSE 8000 52000 18000

ENTRYPOINT ["/app/docker-entrypoint.sh"]
