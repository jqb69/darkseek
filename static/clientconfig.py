# frontend/static/clientconfig.py

# Define available LLM options (must match backend's self.llms keys)
LLM_OPTIONS = [
    "gemma_flash_2.0",
    "deepseek_r1_llm",
    "qwen_2.5_max"
]

# WebSocket server URI
WEBSOCKET_URI = "ws://localhost:8000/ws/"

# Default session ID placeholder
DEFAULT_SESSION_ID = "default_session_id"

# Maximum input length for user queries
MAX_INPUT_LENGTH = 500
