# app/backend/Dockerfile.ws
FROM python:3.11-slim

WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends gcc \
    && rm -rf /var/lib/apt/lists/*
COPY app/backend/requirements.txt ./backend/
RUN pip install --no-cache-dir -r backend/requirements.txt
COPY app/backend/ ./backend/
ENV PYTHONPATH=/app
EXPOSE 8000
CMD ["uvicorn", "backend/main:app", "--host", "0.0.0.0", "--port", "8000"]
