# app/frontend/streamlit_app.py (Corrected - Main App Entry Point)
import streamlit as st
import secrets
# The provided code used an alias chat_interface, but the file defines chat2_interface.
# We will import the actual function name.
from app.frontend.components.chat2_interface import chat2_interface
from app.frontend.components.login import login_interface 
# Import the constants for easy display if needed
from app.frontend.static.clientconfig import MAX_GUEST_QUERIES, MAX_REGULAR_QUERIES

def generate_session_id():
    return secrets.token_hex(16)

def inject_javascript():
    """Inject necessary JavaScript for WebSocket communication."""
    # Assuming standard relative path from where Streamlit is run
    st.components.v1.html(
        '<script src="https://cdn.socket.io/4.6.0/socket.io.min.js" xintegrity="sha384-c79GN5VsunZvi+Q/WObgk2in0CbZsHnjEqvFxC5DxHn9lTfNce2WW6h2pH6u/kF+" crossorigin="anonymous"></script>',
        height=0,
    )
    try:
        # Note: Streamlit struggles with relative paths inside components.v1.html(). 
        # For simplicity in this environment, we assume the user has this deployed correctly.
        with open("/static/js/socketio_client.js", "r") as f:
            js_code = f.read()
        st.components.v1.html(f'<script>{js_code}</script>', height=0)
    except FileNotFoundError:
        st.error("JavaScript file (socketio_client.js) not found. Please check the file path.")

def inject_css():
    """Inject necessary CSS styles."""
    try:
        with open("/static/css/styles.css", "r") as f:
            st.markdown(f"<style>{f.read()}</style>", unsafe_allow_html=True)
    except FileNotFoundError:
        st.error("CSS file (styles.css) not found. Please check the file path.")


def main():
    st.set_page_config(page_title="DarkSeek", page_icon=":mag:", layout="wide")
    
    # --- BUG FIX: Initializing missing state keys and adding auth keys ---
    initial_state = {
        "session_id": generate_session_id(),
        "messages": [],
        "chat_started": False,
        "last_assistant_message": None,
        # CRITICAL BUG FIX: Add authentication/limit keys that the whole app relies on
        "logged_in": False, 
        "username": None,
        "display_name": None,
        "query_limit": 0,
        "query_count": 0,
    }
    
    for key, default_value in initial_state.items():
        if key not in st.session_state:
            st.session_state[key] = default_value

    inject_javascript()
    inject_css()

    # --- Routing (Login or Chat) ---
    if st.session_state.logged_in:
        # Correctly call the imported function
        chat2_interface(st.session_state.session_id) 
    else:
        login_interface() 
    
    # --- Sidebar Status Display (for logged in users) ---
    if st.session_state.logged_in:
        with st.sidebar:
            st.title("User Status")
            st.success(f"Logged in as: {st.session_state.display_name}")
            
            queries_left = st.session_state.query_limit - st.session_state.query_count
            st.info(f"Queries Left: {queries_left} / {st.session_state.query_limit}")
            
            if st.session_state.username == 'guest':
                st.caption(f"Guest limit is {MAX_GUEST_QUERIES}.")
            else:
                st.caption(f"Regular limit is {MAX_REGULAR_QUERIES}.")
            
            # Simple logout button
            if st.button("Logout", key="app_logout_btn"):
                st.session_state.clear()
                st.rerun()
            st.markdown("---")


if __name__ == "__main__":
    main()
