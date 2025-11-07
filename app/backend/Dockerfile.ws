# app/backend/Dockerfile.ws
FROM python:3.11-slim
WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends gcc \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir --upgrade pip virtualenv
RUN python -m virtualenv /app/venv
ENV PATH="/app/venv/bin:$PATH"

COPY app/backend/ /app/app/backend/
RUN pip install --no-cache-dir -r /app/app/backend/requirements.txt

ENV PYTHONPATH=/app

EXPOSE 8000
CMD ["uvicorn", "app.backend.main:app", "--host", "0.0.0.0", "--port", "8000"]
