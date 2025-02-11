import streamlit as st
import secrets
import json
from app.backend.api.llm_api import llm_api
from app.backend.core.config import DEFAULT_LLM
from app.frontend.chat_interface import chat_interface

def generate_session_id():
    return secrets.token_hex(16)

def main():
    st.set_page_config(page_title="DarkSeek", page_icon=":mag:", layout="wide")

    if 'session_id' not in st.session_state:
        st.session_state.session_id = generate_session_id()
    if "messages" not in st.session_state:
        st.session_state.messages = []
    if "chat_started" not in st.session_state:
        st.session_state.chat_started = False
    if "last_assistant_message" not in st.session_state:
        st.session_state.last_assistant_message = False

    with open("app/frontend/static/css/styles.css", "r") as f:
        st.markdown(f"<style>{f.read()}</style>", unsafe_allow_html=True)

    chat_interface(st.session_state.session_id)

if __name__ == "__main__":
    main()
