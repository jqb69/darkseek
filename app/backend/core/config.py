# app/backend/core/config.py
import os
from dotenv import load_dotenv

load_dotenv()

def validate_env_vars():
    required_vars = ["GOOGLE_API_KEY", "GOOGLE_CSE_ID", "DATABASE_URL", "REDIS_URL", "HUGGINGFACEHUB_API_TOKEN"]
    missing_vars = [var for var in required_vars if not os.getenv(var)]
    if missing_vars:
        raise EnvironmentError(f"Missing required environment variables: {', '.join(missing_vars)}")

validate_env_vars()

# === Base Directory ===
BASE_DIR = os.path.dirname(os.path.abspath(__file__))  # Base directory of the backend

# === Certificates Directory ===
CERTS_DIR = os.path.join(BASE_DIR, "certs")  # Directory for certificates
os.makedirs(CERTS_DIR, exist_ok=True)  # Ensure the certs directory exists

# === File Paths for Certificates ===
CA_CERT_PATH = os.path.join(CERTS_DIR, "ca.crt")  # Path to CA certificate
SERVER_CERT_PATH = os.path.join(CERTS_DIR, "server.crt")  # Path to server certificate
SERVER_KEY_PATH = os.path.join(CERTS_DIR, "server.key")  # Path to server private key

# === Logs Directory ===
LOGS_DIR = os.path.join(BASE_DIR, "logs")  # Directory for logs
os.makedirs(LOGS_DIR, exist_ok=True)  # Ensure the logs directory exists

# === Log File Path ===
LOG_FILE_PATH = os.path.join(LOGS_DIR, "backend.log")  # Path to backend log file

# === MQTT Broker Configuration ===
MQTT_BROKER_URI = os.getenv("MQTT_BROKER_URI", "localhost")  # Replace with your broker's URI
MQTT_PORT = int(os.getenv("MQTT_PORT", 8883))  # Default port for MQTT over TLS/SSL

# === Application Settings ===
LLM_CONFIGS = {
    "gemma_flash_2.0": {
        "repo_id": "google/gemma-1.1-2b-it",
        "config": {"max_new_tokens": 512, "temperature": 0.7, "repetition_penalty": 1.2},
        "tgi_server_url": "https://your-gemma-endpoint.endpoints.huggingface.cloud/generate_stream"
    },
    "deepseek_r1_llm": {
        "repo_id": "deepseek-ai/deepseek-coder-1.3b-instruct",
        "config": {"max_new_tokens": 512, "temperature": 0.6},
        "tgi_server_url": "https://your-deepseek-endpoint.endpoints.huggingface.cloud/generate_stream"
    },
    "qwen_2.5_max": {
        "repo_id": "Qwen/Qwen1.5-72B-Chat",
        "config": {"max_new_tokens": 512, "temperature": 0.8},
        "tgi_server_url": "https://your-qwen-endpoint.endpoints.huggingface.cloud/generate_stream"
    }
}



LLM_OPTIONS = list(LLM_CONFIGS.keys())  # Automatically reflect available LLMs
MAX_INPUT_LENGTH = 1000  # Maximum allowed input length for user messages

# === Debug Mode ===
DEBUG_MODE = os.getenv("DEBUG_MODE", "True").lower() == "true"  # Enable debug mode for development
# Search Engine API Keys
GOOGLE_API_KEY = os.getenv("GOOGLE_API_KEY")
GOOGLE_CSE_ID = os.getenv("GOOGLE_CSE_ID")
DUCKDUCKGO_API_KEY = os.getenv("DUCKDUCKGO_API_KEY") # Not directly used, but good practice
#DEFAULT_LLM = "gemma_flash_2.0"
# LLM Settings
DEFAULT_LLM = os.getenv("DEFAULT_LLM", "gemma_flash_2.0")
#TGI_SERVER_URL = os.getenv("TGI_SERVER_URL", "http://localhost:8080/generate")  # Default TGI server URL

# Constants
MAX_QUERY = int(os.getenv("MAX_QUERY", 7))
MAX_CHATS = int(os.getenv("MAX_CHATS", 12))

# Database Configuration
DATABASE_URL = os.getenv("DATABASE_URL", "postgresql://user:password@localhost:5432/darkseekdb")
REDIS_URL = os.getenv("REDIS_URL", "redis://localhost:6379")
STREAMING_CHUNK_SIZE = 128  # Example default value
#STREAMING_CHUNK_SIZE = 10
