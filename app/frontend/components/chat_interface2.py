# app/frontend/components/chat2_interface.py
import asyncio
import json
import aiomqtt
import streamlit as st
import uuid
import logging
import requests
from app.frontend.static.clientconfig import LLM_OPTIONS, MQTT_URI, MQTT_BROKER_HOST, MQTT_BROKER_PORT, MAX_INPUT_LENGTH

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
        }
        for key, value in defaults.items():
            if key not in st.session_state:
                st.session_state[key] = value

# === MQTT Client ===
class AsyncMQTTClient:
    def __init__(self):
        self.client = aiomqtt.Client(hostname=MQTT_BROKER_HOST, port=int(MQTT_BROKER_PORT), tls_context=True)
        self.response_queue = asyncio.Queue()

    async def connect(self):
        """Connect to the MQTT broker."""
        await self.client.connect()
        await self.client.subscribe("chat/#")
        asyncio.create_task(self.listen())

    async def listen(self):
        """Listen for MQTT messages."""
        async for message in self.client.messages:
            payload = message.payload.decode()
            try:
                response_data = json.loads(payload)
                await self.response_queue.put(response_data["content"])
            except json.JSONDecodeError:
                logger.error("Failed to decode MQTT message payload.")

    async def publish_query(self, user_input: str, selected_llm: str, search_enabled: bool):
        """Send query via HTTPS to the backend and wait for MQTT response."""
        query_request = {
            "query": user_input,
            "session_id": st.session_state.session_id,
            "search_enabled": search_enabled,
            "llm_name": selected_llm,
        }
        try:
            # Use HTTPS for the POST request
            response = requests.post(f"{MQTT_URI}/process_query/", json=query_request, verify=True)
            response.raise_for_status()
            logger.info(f"Query sent to {MQTT_URI}/process_query/: {query_request}")
            # Wait for response via MQTT
            assistant_response = await asyncio.wait_for(self.response_queue.get(), timeout=30)
            return assistant_response
        except requests.RequestException as e:
            logger.error(f"Failed to send query to {MQTT_URI}: {e}")
            return "Sorry, I couldn't connect to the server at the moment."
        except asyncio.TimeoutError:
            logger.error("Timeout waiting for MQTT response.")
            return "Sorry, no response received in time."

# === Chat Input Handling ===
class ChatInputHandler:
    @staticmethod
    def validate_user_input(user_input: str) -> bool:
        """Validate user input."""
        if not user_input.strip():
            logger.warning("Empty input detected.")
            return False
        if len(user_input) > MAX_INPUT_LENGTH:
            logger.warning(f"Input exceeds character limit of {MAX_INPUT_LENGTH}.")
            return False
        return True

    @staticmethod
    async def handle_chat_input(client: AsyncMQTTClient, selected_llm: str, search_enabled: bool):
        """Handle user input and generate assistant response."""
        user_input = st.chat_input("Ask me anything...", key="chat_input")
        if user_input:
            if ChatInputHandler.validate_user_input(user_input):
                with st.spinner("Generating response..."):
                    assistant_response = await client.publish_query(user_input, selected_llm, search_enabled)
                    st.session_state.messages.append({"role": "assistant", "content": assistant_response})
                    with st.chat_message("assistant"):
                        st.markdown(assistant_response)
            else:
                st.error(f"Please enter a valid message (max {MAX_INPUT_LENGTH} characters).")

# === Sidebar Settings ===
class SidebarManager:
    @staticmethod
    def render_sidebar():
        """Render sidebar settings."""
        with st.sidebar:
            st.title("DarkSeek Settings")
            search_enabled = st.checkbox("Enable Web Search", value=True)
            selected_llm = st.selectbox("Select LLM", LLM_OPTIONS, index=0)
            st.markdown("---")
            st.markdown("DarkSeek is an AI-powered chatbot...")
        return search_enabled, selected_llm

# === Message Display ===
class MessageDisplay:
    @staticmethod
    def display_messages():
        """Display chat messages."""
        for message in st.session_state.messages:
            with st.chat_message(message["role"]):
                st.markdown(message["content"])

# === Chat Interface Function ===
async def chat2_interface(session_id=None):
    """Main function to run the MQTT chat interface."""
    if session_id is not None:
        st.session_state.session_id = session_id
    SessionStateManager.initialize_session_state()
    search_enabled, selected_llm = SidebarManager.render_sidebar()

    client = AsyncMQTTClient()
    await client.connect()

    st.title("DarkSeek")
    MessageDisplay.display_messages()
    await ChatInputHandler.handle_chat_input(client, selected_llm, search_enabled)

# Run the async function
if __name__ == "__main__":
    asyncio.run(chat2_interface())
