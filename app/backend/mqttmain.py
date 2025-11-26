
# app/backend/mqttmain.py 
from fastapi import FastAPI, HTTPException
from app.backend.schemas.request_models import QueryRequest
from app.backend.api.mqtt_api import AsyncMQTTServer  # ← Only dependency
import json
import time
import logging
import asyncio

# === Logging ===
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

# === FastAPI App ===
app = FastAPI(title="DarkSeek Backend", version="1.0")

# === Global MQTT Server (handles ALL logic including DB) ===
mqtt_server = AsyncMQTTServer()

# === Startup: Start MQTT + Heartbeat ===
@app.on_event("startup")
async def startup_event():
    logger.info("DarkSeek backend starting...")
    asyncio.create_task(mqtt_server.start())
    asyncio.create_task(publish_heartbeat())
    logger.info("MQTT server + heartbeat launched")

# === Shutdown ===
@app.on_event("shutdown")
async def shutdown_event():
    logger.info("Shutting down...")
    await mqtt_server.close_connection()

# === Heartbeat ===
async def publish_heartbeat(interval: int = 30):
    while True:
        try:
            payload = {"type": "heartbeat", "timestamp": time.time()}
            await mqtt_server.client.publish("server/heartbeat", json.dumps(payload))
            await asyncio.sleep(interval)
        except Exception as e:
            logger.error(f"Heartbeat error: {e}")
            await asyncio.sleep(10)

# === HTTP → MQTT Bridge (NO database coupling here) ===
@app.post("/process_query/")
async def process_query(query_request: QueryRequest):
    """
    Client sends HTTP POST → we forward to MQTT → mqtt_api handles everything
    No DB, no Depends(), no core.database import
    """
    session_id = query_request.session_id
    logger.info(f"HTTP bridge: Forwarding query for session {session_id}")

    try:
        # Just forward the exact payload to MQTT
        topic = f"chat/{session_id}/query"
        await mqtt_server.client.publish(topic, query_request.model_dump_json())
        
        logger.info(f"Query forwarded to MQTT topic: {topic}")
        return {"status": "query_forwarded", "session_id": session_id}

    except Exception as e:
        logger.error(f"Failed to forward query: {e}", exc_info=True)
        error = {"error": "Failed to forward query to backend"}
        try:
            await mqtt_server.client.publish(
                f"chat/{session_id}/error",
                json.dumps(error)
            )
        except:
            pass
        raise HTTPException(status_code=500, detail="Backend unreachable")

# === Health Check ===
@app.get("/health")
async def health():
    "mqtt_connected": mqtt_server.is_connected()
    return {"status": "ok", "mqtt_connected": connected}
