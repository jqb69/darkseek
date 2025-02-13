#!/bin/bash

# --- Setup Script for DarkSeek ---

# Exit on any error
set -e

# --- Check for Required Tools ---
check_command() {
  if ! command -v "$1" &> /dev/null; then
    echo "Error: '$1' is not installed. Please install it before proceeding." >&2
    exit 1
  fi
}

check_command python3
check_command pip3
check_command docker
check_command docker-compose

# --- Create Virtual Environment (Recommended) ---
if [ ! -d "./venv" ]; then
  echo "Creating virtual environment..."
  python3 -m venv ./venv
fi

# --- Activate Virtual Environment ---
source ./venv/bin/activate

# --- Install Python Dependencies (Backend and Frontend) ---
echo "Installing backend dependencies..."
pip3 install -r ./app/backend/requirements.txt

echo "Installing frontend dependencies..."
pip3 install -r ./app/frontend/requirements.txt

# --- Create .env File (from .env.example) ---
if [ ! -f ".env" ]; then
  echo "Creating .env file from .env.example..."
  cp .env.example .env
  echo "Please edit the .env file and add your API keys and other settings."
else
  echo ".env file already exists.  Skipping creation."
fi

# --- Success Message ---
echo "\nSetup completed successfully!\n"
echo "To run the application with Docker Compose (recommended):"
echo "  docker-compose up --build"

echo "To run the backend and frontend *separately* (for development without Docker):"
echo "  1. Backend (in one terminal):"
echo "     cd app/backend && uvicorn main:app --reload --host 0.0.0.0 --port 8000"
echo "  2. Frontend (in another terminal):"
echo "     cd app/frontend && streamlit run streamlit_app.py --server.address=0.0.0.0 --server.port 8501"

# Deactivate the virtual environment when the script finishes (optional).
# deactivate
