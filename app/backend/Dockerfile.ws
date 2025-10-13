# Use a slim base image
FROM python:3.9-slim AS builder

# Set the working directory
WORKDIR /app

# Install system dependencies for building
RUN apt-get update && apt-get install -y --no-install-recommends gcc \
    && rm -rf /var/lib/apt/lists/*

# Copy requirements file and install Python dependencies
COPY ./app/backend/requirements.txt .
RUN pip install --upgrade pip
RUN pip install --no-cache-dir -r requirements.txt

# Copy the application code
COPY ./app /app/app

# Set the environment variable
ENV PYTHONPATH=/app

# Expose the port
EXPOSE 8000

# Start the application using Uvicorn
CMD ["uvicorn", "app.backend.main:app", "--host", "0.0.0.0", "--port", "8000"]
