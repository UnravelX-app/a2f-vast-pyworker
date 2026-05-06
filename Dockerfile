FROM nvcr.io/nim/nvidia/audio2face-3d:1.3.16

USER root

WORKDIR /app
COPY requirements.txt /app/requirements.txt
COPY worker.py /app/worker.py
COPY a2f-start-server.sh /app/a2f-start-server.sh
RUN chmod +x /app/a2f-start-server.sh \
    && mkdir -p /var/log/portal /workspace/a2f-cache

WORKDIR /opt/nim

ENV A2F_WRAPPER_BUILD=stock-entrypoint-v11 \
    SERVER_START_SCRIPT_PATH=/app/a2f-start-server.sh

EXPOSE 8000 52000 18000
