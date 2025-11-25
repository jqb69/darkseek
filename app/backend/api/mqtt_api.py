#app/backend/api/mqtt_api
import aiomqtt
import ssl
import json
import logging
import os
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
        self.client = Client()
        self.client.on_connect = self.on_connect
        self.client.on_message = self.on_message

    async def on_connect(self, client, userdata, flags, rc):
        if rc == 0:
            logger.info("Connected to MQTT broker")
            await client.subscribe("chat/#")  # Subscribe to all chat topics
        else:
            logger.error(f"Failed to connect to MQTT broker, return code: {rc}")

    async def on_message(self, client, userdata, msg):
        try:
            message = json.loads(msg.payload)
            logger.info(f"Received message: {message}")
            response = await self.process_message(message)
            logger.info(f"Processed message: {response}")

            # Publish the response to the session-specific topic
            session_id = message.get("session_id")
            if session_id:
                response_topic = f"chat/{session_id}/response"
                await client.publish(response_topic, json.dumps(response))
                logger.info(f"Published response to {response_topic}: {response}")
        except json.JSONDecodeError:
            logger.error("Failed to decode JSON message.")
        except Exception as e:
            logger.error(f"Error processing message: {e}", exc_info=True)

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
            # Configure TLS settings
            self.client.tls_set(
                ca_certs=CA_CERT_PATH,
                certfile=SERVER_CERT_PATH,
                keyfile=SERVER_KEY_PATH,
                tls_version=ssl.PROTOCOL_TLSv1_2
            )
            self.client.tls_insecure_set(False)  # Set to True only for testing with self-signed certificates

            # Connect to the broker
            await self.client.connect(MQTT_BROKER_URI, MQTT_PORT)
            logger.info("MQTT server connected.")
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

    async def close_connection(self):
        """Close the MQTT connection."""
        try:
            await self.client.disconnect()
            logger.info("Disconnected from MQTT broker.")
        except Exception as e:
            logger.error(f"Failed to disconnect from MQTT broker: {e}", exc_info=True)
            raise

# === Main Function ===
#async def main():
#    mqtt_server = AsyncMQTTServer()
#    try:
#        await mqtt_server.start()
#    finally:
#        await mqtt_server.close_connection()


    
