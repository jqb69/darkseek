# app/frontend/Dockerfile
FROM python:3.11-slim
WORKDIR /app
RUN apt-get update && apt-get install -y gcc && rm -rf /var/lib/apt/lists/*
COPY ./app/frontend/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY ./app/frontend /app/frontend
EXPOSE 8501
CMD ["streamlit", "run", "app/frontend/streamlit.py", "--server.port", "8501", "--server.address", "0.0.0.0"]
