# app/backend/runws.py
import multiprocessing
import uvicorn
import os

# Your existing config
APP_MODULE = "app.backend.main:app"
CERT_PATH = "/app/certs/tls.crt"
KEY_PATH = "/app/certs/tls.key"

def run_http():
    print("📡 Starting HTTP on port 8000...")
    uvicorn.run(APP_MODULE, host="0.0.0.0", port=8000, log_level="info")

def run_https():
    if os.path.exists(CERT_PATH) and os.path.exists(KEY_PATH):
        print("🔐 Starting HTTPS on port 8443...")
        uvicorn.run(
            APP_MODULE, 
            host="0.0.0.0", 
            port=8443, 
            ssl_keyfile=KEY_PATH, 
            ssl_certfile=CERT_PATH,
            log_level="info"
        )
    else:
        print("⚠️ SSL Certs missing. HTTPS server will not start.")

if __name__ == "__main__":
    # Create processes for both listeners
    http_process = multiprocessing.Process(target=run_http)
    https_process = multiprocessing.Process(target=run_https)

    # Start them
    http_process.start()
    https_process.start()

    # Keep the main process alive
    http_process.join()
    https_process.join()
