#app/backend/api/mqtt_api
import aiomqtt
import ssl
import json
import logging
import os
from app.backend.core.database import SessionLocal
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
        self.client = Client(MQTT_BROKER_URI)   # ← fixed
        self._connected = False   # ← ADD THIS
        self.client.on_connect = self.on_connect
        self.client.on_message = self.on_message
        self.client.on_disconnect = self.on_disconnect  # ← ADD THIS

    async def on_connect(self, client, userdata, flags, rc):
        if rc == 0:
            self._connected = True
            logger.info("Connected to MQTT broker")
            await client.subscribe("chat/#")  # Subscribe to all chat topics
        else:
            logger.error(f"Failed to connect to MQTT broker, return code: {rc}")

    def is_connected(self) -> bool:
        """Return True if currently connected to MQTT broker."""
        return self._connected

    async def on_message(self, client, userdata, msg):
        if msg.topic.startswith("chat/") and msg.topic.endswith("/query"):
            try:
                payload = json.loads(msg.payload)
                query_request = QueryRequest(**payload)
                session_id = query_request.session_id

                # DB session created HERE and only here
                db = SessionLocal()
                try:
                    async for chunk in search_manager.get_streaming_response(
                        query=query_request.query,
                        session_id=session_id,
                        search_enabled=query_request.search_enabled,
                        llm_name=query_request.llm_name,
                        db=db,
                    ):
                        await client.publish(
                            f"chat/{session_id}/response",
                            json.dumps(chunk)
                        )
                finally:
                    db.close()
            except json.JSONDecodeError:
                logger.error("Failed to decode JSON message.")
            except Exception as e:
                logger.error(f"MQTT processing error: {e}")
                await client.publish(f"chat/{session_id}/error", json.dumps({"error": str(e)}))

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

    async def connect(self):
        try:
            await self.client.connect(
                host=MQTT_BROKER_URI,
                port=MQTT_PORT,
                tls_params=aiomqtt.TLSParameters(
                    ca_certs=CA_CERT_PATH,
                    certfile=SERVER_CERT_PATH,
                    keyfile=SERVER_KEY_PATH,
                    tls_version=ssl.PROTOCOL_TLSv1_2,
                    insecure=False
                )
            )
            logger.info("MQTT server connected with TLS.")
        except Exception as e:
            logger.error(f"Failed to connect to MQTT broker: {e}", exc_info=True)
            raise

    async def start(self):
        try:
            await self.connect()
            logger.info("Starting MQTT server loop...")
            await self.client.loop_forever()  # Keep the server running
        except KeyboardInterrupt:
            logger.info("Shutting down MQTT server...")
        except Exception as e:
            logger.error(f"Failed to start MQTT server: {e}", exc_info=True)
            raise
    
    async def on_disconnect(self, client, userdata, rc):
        self._connected = False
        logger.info("Disconnected from MQTT broker")
    
 
    # ← Replace disconnect() with terminate():
    async def close_connection(self):
        try:
            await self.client.terminate()   # ← NOT disconnect()
            logger.info("MQTT connection terminated.")
        except Exception as e:
            logger.error(f"Failed to terminate MQTT: {e}")

# === Main Function ===
#async def main():
#    mqtt_server = AsyncMQTTServer()
#    try:
#        await mqtt_server.start()
#    finally:
#        await mqtt_server.close_connection()


    
