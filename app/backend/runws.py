# app/backend/runws.py
import uvicorn
import os
import sys

# Configuration
APP_MODULE = "app.backend.main:app"
CERT_PATH = "/app/certs/tls.crt"
KEY_PATH = "/app/certs/tls.key"

def run_https():
    """Starts the server in secure mode on 8443."""
    print(f"🔐 Starting SECURE server on 8443 using {APP_MODULE}")
    uvicorn.run(
        APP_MODULE,
        host="0.0.0.0",
        port=8443,
        ssl_keyfile=KEY_PATH,
        ssl_certfile=CERT_PATH,
        log_level="info"
    )

def run_http():
    """Starts the server in legacy mode on 8000."""
    print(f"⚠️ Starting LEGACY server on 8000 using {APP_MODULE}")
    uvicorn.run(
        APP_MODULE,
        host="0.0.0.0",
        port=8000,
        log_level="info"
    )

def main():
    # Check if both cert and key files exist
    has_certs = os.path.exists(CERT_PATH) and os.path.exists(KEY_PATH)
    
    if has_certs:
        run_https()
    else:
        print("❌ Certificates not found at /app/certs/")
        run_http()

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
