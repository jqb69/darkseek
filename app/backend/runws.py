# app/backend/runws.py
import multiprocessing
import uvicorn
import os

# The import string used by uvicorn
APP_MODULE = "app.backend.main:app"

def run_http():
    print("🚀 Starting Legacy HTTP on Port 8000...")
    uvicorn.run(APP_MODULE, host="0.0.0.0", port=8000)

def run_https():
    key = "/app/certs/tls.key"
    cert = "/app/certs/tls.crt"
    
    if os.path.exists(key) and os.path.exists(cert):
        print("🔐 Starting Secure HTTPS on Port 8443...")
        uvicorn.run(
            APP_MODULE, 
            host="0.0.0.0", 
            port=8443, 
            ssl_keyfile=key, 
            ssl_certfile=cert
        )
    else:
        print("⚠️ SSL Certs missing at /app/certs. Port 8443 idle.")

if __name__ == "__main__":
    p1 = multiprocessing.Process(target=run_http)
    p2 = multiprocessing.Process(target=run_https)
    p1.start()
    p2.start()
    p1.join()
    p2.join()
