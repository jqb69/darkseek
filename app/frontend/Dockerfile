# app/frontend/Dockerfile
FROM python:3.11-slim
WORKDIR /app
# install build deps, then install Python deps
RUN apt-get update && apt-get install -y gcc && rm -rf /var/lib/apt/lists/*
COPY ./app/frontend/requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt
# Copy the frontend code into /app/frontend so the path is /app/frontend/...
COPY ./app/frontend /app/frontend
EXPOSE 8501
# Run streamlit relative to WORKDIR=/app — path points to frontend/streamlit_app.py
CMD ["streamlit", "run", "frontend/streamlit_app.py", "--server.port", "8501", "--server.address", "0.0.0.0"]
