# app/frontend/Dockerfile
FROM python:3.11-slim
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends gcc \
    && rm -rf /var/lib/apt/lists/*
COPY requirements.txt ./frontend/
RUN pip install --no-cache-dir -r frontend/requirements.txt
COPY . ./frontend/
COPY components/ ./frontend/components/
COPY static/ ./frontend/static/
ENV PYTHONPATH=/app
EXPOSE 8501
CMD ["streamlit", "run", "frontend/streamlit_app.py", "--server.port", "8501", "--server.address", "0.0.0.0"]
