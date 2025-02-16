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

# Search Engine API Keys
GOOGLE_API_KEY = os.getenv("GOOGLE_API_KEY")
GOOGLE_CSE_ID = os.getenv("GOOGLE_CSE_ID")
DUCKDUCKGO_API_KEY = os.getenv("DUCKDUCKGO_API_KEY") # Not directly used, but good practice

# LLM Settings
DEFAULT_LLM = os.getenv("DEFAULT_LLM", "gemma_flash_2.0")

# Constants
MAX_QUERY = int(os.getenv("MAX_QUERY", 7))
MAX_CHATS = int(os.getenv("MAX_CHATS", 12))

# Database Configuration
DATABASE_URL = os.getenv("DATABASE_URL", "postgresql://user:password@localhost:5432/darkseekdb")
REDIS_URL = os.getenv("REDIS_URL", "redis://localhost:6379")
STREAMING_CHUNK_SIZE = 10
