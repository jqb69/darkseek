# app/frontend/Dockerfile
FROM python:3.11-slim

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends gcc \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir --upgrade pip virtualenv
RUN python -m virtualenv /app/venv
ENV PATH="/app/venv/bin:$PATH"

# ← THIS LINE IS PURE GENIUS
COPY app/frontend/requirements.txt /app/
RUN pip install --no-cache-dir -r /app/requirements.txt

COPY . /app/
ENV PYTHONPATH=/app

WORKDIR /app/frontend
EXPOSE 8501

CMD ["streamlit", "run", "streamlit_app.py", \
     "--server.port=8501", \
     "--server.address=0.0.0.0", \
     "--server.enableCORS=false", \
     "--server.enableXsrfProtection=false"]
