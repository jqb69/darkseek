#!/bin/bash

# --- Setup Script for DarkSeek on Google Cloud ---

# Exit on any error
set -e

# --- Check for Required Tools ---
check_command() {
  if ! command -v "$1" &> /dev/null; then
    echo "Installing '$1'..."
    case "$1" in
      git)
        sudo apt-get update && sudo apt-get install -y git
        ;;
      python3)
        sudo apt-get update && sudo apt-get install -y python3 python3-dev
        ;;
      pip3)
        sudo apt-get update && sudo apt-get install -y python3-pip
        ;;
      docker)
        sudo apt-get update && sudo apt-get install -y docker.io
        sudo systemctl start docker
        sudo systemctl enable docker
        sudo usermod -aG docker $USER
        ;;
      docker-compose)
        sudo curl -L "https://github.com/docker/compose/releases/download/v2.29.7/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        sudo chmod +x /usr/local/bin/docker-compose
        ;;
      *)
        echo "Error: '$1' is not installed and no install method defined. Please install it manually." >&2
        exit 1
        ;;
    esac
  fi
}

echo "Checking for required tools..."
check_command git
check_command python3
check_command pip3
check_command docker
check_command docker-compose

# --- Define Project Directory ---
PROJECT_DIR="/opt/darksearch"
REPO_URL="https://github.com/yourusername/darksearch.git"  # Replace with your GitHub repo URL

# --- Clone or Update from GitHub ---
if [ ! -d "$PROJECT_DIR" ]; then
  echo "Cloning repository from GitHub..."
  sudo mkdir -p "$PROJECT_DIR"
  sudo chown $USER:$USER "$PROJECT_DIR"
  git clone "$REPO_URL" "$PROJECT_DIR"
else
  echo "Repository already exists. Pulling latest changes..."
  cd "$PROJECT_DIR"
  git pull origin main  # Assumes 'main' is your default branch; adjust if needed (e.g., 'master')
fi

# --- Change to Project Directory ---
cd "$PROJECT_DIR"

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
  if [ -f ".env.example" ]; then
    cp .env.example .env
  else
    echo "Warning: .env.example not found. Creating a basic .env file..."
    cat <<EOL > .env
GOOGLE_API_KEY="your_actual_api_key_here"
GOOGLE_CSE_ID="your_actual_cse_id_here"
HUGGINGFACEHUB_API_TOKEN="your_huggingface_token_here"
DEFAULT_LLM="gemma_flash_2.0"
MQTT_BROKER_HOST="test.mosquitto.org"
MQTT_BROKER_PORT=8885
MQTT_TLS=true
DATABASE_URL="postgresql://user:password@localhost:5432/darkseekdb"
REDIS_URL="redis://localhost:6379"
EOL
  fi
  echo "Please edit the .env file and add your API keys and other settings."
else
  echo ".env file already exists. Skipping creation."
fi

# --- Ensure Docker Permissions (Google Cloud Specific) ---
echo "Ensuring Docker permissions for current user..."
sudo usermod -aG docker $USER

# --- Success Message ---
echo "\nSetup completed successfully!\n"
echo "To run both WebSocket and MQTT servers with Docker Compose (recommended):"
echo "  docker-compose up --build"

echo "To run WebSocket server only:"
echo "  docker-compose up backend-ws db redis"

echo "To run MQTT server only:"
echo "  docker-compose up backend-mqtt db redis"

echo "To run frontend separately:"
echo "  docker-compose up frontend"

echo "For development without Docker:"
echo "  1. WebSocket Backend: cd $PROJECT_DIR/app/backend && uvicorn main:app --reload --host 0.0.0.0 --port 8000"
echo "  2. MQTT Backend: cd $PROJECT_DIR/app/backend && uvicorn mainmqtt:app --reload --host 0.0.0.0 --port 8001"
echo "  3. Frontend: cd $PROJECT_DIR/app/frontend && streamlit run streamlit.py --server.address=0.0.0.0 --server.port 8501"

# Note: Virtual environment remains active in this shell session
echo "Virtual environment is active. To deactivate, run: deactivate"
