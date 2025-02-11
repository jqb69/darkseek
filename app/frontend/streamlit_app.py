# app/frontend/streamlit_app.py (Corrected - Main App Entry Point)
import streamlit as st
import secrets
import json # Not used, but imported for consistency.
from app.frontend.components.chat_interface import chat_interface  # Correct import
from app.frontend.components.login import login_interface  # Correct import

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
# --- Inject JavaScript (for WebSocket communication) ---
    st.components.v1.html(
        '<script src="https://cdn.socket.io/4.6.0/socket.io.min.js" integrity="sha384-c79GN5VsunZvi+Q/WObgk2in0CbZsHnjEqvFxC5DxHn9lTfNce2WW6h2pH6u/kF+" crossorigin="anonymous"></script>',
        height=0,
    )
    with open("app/frontend/static/js/socketio_client.js", "r") as f:
        js_code = f.read()
    st.components.v1.html(f'<script>{js_code}</script>', height=0)

    # --- Routing (Login or Chat) ---
    if st.session_state.logged_in:
        chat_interface(st.session_state.session_id)  # Show chat interface
    else:
        login_interface()  # Show login interface
    with open("app/frontend/static/css/styles.css", "r") as f:
        st.markdown(f"<style>{f.read()}</style>", unsafe_allow_html=True)

    

if __name__ == "__main__":
    main()
