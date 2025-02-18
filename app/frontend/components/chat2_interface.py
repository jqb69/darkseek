# app/frontend/components/chat_interface.py
import json
import aiomqtt
import requests
import re
import streamlit as st
import uuid
import logging
from app.frontend.static.clientconfig import (
    MQTT_BROKER_URI,
    MQTT_PORT,
    CA_CERT_PATH,
    CLIENT_CERT_PATH,
    CLIENT_KEY_PATH,
    LLM_OPTIONS,
    MAX_INPUT_LENGTH,
    MQTT_URI,
)
from app.frontend.components.chat_action import ChatActions  # Import ChatActions
import asyncio
import ssl
import time

# === Logging Configuration ===
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# === Session State Management ===
class SessionStateManager:
    @staticmethod
    def initialize_session_state():
        """Initialize session state variables."""
        defaults = {
            "messages": [],
            "session_id": str(uuid.uuid4()),
            "clear_chat_confirmed": False,
            "new_session_confirmed": False,
        }
        for key, value in defaults.items():
            if key not in st.session_state:
                st.session_state[key] = value

# === Asynchronous MQTT Client ===
class AsyncMQTTClient:
    def __init__(self):
        self.client = aiomqtt.Client()
        self.client.on_connect = self.on_connect
        self.client.on_message = self.on_message
        self.response_queue = asyncio.Queue()  # Use a queue for responses

    async def on_connect(self, client, userdata, flags, rc):
        try:
            if rc == 0:
                logger.info("Connected to MQTT broker")
                await client.subscribe(f"chat/#")  # Subscribe to all chat topics
            else:
                logger.error(f"Failed to connect to MQTT broker, return code: {rc}")
                raise ConnectionError(f"Failed to connect to MQTT broker, return code: {rc}")
        except Exception as e:
            logger.error(f"Error on connect: {e}")
            raise

    async def on_message(self, client, userdata, msg):
        try:
            response_data = json.loads(msg.payload)
            logger.info(f"Received response: {response_data}")
            if response_data.get("error"):
                logger.error(f"Error from server: {response_data['error']}")
                await self.response_queue.put("Sorry, I couldn't process your request at the moment.")
            else:
                await self.response_queue.put(response_data["content"])  # Push message to the queue
        except json.JSONDecodeError:
            logger.error("Failed to decode JSON response.")
            await self.response_queue.put("Sorry, I couldn't understand the server's response.")
        except Exception as e:
            logger.error(f"Error on message: {e}")
            await self.response_queue.put("Sorry, an error occurred.")

    async def get_response(self, timeout=10):
        """Get the response from the queue with a timeout."""
        try:
            response = await asyncio.wait_for(self.response_queue.get(), timeout)
            return response
        except asyncio.TimeoutError:
            logger.error("Response timeout.")
            return "The request timed out. Please try again."
        except Exception as e:
            logger.error(f"Failed to get response: {e}")
            return "Failed to get response. Please try again."

    async def connect(self):
        try:
            # Configure TLS settings using paths from clientconfig
            self.client.tls_set(
                ca_certs=CA_CERT_PATH,
                certfile=CLIENT_CERT_PATH,
                keyfile=CLIENT_KEY_PATH,
                tls_version=ssl.PROTOCOL_TLSv1_2
            )
            self.client.tls_insecure_set(False)  # Set to True only for testing with self-signed certificates

            # Connect to the broker
            await self.client.connect(MQTT_BROKER_URI, MQTT_PORT)
            await self.client.loop_start()  # Start the loop to process incoming messages
        except ConnectionError as e:
            logger.error(f"Failed to connect to MQTT broker: {e}")
            st.error("Could not connect to the MQTT broker. Please check your settings.")
            raise
        except Exception as e:
            logger.error(f"Failed to connect to MQTT broker: {e}")
            st.error("Failed to connect to the MQTT broker. Please try again.")
            raise

    async def publish_query(self, user_input, selected_llm, search_enabled):
        try:
            query_request = {
                "query": user_input,
                "session_id": st.session_state.session_id,
                "search_enabled": search_enabled,
                "llm_name": selected_llm,
            }
            # Send the query to the FastAPI endpoint
            response = requests.post(MQTT_URI + "/process_query/", json=query_request)
            if response.status_code == 200:
                logger.info(f"Query processed successfully: {query_request}")
            else:
                logger.error(f"Failed to process query: {response.text}")
                st.error("Failed to process your query. Please try again.")
        except Exception as e:
            logger.error(f"Failed to publish query: {e}")
            st.error("Failed to send your message. Please try again.")
            raise

    async def close_connection(self):
        """Close the MQTT connection."""
        try:
            await self.client.disconnect()
            logger.info("Disconnected from MQTT broker.")
        except Exception as e:
            logger.error(f"Failed to disconnect: {e}")
            raise

