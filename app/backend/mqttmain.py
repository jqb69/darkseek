#app/backend/api/mqttmain.py
import aiomqtt
import ssl
import json
import logging
import os
import asyncio
#from app.backend.core.database import SessionLocal
from app.backend.core.search_manager import search_manager
from app.backend.schemas.request_models import QueryRequest
from logging.handlers import RotatingFileHandler
from aiomqtt import Client

# === Logging Configuration ===
def setup_logger():
    logger = logging.getLogger(__name__)
    logger.setLevel(logging.INFO)

    # Create a rotating file handler (max 5 MB per file, 5 backup files)
    log_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "logs")
    os.makedirs(log_dir, exist_ok=True)  # Ensure logs directory exists
    log_file_path = os.path.join(log_dir, "backend.log")

    file_handler = RotatingFileHandler(log_file_path, maxBytes=5 * 1024 * 1024, backupCount=5)
    file_formatter = logging.Formatter("%(asctime)s - %(name)s - %(levelname)s - %(message)s")
    file_handler.setFormatter(file_formatter)

    # Add a console handler for real-time logs
    console_handler = logging.StreamHandler()
    console_formatter = logging.Formatter("%(asctime)s - %(levelname)s - %(message)s")
    console_handler.setFormatter(console_formatter)

    # Attach handlers to the logger
    logger.addHandler(file_handler)
    logger.addHandler(console_handler)

    return logger

logger = setup_logger()

# === MQTT Broker Configuration ===
from app.backend.core.config import (
    MQTT_BROKER_URI,
    MQTT_PORT,
    CA_CERT_PATH,
    SERVER_CERT_PATH,
    SERVER_KEY_PATH,
)

# === Asynchronous MQTT Server ===
class AsyncMQTTServer:
    def __init__(self):
        self._connected = False
        self.tls_params = aiomqtt.TLSParameters(
            ca_certs=CA_CERT_PATH,
            certfile=SERVER_CERT_PATH,
            keyfile=SERVER_KEY_PATH,
            tls_version=ssl.PROTOCOL_TLSv1_2,
            insecure=False
        )
        self.health_file = "/tmp/mqtt-healthy"

    async def start(self):
        """aiomqtt context manager with exponential backoff retry logic."""
        reconnect_interval = 2  # Initial delay in seconds
        max_interval = 60
        
        try: # Outer try to catch process-level interruptions
            while True:
                try:
                    logger.info(f"Connecting to {MQTT_BROKER_URI}:{MQTT_PORT}...")
                    
                    async with aiomqtt.Client(
                        hostname=MQTT_BROKER_URI,
                        port=MQTT_PORT,
                        tls_params=self.tls_params,
                    ) as client:
                        self._connected = True
                        logger.info("✅ MQTT connected via TLS")
                        
                        # Set health signal
                        with open(self.health_file, "w") as f:
                            f.write("healthy")

                        reconnect_interval = 2 # Reset backoff on success

                        async with client.messages() as messages:
                            await client.subscribe("chat/#")
                            async for message in messages:
                                await self.on_message(client, message)
                                
                except (aiomqtt.MqttError, Exception) as e:
                    self._connected = False
                    # Remove health file immediately so K8s stops routing
                    if os.path.exists(self.health_file):
                        os.unlink(self.health_file)
                    
                    logger.error(f"MQTT Connection Error: {e}. Retrying in {reconnect_interval}s...")
                    await asyncio.sleep(reconnect_interval)
                    reconnect_interval = min(reconnect_interval * 2, max_interval)
                    
        finally:
            # This runs only when the while loop is broken (e.g., SIGTERM)
            if os.path.exists(self.health_file):
                os.unlink(self.health_file)
            logger.info("MQTT Server process shutting down.")

    def is_connected(self) -> bool:
        """Return True if currently connected to MQTT broker."""
        return self._connected

    async def on_message(self, client, msg):
        topic = str(msg.topic)
        if topic.startswith("chat/") and topic.endswith("/query"):
            session_id = "unknown" # Default fallback
            try:
                payload = json.loads(msg.payload)
                query_request = QueryRequest(**payload)
                session_id = query_request.session_id
    
                # ✅ CLEAN - search_manager handles DB internally now
                async for chunk in search_manager.get_streaming_response(
                    query=query_request.query,
                    session_id=session_id,
                    search_enabled=query_request.search_enabled,
                    llm_name=query_request.llm_name
                ):
                    await client.publish(
                        f"chat/{session_id}/response",
                        json.dumps(chunk)
                    )
            except json.JSONDecodeError:
                logger.error("Failed to decode JSON message.")
            except Exception as e:
                logger.error(f"MQTT processing error: {e}")
                # Attempt to notify frontend of the error
                try:
                    await client.publish(f"chat/{session_id}/error", json.dumps({"error": str(e)}))
                except:
                    pass


    async def process_message(self, message):
        """
        Process the incoming message and generate a response.
        This is where you would integrate with an LLM or perform a web search.
        """
        try:
            query = message.get("query", "")
            session_id = message.get("session_id", "")
            search_enabled = message.get("search_enabled", False)
            llm_name = message.get("llm_name", "default")

            # Example: Simulate a response from an LLM
            response_content = f"Processed query '{query}' using {llm_name}. Search enabled: {search_enabled}"
            logger.debug(f"Generated response content: {response_content}")
            return {"content": response_content}
        except Exception as e:
            logger.error(f"Error processing message: {e}", exc_info=True)
            return {"error": "Failed to process the query."}

    

# === Main async Function ===
async def main():
    mqtt_server = AsyncMQTTServer()
    try:
        await mqtt_server.start()
    except KeyboardInterrupt:
        pass
    #finally:
    #    await mqtt_server.close_connection()

if __name__ == "__main__":
    asyncio.run(main())

    
