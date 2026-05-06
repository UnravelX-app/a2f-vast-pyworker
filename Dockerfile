FROM nvcr.io/nim/nvidia/audio2face-3d:1.3.16

USER root

WORKDIR /app
COPY requirements.txt /app/requirements.txt
COPY worker.py /app/worker.py
COPY a2f-start-server.sh /app/a2f-entrypoint.sh
RUN chmod +x /app/a2f-entrypoint.sh \
    && mkdir -p /var/log/portal

WORKDIR /opt/nim

ENV A2F_WRAPPER_BUILD=stock-entrypoint-unset-skip-v30 \
    A2F_PYWORKER_START_DELAY_SEC=45

EXPOSE 8000 52000 18000

ENTRYPOINT ["/app/a2f-entrypoint.sh"]
