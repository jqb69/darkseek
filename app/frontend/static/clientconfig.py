# frontend/static/clientconfig.py

# Define available LLM options (must match backend's self.llms keys)
LLM_OPTIONS = [
    "gemma_flash_2.0",
    "deepseek_r1_llm",
    "qwen_2.5_max"
]
# === Certificates Directory ===
CERTS_DIR = /etc/mosquitto/ssl/  # Directory for certificates
#os.makedirs(CERTS_DIR, exist_ok=True)  # Ensure the certs directory exists

# === File Paths for Certificates ===
CA_CERT_PATH = os.path.join(CERTS_DIR, "mosquitto.org.crt")  # Path to CA certificate
SERVER_CERT_PATH = os.path.join(CERTS_DIR, "test.mosquitto.org.crt")  # Path to server certificate
SERVER_KEY_PATH = os.path.join(CERTS_DIR, "test.mosquitto.org.key")  # Path to server private key
# === MQTT Broker Configuration ===
MQTT_BROKER_URI = os.getenv("MQTT_BROKER_URI", "test.mosquitto.org")  # Replace with your broker's URI
MQTT_PORT = int(os.getenv("MQTT_PORT", 8885))  # Default port for MQTT over TLS/SSL

# WebSocket server URI
WEBSOCKET_URI = os.getenv("WEBSOCKET_URI", "wss://darkseek-backend/ws/")
#MQTTostSERVER ui
MQTT_URI = os.getenv("MQTT_URI", "https:darkseek-backend-mqtt:8001")
# Default session ID placeholder
DEFAULT_SESSION_ID = "default_session_id"

# Maximum input length for user queries
MAX_INPUT_LENGTH = 1000
