#  app/frontend/Dockerfile
#  Dockerfile — FINAL, ETERNAL, GEMINI-APPROVED (repo root)
FROM python:3.11-slim

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends gcc \
    && rm -rf /var/lib/apt/lists/*
# Upgrade pip and install virtualenv
RUN pip install --no-cache-dir --upgrade pip virtualenv

# Create and activate virtual environment
RUN python -m virtualenv /app/venv
ENV PATH="/app/venv/bin:$PATH"
# --- Dependency Installation (for better caching) ---
# CRITICAL FIX: requirements.txt is located at ./app/frontend/requirements.txt
COPY app/frontend/requirements.txt /app/
RUN pip install --no-cache-dir --no-cache -r /app/requirements.txt

# --- CRITICAL FIXES FOR PYTHON IMPORTS ---
# 1. Copies ENTIRE repo (including 'app/frontend') into /app
#    Result: Code is now at /app/app/frontend/...
COPY . /app/
# 2. Sets Python search path to include /app (the root containing the 'app' module)
ENV PYTHONPATH=/app

# 3. Sets working directory to the application code location
# FIX: WORKDIR must point to the full path of the Streamlit app.
WORKDIR /app/app/frontend

EXPOSE 8501
# --- CMD FIX ---
# Command is now relative to WORKDIR /app/app/frontend, so it is just the filename.
CMD ["streamlit", "run", "streamlit_app.py", \
    "--server.port=8501", \
    "--server.address=0.0.0.0", \
    "--server.enableCORS=false", \
    "--server.enableXsrfProtection=false"]
