# app/backend/runws.py
import multiprocessing
import uvicorn
import os

def run_http():
    print("🚀 Starting Legacy HTTP on Port 8000...")
    uvicorn.run("main:app", host="0.0.0.0", port=8000)

def run_https():
    key = "/app/certs/tls.key"
    cert = "/app/certs/tls.crt"
    
    if os.path.exists(key) and os.path.exists(cert):
        print("🔐 Starting Secure HTTPS on Port 8443...")
        uvicorn.run(
            "main:app", 
            host="0.0.0.0", 
            port=8443, 
            ssl_keyfile=key, 
            ssl_certfile=cert
        )
    else:
        print("⚠️ SSL Certificates not found in /app/certs. Port 8443 will not start.")

if __name__ == "__main__":
    # Create processes for both listeners
    p1 = multiprocessing.Process(target=run_http)
    p2 = multiprocessing.Process(target=run_https)
    
    p1.start()
    p2.start()
    
    # Keep the main process alive
    p1.join()
    p2.join()
