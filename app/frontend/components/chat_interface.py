import streamlit as st
import uuid
import logging
import asyncio
from app.backend.api.llm_api import LLMAPI
from app.backend.core.config import DEFAULT_LLM

# === Logging Configuration ===
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Instantiate llm_api
llm_api = LLMAPI()

# === Session State Management ===
class SessionStateManager:
    @staticmethod
    def initialize_session_state():
        """Initialize session state variables."""
        defaults = {
            "messages": [],
            "chat_started": False,
            "last_assistant_message": False,
            "session_id": str(uuid.uuid4()),
            "clear_chat_confirmed": False,
            "new_session_confirmed": False,
            "max_input_length": 500,
        }
        for key, value in defaults.items():
            if key not in st.session_state:
                st.session_state[key] = value


# === Sidebar Settings ===
class SidebarManager:
    @staticmethod
    def render_sidebar(llm_api):
        """Render sidebar settings."""
        with st.sidebar:
            st.title("DarkSeek Settings")
            search_enabled = st.checkbox("Enable Web Search", value=True)
            llm_options = list(llm_api.llms.keys())
            default_llm_index = (
                llm_options.index(DEFAULT_LLM) if DEFAULT_LLM in llm_options else 0
            )
            selected_llm = st.selectbox("LLM", llm_options, index=default_llm_index)
            st.markdown("---")
            st.markdown("DarkSeek is an AI-powered chatbot...")
        return search_enabled, selected_llm


# === Chat Actions ===
class ChatActions:
    @staticmethod
    def handle_clear_chat():
        """Handle clear chat button logic."""
        if st.button("Clear Chat"):
            st.session_state.clear_chat_confirmed = True

        if st.session_state.clear_chat_confirmed:
            confirm_clear_chat = st.checkbox("Are you sure you want to clear the chat?")
            if confirm_clear_chat:
                st.session_state.messages = []
                st.session_state.clear_chat_confirmed = False
                st.success("Chat cleared.")
            elif st.button("Cancel"):
                st.session_state.clear_chat_confirmed = False
                st.info("Clear chat cancelled.")

    @staticmethod
    def handle_new_chat_session():
        """Handle new chat session button logic."""
        if st.button("New Chat Session"):
            st.session_state.new_session_confirmed = True

        if st.session_state.new_session_confirmed:
            confirm_new_session = st.checkbox(
                "Are you sure you want to start a new chat session?"
            )
            if confirm_new_session:
                ChatActions.reset_chat_session()
                st.success("New chat session started!")
            elif st.button("Cancel"):
                st.session_state.new_session_confirmed = False
                st.info("New chat session cancelled.")

    @staticmethod
    def reset_chat_session():
        """Reset chat session."""
        st.session_state.messages = []
        st.session_state.chat_started = False
        st.session_state.last_assistant_message = False
        st.session_state.session_id = str(uuid.uuid4())
        st.session_state.new_session_confirmed = False


# === Message Display ===
class MessageDisplay:
    @staticmethod
    def display_messages():
        """Display chat messages."""
        for message in st.session_state.messages:
            with st.chat_message(message["role"]):
                st.markdown(message["content"])
                if message["role"] == "assistant" and "search_results" in message:
                    with st.expander("Search Results"):
                        for result in message["search_results"]:
                            st.markdown(f"[{result['title']}]({result['link']})")
                            st.write(result["snippet"])


# === Chat Input Handling ===
class ChatInputHandler:
    @staticmethod
    def validate_user_input(user_input: str, max_length: int) -> bool:
        """Validate user input."""
        if not user_input.strip():
            logger.warning("Empty input detected.")
            return False
        if len(user_input) > max_length:
            logger.warning(f"Input exceeds character limit of {max_length}.")
            return False
        return True

    @staticmethod
    def handle_chat_input(selected_llm: str, search_enabled: bool):
        """Handle user input and generate assistant response."""
        user_input = st.chat_input("What's up?", key="chat_input")
        if user_input:
            max_input_length = st.session_state.get("max_input_length", 500)
            if ChatInputHandler.validate_user_input(user_input, max_input_length):
                ChatProcessor.process_user_input(user_input, selected_llm, search_enabled)
            else:
                st.error(f"Invalid input. Please enter a valid message (max {max_input_length} characters).")


# === Chat Processing ===
class ChatProcessor:
    @staticmethod
    def get_suggestions(user_input: str, llm_name: str) -> list:
        """Get dynamic suggestions based on user input."""
        try:
            logger.info(f"Fetching suggestions for input: {user_input}")
            return llm_api.generate_suggestions(user_input, llm_name)
        except Exception as e:
            logger.error(f"Error fetching suggestions: {e}")
            st.error("Failed to fetch suggestions.")
            return []

    @staticmethod
    async def get_assistant_response(user_input: str, llm_name: str, search_enabled: bool) -> str:
        """Get a response from the assistant with error handling."""
        try:
            logger.info(f"Fetching assistant response for input: {user_input}")
            response = await llm_api.query_llm(user_input, [], llm_name)
            return response
        except Exception as e:
            logger.error(f"Error fetching assistant response: {e}")
            st.error("An error occurred while getting the assistant's response.")
            return "Sorry, I couldn't process your request at the moment."

    @staticmethod
    def process_user_input(user_input: str, selected_llm: str, search_enabled: bool):
        """Process user input and generate assistant response."""
        # Append user message to chat history
        st.session_state.messages.append({"role": "user", "content": user_input})
        with st.chat_message("user"):
            st.markdown(user_input)

        # Fetch suggestions based on user input
        suggestions = ChatProcessor.get_suggestions(user_input, selected_llm)
        if suggestions:
            st.write("Suggestions:")
            for suggestion in suggestions:
                st.markdown(f"* {suggestion}")

        # Handle user response to suggestions
        response = st.selectbox(
            "Select a suggestion or type your own response",
            ["Type my own response"] + suggestions,
            key="suggestion_response"
        )

        if response == "Type my own response":
            custom_response = st.text_area("Enter your response", key="custom_response")
            if custom_response:
                st.session_state.messages.append({"role": "user", "content": custom_response})
                with st.chat_message("user"):
                    st.markdown(custom_response)
        else:
            st.session_state.messages.append({"role": "user", "content": response})
            with st.chat_message("user"):
                st.markdown(response)

        # Generate assistant response
        with st.spinner("Generating response..."):
            assistant_response = asyncio.run(ChatProcessor.get_assistant_response(user_input, selected_llm, search_enabled))
            st.session_state.messages.append({"role": "assistant", "content": assistant_response})
            with st.chat_message("assistant"):
                st.markdown(assistant_response)


# === Run the Chat Interface ===
SessionStateManager.initialize_session_state()
search_enabled, selected_llm = SidebarManager.render_sidebar(llm_api)

st.title("DarkSeek")

ChatActions.handle_clear_chat()
ChatActions.handle_new_chat_session()

MessageDisplay.display_messages()
ChatInputHandler.handle_chat_input(selected_llm, search_enabled)
