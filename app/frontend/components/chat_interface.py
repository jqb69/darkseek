#app/foontend/components/chat_interface.py
import asyncio
import json
import websockets
import streamlit as st
import uuid
import logging
from app.frontend.static.clientconfig import LLM_OPTIONS, WEBSOCKET_URI, MAX_INPUT_LENGTH

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


# === WebSocket Client ===
class WebSocketClient:
    @staticmethod
    async def send_query(user_input: str, selected_llm: str, search_enabled: bool) -> str:
        """
        Send user query to the backend via WebSocket and receive the assistant's response.
        
        Args:
            user_input (str): The user's query.
            selected_llm (str): The selected language model name.
            search_enabled (bool): Whether search functionality is enabled.
        
        Returns:
            str: The assistant's response.
        """
        uri = WEBSOCKET_URI + st.session_state.session_id  # Use centralized WebSocket URI
        try:
            async with websockets.connect(uri) as websocket:
                logger.info("Connected to WebSocket server")

                # Prepare the query request payload
                query_request = {
                    "query": user_input,
                    "session_id": st.session_state.session_id,
                    "search_enabled": search_enabled,
                    "llm_name": selected_llm,
                }

                # Send the query request to the backend
                await websocket.send(json.dumps(query_request))
                logger.info(f"Sent query request: {query_request}")

                # Receive and process responses
                full_response = ""
                try:
                    while True:
                        response = await websocket.recv()
                        response_data = json.loads(response)
                        logger.info(f"Received response: {response_data}")

                        # Handle different types of responses
                        if response_data.get("type") == "heartbeat":
                            logger.info("Heartbeat received")
                        elif response_data.get("type") == "llm_response":
                            chunk = response_data["content"]
                            full_response += chunk
                            logger.info(f"LLM Response Chunk: {chunk}")
                        elif response_data.get("error"):
                            logger.error(f"Error from server: {response_data['error']}")
                            return "Sorry, I couldn't process your request at the moment."
                except websockets.exceptions.ConnectionClosed:
                    logger.warning("WebSocket connection closed")
                
                return full_response
        except Exception as e:
            logger.error(f"Failed to connect to WebSocket server: {e}")
            return "Sorry, I couldn't connect to the server at the moment."


# === Chat Input Handling ===
class ChatInputHandler:
    @staticmethod
    def validate_user_input(user_input: str) -> bool:
        """Validate user input."""
        if not user_input.strip():
            logger.warning("Empty input detected.")
            return False
        if len(user_input) > MAX_INPUT_LENGTH:  # Use centralized max input length
            logger.warning(f"Input exceeds character limit of {MAX_INPUT_LENGTH}.")
            return False
        return True

    @staticmethod
    def handle_chat_input(selected_llm: str, search_enabled: bool):
        """Handle user input and generate assistant response."""
        user_input = st.chat_input("Ask me anything...", key="chat_input")
        if user_input:
            if ChatInputHandler.validate_user_input(user_input):
                with st.spinner("Generating response..."):
                    assistant_response = asyncio.run(WebSocketClient.send_query(user_input, selected_llm, search_enabled))
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
            selected_llm = st.selectbox("Select LLM", LLM_OPTIONS, index=0)  # Use centralized LLM options
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
def chat_interface():
    """Main function to run the chat interface."""
    SessionStateManager.initialize_session_state()
    search_enabled, selected_llm = SidebarManager.render_sidebar()

    st.title("DarkSeek")

    MessageDisplay.display_messages()
    ChatInputHandler.handle_chat_input(selected_llm, search_enabled)
