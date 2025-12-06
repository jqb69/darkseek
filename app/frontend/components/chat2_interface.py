# app/frontend/components/chat2_interface.py
import asyncio
import json
import aiomqtt
import streamlit as st
import uuid
import logging
import requests
# Import client config to use MQTT settings and max input length
from app.frontend.static.clientconfig import (
    LLM_OPTIONS, 
    MQTT_BROKER_HOST, 
    MQTT_BROKER_PORT, 
    MQTT_URI, # Used for the HTTPS POST request
    MAX_INPUT_LENGTH
)

# === Logging Configuration ===
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# === MQTT Client (Needs to be persisted across reruns) ===
def get_mqtt_client():
    """Gets or creates the persistent AsyncMQTTClient instance."""
    if 'mqtt_client' not in st.session_state:
        st.session_state.mqtt_client = AsyncMQTTClient()
    return st.session_state.mqtt_client

class AsyncMQTTClient:
    def __init__(self):
        # NOTE: tls_context=True relies on having proper certs available in the k8s volume
        self.client = aiomqtt.Client(hostname=MQTT_BROKER_HOST, port=int(MQTT_BROKER_PORT), tls_context=True)
        self.response_queue = asyncio.Queue()
        self.connected = False

    async def connect(self):
        """Connect to the MQTT broker and start listener only if not already connected."""
        if self.connected:
            return
        
        try:
            await self.client.connect()
            # Subscribe to the response topic based on the session ID
            await self.client.subscribe(f"chat/response/{st.session_state.session_id}") 
            asyncio.create_task(self.listen())
            self.connected = True
            logger.info("MQTT Client connected and listening.")
        except Exception as e:
            logger.error(f"MQTT connection failed: {e}")
            st.error("Could not connect to the real-time service. Please check the backend configuration.")

    async def listen(self):
        """Listen for MQTT messages."""
        async for message in self.client.messages:
            # We are only interested in messages for our session's response topic
            if message.topic.value.startswith(f"chat/response/{st.session_state.session_id}"):
                payload = message.payload.decode()
                try:
                    # Assuming the backend sends the full response in the content key
                    response_data = json.loads(payload)
                    content = response_data.get("content", "Error: Empty response content.")
                    await self.response_queue.put(content)
                    logger.info("Received MQTT response for session.")
                except json.JSONDecodeError:
                    logger.error("Failed to decode MQTT message payload.")
                except Exception as e:
                    logger.error(f"Error processing MQTT message: {e}")

    async def publish_query(self, user_input: str, selected_llm: str, search_enabled: bool):
        """Send query via HTTPS to the backend and wait for MQTT response."""
        query_request = {
            "query": user_input,
            "session_id": st.session_state.session_id,
            "search_enabled": search_enabled,
            "llm_name": selected_llm,
            "user_id": st.session_state.username # Pass username for backend logging/tracking
        }
        
        # --- HTTPS POST REQUEST ---
        try:
            # Use HTTPS for the POST request to trigger the backend processing
            response = requests.post(f"{MQTT_URI}/process_query", json=query_request, verify=True, timeout=10)
            response.raise_for_status()
            logger.info(f"Query sent to {MQTT_URI}/process_query: {response.status_code}")
            
            # --- WAIT FOR MQTT RESPONSE ---
            assistant_response = await asyncio.wait_for(self.response_queue.get(), timeout=60) # Increased timeout
            return assistant_response
        
        except requests.RequestException as e:
            logger.error(f"Failed to send query to {MQTT_URI}: {e}")
            return "Sorry, I couldn't connect to the server at the moment (HTTP Error)."
        except asyncio.TimeoutError:
            logger.error("Timeout waiting for MQTT response.")
            return "Sorry, no real-time response received in time from the service."
        except Exception as e:
            logger.error(f"An unexpected error occurred during query processing: {e}")
            return f"An unexpected error occurred: {e}"

# === Chat Input Handling ===
class ChatInputHandler:
    @staticmethod
    def validate_user_input(user_input: str) -> bool:
        """Validate user input and check query limits."""
        # 1. Input validation
        if not user_input.strip():
            st.error("Please enter a non-empty message.")
            return False
        if len(user_input) > MAX_INPUT_LENGTH:
            st.error(f"Input exceeds character limit of {MAX_INPUT_LENGTH}.")
            return False
            
        # 2. Limit Check (NEW FEATURE INTEGRATION)
        limit = st.session_state.query_limit
        count = st.session_state.query_count
        if limit > 0 and count >= limit: 
            st.error(f"Query limit reached! You have used {count} out of {limit} queries.")
            # If a message was just added, we want to show it before the limit error
            # This is complex in Streamlit, so we just return False and let the sync handler rerun.
            return False
            
        return True

    @staticmethod
    def handle_chat_input_sync(client: AsyncMQTTClient, selected_llm: str, search_enabled: bool):
        """
        Synchronous handler for Streamlit lifecycle. 
        It uses asyncio.run() to execute the async publish operation.
        """
        # Disable input if limit is reached
        input_disabled = st.session_state.query_limit > 0 and st.session_state.query_count >= st.session_state.query_limit
        user_input = st.chat_input("Ask me anything...", key="chat_input", disabled=input_disabled)
        
        if user_input:
            
            # Add user message to history immediately for display
            st.session_state.messages.append({"role": "user", "content": user_input})
            
            # Validate and check limits BEFORE API call
            if not ChatInputHandler.validate_user_input(user_input):
                st.rerun() # Rerun to display error/limit message
                return

            with st.spinner("Generating response..."):
                try:
                    # Use asyncio.run to execute the async part in a synchronous Streamlit context
                    assistant_response = asyncio.run(client.publish_query(user_input, selected_llm, search_enabled))
                    
                    # Update state after a successful (or attempted) query
                    # Only increment if the response doesn't indicate a hard system error
                    if "Sorry, I couldn't connect" not in assistant_response and "A critical system error" not in assistant_response:
                         st.session_state.query_count += 1
                         logger.info(f"Query successful. Count: {st.session_state.query_count}")
                    
                except Exception as e:
                    logger.error(f"Error running async task: {e}")
                    assistant_response = "A critical system error occurred while processing your request."
                    
                # Add assistant response to history and trigger rerun
                st.session_state.messages.append({"role": "assistant", "content": assistant_response})
                st.rerun()


# === Sidebar Settings ===
class SidebarManager:
    @staticmethod
    def render_sidebar():
        """Render sidebar settings."""
        with st.sidebar:
            st.title("DarkSeek Settings")
            st.caption(f"Connected to MQTT Host: `{MQTT_BROKER_HOST}:{MQTT_BROKER_PORT}`")
            
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

# === Chat Interface Function (Synchronous) ===
def chat2_interface(session_id=None):
    """Main function to run the chat interface (now synchronous for Streamlit)."""
    if session_id is not None:
        st.session_state.session_id = session_id

    search_enabled, selected_llm = SidebarManager.render_sidebar()
    
    client = get_mqtt_client()
    if not client.connected:
        try:
            # Run the initial connection attempt
            asyncio.run(client.connect())
        except Exception:
            # Error message is already displayed in connect()
            pass 

    st.title("DarkSeek")
    MessageDisplay.display_messages()
    
    # Call the synchronous handler which wraps the async logic
    ChatInputHandler.handle_chat_input_sync(client, selected_llm, search_enabled)
