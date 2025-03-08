FROM python:3.9-slim

# Install gcc
RUN apt-get update && apt-get install -y gcc && rm -rf /var/lib/apt/lists/*

# Copy requirements.txt
COPY ./app/backend/requirements.txt .

# Upgrade pip and install Python dependencies
RUN pip install --upgrade pip
RUN pip install --no-cache-dir -r requirements.txt

# Copy the backend application
COPY ./app/backend /app/backend

# Expose port 8000
EXPOSE 8000

# Command to run the application (add your command here)
CMD ["uvicorn", "app.backend.main:app", "--host", "0.0.0.0", "--port", "8000"]
