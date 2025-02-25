#darkseek app/backend/DockerFile.ws
FROM python:3.11-slim
WORKDIR /app
RUN apt-get update && apt-get install -y gcc && rm -rf /var/lib/apt/lists/*
COPY ./app/backend/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY ./app/backend /app/backend
EXPOSE 8000
CMD ["uvicorn", "app.backend.main:app", "--host", "0.0.0.0", "--port", "8000"]
