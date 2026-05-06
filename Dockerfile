FROM nvcr.io/nim/nvidia/audio2face-3d:1.3.16

USER root

WORKDIR /app

COPY requirements.txt /app/requirements.txt

COPY worker.py /app/worker.py
COPY docker-entrypoint.sh /app/docker-entrypoint.sh
RUN chmod +x /app/docker-entrypoint.sh \
    && mkdir -p /var/log/portal /workspace/a2f-cache

WORKDIR /opt/nim

ENV PYTHONUNBUFFERED=1 \
    A2F_WRAPPER_BUILD=stock-a2f-runtime-v9

EXPOSE 8000 52000 18000

ENTRYPOINT ["/app/docker-entrypoint.sh"]
