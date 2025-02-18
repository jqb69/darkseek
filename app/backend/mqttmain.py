from fastapi import FastAPI, Depends, HTTPException
from app.backend.api.search_api import search_manager
from app.backend.core.database import get_db, UserQuery
from sqlalchemy.orm import Session
from app.backend.schemas.request_models import QueryRequest
import json
import logging
import asyncio
from app.backend.api.mqtt_api import AsyncMQTTServer

# === Logging Configuration ===
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

# === FastAPI App Setup ===
app = FastAPI()

# === MQTT Server Instance ===
mqtt_server = AsyncMQTTServer()


# === Background Task to Start MQTT Server ===
@app.on_event("startup")
async def startup_event():
    """Start the MQTT server when the application starts."""
    asyncio.create_task(mqtt_server.start())
    logger.info("MQTT server started.")

@app.on_event("shutdown")
async def shutdown_event():
    """Stop the MQTT server when the application shuts down."""
    await mqtt_server.close_connection()
    logger.info("MQTT server stopped.")

# === MQTT-Based Streaming Endpoint ===
@app.post("/process_query/")
async def process_query(query_request: QueryRequest, db: Session = Depends(get_db)):
    """
    Process a query request and stream responses back to the client via MQTT.
    """
    try:
        session_id = query_request.session_id
        logger.info(f"Processing query for session: {session_id}")

        # Stream search and LLM responses
        async for chunk in search_manager.get_streaming_response(
            query_request.query,
            query_request.session_id,
            query_request.search_enabled,
            llm_name=query_request.llm_name,
            db=db,
        ):
            # Publish each chunk to the session-specific MQTT topic
            response_topic = f"chat/{session_id}/response"
            await mqtt_server.client.publish(response_topic, json.dumps(chunk))
            logger.info(f"Published chunk to {response_topic}: {chunk}")

        return {"status": "success", "message": "Query processed successfully."}

    except Exception as e:
        logger.error(f"Error processing query for session {session_id}: {e}", exc_info=True)
        error_message = {"error": "An error occurred while processing your request"}
        response_topic = f"chat/{query_request.session_id}/response"
        await mqtt_server.client.publish(response_topic, json.dumps(error_message))
        raise HTTPException(status_code=500, detail="Internal Server Error")

# === Heartbeat Mechanism ===
async def publish_heartbeat(interval: int = 30):
    """
    Periodically publish a heartbeat message to indicate the server is alive.
    """
    try:
        while True:
            heartbeat_topic = "server/heartbeat"
            heartbeat_message = {"status": "alive", "timestamp": time.time()}
            await mqtt_server.client.publish(heartbeat_topic, json.dumps(heartbeat_message))
            logger.info("Published heartbeat message.")
            await asyncio.sleep(interval)
    except Exception as e:
        logger.error(f"Failed to publish heartbeat: {e}", exc_info=True)

# === Background Task to Start Heartbeat ===
@app.on_event("startup")
async def start_heartbeat():
    """Start the periodic heartbeat task."""
    asyncio.create_task(publish_heartbeat(interval=30))
    logger.info("Heartbeat task started.")
