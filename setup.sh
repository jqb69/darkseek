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

# --- Define Project Directory and GitHub Repo ---
PROJECT_DIR="/opt/darksearch"
REPO_URL="https://github.com/jqb69/darkseek.git"  # Replace with your GitHub repo URL
CURRENT_USER=$(whoami)

# --- Clone or Update from GitHub ---
if [ ! -d "$PROJECT_DIR" ]; then
  echo "Cloning repository from GitHub..."
  sudo mkdir -p "$PROJECT_DIR"
  sudo chown $CURRENT_USER:$CURRENT_USER "$PROJECT_DIR"
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

# --- Ensure Docker Permissions ---
echo "Ensuring Docker permissions for current user..."
sudo usermod -aG docker $CURRENT_USER

# --- Create Systemd Service Files ---
echo "Creating systemd service files..."

# WebSocket Backend Service
cat <<EOL | sudo tee /etc/systemd/system/darksearch-backend-ws.service
[Unit]
Description=DarkSearch WebSocket Backend Service
After=network.target docker.service
Requires=docker.service

[Service]
Type=simple
ExecStart=/usr/local/bin/docker-compose -f $PROJECT_DIR/docker-compose.yaml up backend-ws db redis
ExecStop=/usr/local/bin/docker-compose -f $PROJECT_DIR/docker-compose.yaml stop backend-ws db redis
WorkingDirectory=$PROJECT_DIR
Restart=always
User=$CURRENT_USER
EnvironmentFile=$PROJECT_DIR/.env

[Install]
WantedBy=multi-user.target
EOL

# MQTT Backend Service
cat <<EOL | sudo tee /etc/systemd/system/darksearch-backend-mqtt.service
[Unit]
Description=DarkSearch MQTT Backend Service
After=network.target docker.service
Requires=docker.service

[Service]
Type=simple
ExecStart=/usr/local/bin/docker-compose -f $PROJECT_DIR/docker-compose.yaml up backend-mqtt db redis
ExecStop=/usr/local/bin/docker-compose -f $PROJECT_DIR/docker-compose.yaml stop backend-mqtt db redis
WorkingDirectory=$PROJECT_DIR
Restart=always
User=$CURRENT_USER
EnvironmentFile=$PROJECT_DIR/.env

[Install]
WantedBy=multi-user.target
EOL

# Frontend Service
cat <<EOL | sudo tee /etc/systemd/system/darksearch-frontend.service
[Unit]
Description=DarkSearch Frontend Service
After=network.target docker.service
Requires=docker.service

[Service]
Type=simple
ExecStart=/usr/local/bin/docker-compose -f $PROJECT_DIR/docker-compose.yaml up frontend
ExecStop=/usr/local/bin/docker-compose -f $PROJECT_DIR/docker-compose.yaml stop frontend
WorkingDirectory=$PROJECT_DIR
Restart=always
User=$CURRENT_USER
EnvironmentFile=$PROJECT_DIR/.env

[Install]
WantedBy=multi-user.target
EOL

# --- Set Permissions for Service Files ---
sudo chmod 644 /etc/systemd/system/darksearch-backend-ws.service
sudo chmod 644 /etc/systemd/system/darksearch-backend-mqtt.service
sudo chmod 644 /etc/systemd/system/darksearch-frontend.service

# --- Reload Systemd and Enable Services ---
echo "Reloading systemd and enabling services..."
sudo systemctl daemon-reload
sudo systemctl enable darksearch-backend-ws.service
sudo systemctl enable darksearch-backend-mqtt.service
sudo systemctl enable darksearch-frontend.service

# --- Start Services ---
echo "Starting services..."
sudo systemctl start darksearch-backend-ws.service
sudo systemctl start darksearch-backend-mqtt.service
sudo systemctl start darksearch-frontend.service

# --- Success Message ---
echo "\nSetup completed successfully!\n"
echo "Services are configured to start automatically on boot."
echo "Current status:"
echo "  systemctl status darksearch-backend-ws.service"
echo "  systemctl status darksearch-backend-mqtt.service"
echo "  systemctl status darksearch-frontend.service"

echo "To run manually with Docker Compose (optional):"
echo "  cd $PROJECT_DIR && docker-compose up --build"

echo "To stop services:"
echo "  sudo systemctl stop darksearch-backend-ws.service"
echo "  sudo systemctl stop darksearch-backend-mqtt.service"
echo "  sudo systemctl stop darksearch-frontend.service"

echo "Virtual environment is active. To deactivate, run: deactivate"
