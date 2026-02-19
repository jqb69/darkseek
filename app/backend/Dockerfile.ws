FROM python:3.11-slim
WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    curl \
    netcat-openbsd \
    && rm -rf /var/lib/apt/lists/*    

RUN pip install --no-cache-dir --upgrade pip virtualenv
RUN python -m virtualenv /app/venv
ENV PATH="/app/venv/bin:$PATH"

# Copy everything from local app/backend to the container path
# This includes main.py AND runws.py
COPY app/backend/ /app/darkseek/app/backend/

RUN pip install --no-cache-dir -r /app/darkseek/app/backend/requirements.txt

ENV PYTHONPATH=/app/darkseek
EXPOSE 8000
EXPOSE 8443

# Start the modular runner using the path where it was copied
CMD ["python", "/app/darkseek/app/backend/runws.py"]
