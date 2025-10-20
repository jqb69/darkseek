# app/frontend/Dockerfile
FROM python:3.11-slim

# Set working directory
WORKDIR /app
# Install build dependencies (e.g., gcc)
RUN apt-get update && apt-get install -y gcc && rm -rf /var/lib/apt/lists/*
# Copy the requirements and install them
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
# Copy the application code
COPY . .
# Expose the port that Streamlit will run on
EXPOSE 8501
# Run the Streamlit app
CMD ["streamlit", "run", "streamlit_app.py", "--server.port", "8501", "--server.address", "0.0.0.0"]
