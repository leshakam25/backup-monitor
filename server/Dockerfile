FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app
COPY requirements.txt .
RUN pip install -r requirements.txt

COPY backup_bot ./backup_bot

RUN useradd --system --uid 10001 --home /data bot && mkdir -p /data && chown bot /data
USER bot

ENV LISTEN_HOST=0.0.0.0 \
    LISTEN_PORT=8080 \
    DB_PATH=/data/backup_bot.sqlite3
VOLUME /data
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/health', timeout=3)"

CMD ["python", "-m", "backup_bot"]
