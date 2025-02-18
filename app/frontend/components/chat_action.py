#app/frontend/app/components/chat_action.py
# === Chat Actions ===

import streamlit as st
import uuid

class ChatActions:
    @staticmethod
    def handle_clear_chat():
        """Handle clear chat button logic."""
        if st.button("Clear Chat"):
            st.session_state.clear_chat_confirmed = True

        if st.session_state.get("clear_chat_confirmed", False):
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

        if st.session_state.get("new_session_confirmed", False):
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