# === Chat Input Handling ===
class ChatInputHandler:
    @staticmethod
    async def handle_chat_input(selected_llm: str, search_enabled: bool, mqtt_client: AsyncMQTTClient):
        """Handle user input and generate assistant response."""
        try:
            user_input = await ChatInputHandler.get_user_input()
            if user_input:
                await ChatInputHandler.publish_query(user_input, selected_llm, search_enabled, mqtt_client)
                response = await ChatInputHandler.get_response(mqtt_client)
                if response:
                    st.session_state.messages.append({"role": "assistant", "content": response})
                    with st.chat_message("assistant"):
                        st.markdown(response)
        except Exception as e:
            logger.error(f"Error handling chat input: {e}")
            st.error("Failed to handle your input. Please try again.")

    @staticmethod
    async def get_user_input() -> str:
        """Get user input from the form."""
        try:
            with st.form("chat_form"):
                user_input = st.text_input("Ask me anything...", key="chat_input")
                submit_button = st.form_submit_button("Submit")
            if submit_button:
                if ChatInputHandler.validate_user_input(user_input):
                    return user_input
                else:
                    st.error(f"Please enter a valid message (max {MAX_INPUT_LENGTH} characters).")
                return ""
            return ""
        except Exception as e:
            logger.error(f"Error validating user input: {e}")
            st.error("Failed to send your message. Please try again.")
            raise

    @staticmethod
    async def publish_query(user_input: str, selected_llm: str, search_enabled: bool, mqtt_client: AsyncMQTTClient):
        """Publish the query to the MQTT broker."""
        try:
            await mqtt_client.publish_query(user_input, selected_llm, search_enabled)
        except Exception as e:
            logger.error(f"Failed to publish query: {e}")
            st.error("Failed to send your message. Please try again.")
            raise

    @staticmethod
    async def get_response(mqtt_client: AsyncMQTTClient) -> str:
        """Get the response from the MQTT broker using the queue."""
        try:
            response = await mqtt_client.get_response(timeout=10)
            return response
        except Exception as e:
                logger.error(f"Failed to get response: {e}")
            st.error("Failed to get response. Please try again.")
            raise

    

    def sanitize_input(user_input: str) -> str:
        """Sanitize user input to prevent injection attacks."""
        sanitized = re.sub(r"[^a-zA-Z0-9\s\?\.,!]", "", user_input)
        return sanitized.strip()

    @staticmethod
    def validate_user_input(user_input: str) -> bool:
        """Validate user input."""
        try:
            sanitized_input = sanitize_input(user_input)
            if not sanitized_input:
                logger.warning("Empty or invalid input detected.")
                return False
            if len(sanitized_input) > MAX_INPUT_LENGTH:
                logger.warning(f"Input exceeds character limit of {MAX_INPUT_LENGTH}.")
                return False
            return True
        except Exception as e:
            logger.error(f"Failed to validate user input: {e}")
            st.error("Failed to validate user input. Please try again.")
            raise

# === Sidebar Settings ===
class SidebarManager:
    @staticmethod
    def render_sidebar():
        """Render sidebar settings."""
        try:
            with st.sidebar:
                st.title("DarkSeek Settings")
                search_enabled = st.checkbox("Enable Web Search", value=True)
                selected_llm = st.selectbox("Select LLM", LLM_OPTIONS, index=0)  # Use centralized LLM options
                st.markdown("---")
                st.markdown("DarkSeek is an AI-powered chatbot...")
            return search_enabled, selected_llm
        except Exception as e:
            logger.error(f"Failed to render sidebar: {e}")
            st.error("Failed to render sidebar. Please try again.")
            raise

# === Message Display ===
class MessageDisplay:
    @staticmethod
    def display_messages():
        """Display chat messages."""
        try:
            for message in st.session_state.messages:
                with st.chat_message(message["role"]):
                    st.markdown(message["content"])
        except Exception as e:
            logger.error(f"Failed to display messages: {e}")
            st.error("Failed to display messages. Please try again.")
            raise

# === Chat Interface Function ===
async def chat_interface(session_id=None):
    mqtt_client = None
    try:
        if session_id is not None:
            st.session_state.session_id = session_id
        SessionStateManager.initialize_session_state()
        
        # Create an instance of the MQTT client
        mqtt_client = AsyncMQTTClient()
        await mqtt_client.connect()  # Connect to the MQTT broker

        search_enabled, selected_llm = SidebarManager.render_sidebar()

        st.title("DarkSeek")
        ChatActions.handle_clear_chat()
        ChatActions.handle_new_chat_session()
        await ChatInputHandler.handle_chat_input(selected_llm, search_enabled, mqtt_client)
        MessageDisplay.display_messages()

    except Exception as e:
        logger.error(f"Failed to run chat interface: {e}")
        st.error("Failed to run chat interface. Please try again.")
        raise
    finally:
        if mqtt_client:
            await mqtt_client.close_connection()


# Run the chat interface
#try:
#    await chat_interface()
#    st.experimental_rerun()
#except Exception as e:
#    logger.error(f"Failed to run chat interface: {e}")
#    st.error("Failed to run chat interface. Please try again.")


