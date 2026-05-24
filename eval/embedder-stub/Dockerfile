FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONPATH=/app

WORKDIR /app

COPY eval/embedder-stub/requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt

COPY src /app/src
COPY eval/embedder-stub /app/eval/embedder-stub

EXPOSE 8080

CMD ["uvicorn", "app:app", "--app-dir", "/app/eval/embedder-stub", "--host", "0.0.0.0", "--port", "8080"]
