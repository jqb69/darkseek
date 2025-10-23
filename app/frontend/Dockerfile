# app/frontend/Dockerfile
FROM python:3.11-slim

WORKDIR /app
RUN apt-get update && apt-get install -y gcc && rm -rf /var/lib/apt/lists/*
COPY app/frontend/requirements.txt ./frontend/
RUN pip install --no-cache-dir -r frontend/requirements.txt
COPY app/frontend/streamlit_app.py ./frontend/
COPY app/frontend/components/ ./frontend/components/
COPY app/frontend/static/ ./frontend/static/
EXPOSE 8501
CMD ["streamlit", "run", "frontend/streamlit_app.py", "--server.port", "8501", "--server.address", "0.0.0.0"]
