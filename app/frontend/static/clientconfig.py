# frontend/static/clientconfig.py
import os # <-- BUG FIX: ADDED MISSING OS IMPORT

# Define available LLM options (must match backend's self.llms keys)
LLM_OPTIONS = [
    "gemma_flash_2.0",
    "deepseek_r1_llm",
    "qwen_2.5_max"
]
# === Certificates Directory ===
CERTS_DIR = "/etc/mosquitto/ssl/" # Directory for certificates
#os.makedirs(CERTS_DIR, exist_ok=True) # Ensure the certs directory exists

# === File Paths for Certificates ===
CA_CERT_PATH = os.path.join(CERTS_DIR, "mosquitto.org.crt") # Path to CA certificate
SERVER_CERT_PATH = os.path.join(CERTS_DIR, "test.mosquitto.org.crt") # Path to server certificate
SERVER_KEY_PATH = os.path.join(CERTS_DIR, "test.mosquitto.org.key") # Path to server private key
# === MQTT Broker Configuration ===
MQTT_BROKER_HOST = os.getenv("MQTT_BROKER_HOST", "test.mosquitto.org") # Renamed URI to HOST for clarity
MQTT_BROKER_PORT = int(os.getenv("MQTT_BROKER_PORT", 8885)) # Default port for MQTT over TLS/SSL

# WebSocket server URI
WEBSOCKET_URI = os.getenv("WEBSOCKET_URI", "wss://darkseek-backend-ws/ws/")
# MQTT host SERVER ui
MQTT_URI = os.getenv("MQTT_URI", "http://darkseek-backend-ws:8000") # <-- BUG FIX: Corrected "https:" to "https://"
HTTP_BASE_API = os.getenv("HTTP_BASE_API", "http://darkseek-backend-ws:8000") # <-- BUG FIX: Corrected "https:" to "https://"
# Default session ID placeholder
DEFAULT_SESSION_ID = "default_session_id"

# Maximum input length for user queries
MAX_INPUT_LENGTH = 1000

# --- Authentication Configuration ---
MAX_GUEST_QUERIES = 5
MAX_REGULAR_QUERIES = MAX_GUEST_QUERIES * 30
GUEST_USER = "guest"
GUEST_PASSWORD = "whatever"
