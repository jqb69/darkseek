# app/frontend/streamlit_app.py (Corrected - Main App Entry Point)
import streamlit as st
import secrets
import json # Not used, but imported for consistency.
from app.frontend.components.chat_interface import chat_interface  # Correct import
from app.frontend.components.login import login_interface  # Correct import

def generate_session_id():
    return secrets.token_hex(16)

def inject_javascript():
    """Inject necessary JavaScript for WebSocket communication."""
    st.components.v1.html(
        '<script src="https://cdn.socket.io/4.6.0/socket.io.min.js" integrity="sha384-c79GN5VsunZvi+Q/WObgk2in0CbZsHnjEqvFxC5DxHn9lTfNce2WW6h2pH6u/kF+" crossorigin="anonymous"></script>',
        height=0,
    )
    try:
        with open("app/frontend/static/js/socketio_client.js", "r") as f:
            js_code = f.read()
        st.components.v1.html(f'<script>{js_code}</script>', height=0)
    except FileNotFoundError:
        st.error("JavaScript file not found. Please check the file path.")

def inject_css():
    """Inject necessary CSS styles."""
    try:
        with open("app/frontend/static/css/styles.css", "r") as f:
            st.markdown(f"<style>{f.read()}</style>", unsafe_allow_html=True)
    except FileNotFoundError:
        st.error("CSS file not found. Please check the file path.")


def main():
    st.set_page_config(page_title="DarkSeek", page_icon=":mag:", layout="wide")

   for key in ["session_id", "messages", "chat_started", "last_assistant_message"]:
    if key not in st.session_state:
        st.session_state[key] = None if key == "last_assistant_message" else False if key == "chat_started" else [] if key == "messages" else generate_session_id()
# --- Inject JavaScript (for WebSocket communication) ---
    inject_javascript()
    inject_css()
    #simplify
    # --- Routing (Login or Chat) ---
    if st.session_state.logged_in:
        chat_interface(st.session_state.session_id)  # Show chat interface
    else:
        login_interface()  # Show login interface
    
    

if __name__ == "__main__":
    main()
