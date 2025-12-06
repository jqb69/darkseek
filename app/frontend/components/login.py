# app/frontend/components/login.py
import streamlit as st
import time
# Import authentication constants from clientconfig
from app.frontend.static.clientconfig import (
    MAX_GUEST_QUERIES, 
    MAX_REGULAR_QUERIES, 
    GUEST_USER, 
    GUEST_PASSWORD
)

def authenticate(username, password):
    """
    Checks user credentials and sets up session state accordingly.
    
    This function incorporates the required guest/regular mode logic.
    """

    # Guest Login
    if username == GUEST_USER and password == GUEST_PASSWORD:
        st.session_state.logged_in = True
        st.session_state.username = GUEST_USER
        st.session_state.display_name = "Guest User 👤"
        st.session_state.query_limit = MAX_GUEST_QUERIES
        st.session_state.query_count = 0
        return True

    # Placeholder for Regular User (any other non-empty credentials)
    # In a real app, this would check a database/API.
    if username and password and username != GUEST_USER:
        st.session_state.logged_in = True
        st.session_state.username = username
        st.session_state.display_name = f"User: {username.capitalize()} ✨"
        st.session_state.query_limit = MAX_REGULAR_QUERIES
        st.session_state.query_count = 0
        return True
    
    return False


def login_interface():
    """Renders the login form."""
    st.title("DarkSeek Login")
    st.markdown("""
        ### Access Control & Query Limits
        
        1.  **Guest Mode:** Limited to **5 queries**.
        2.  **Regular Mode:** Limited to **150 queries** (30x the guest limit).
    """)
    
    with st.form("login_form"):
        st.markdown(f"**Guest Mode:** Use `user: {GUEST_USER}`, `pass: {GUEST_PASSWORD}`")
        
        username = st.text_input("Username", key="login_user")
        password = st.text_input("Password", type="password", key="login_pass")
        submit_button = st.form_submit_button("Login")

        if submit_button:
            if authenticate(username, password):
                st.success("Login successful! Redirecting to chat...")
                time.sleep(0.5)
                st.rerun()
            else:
                st.error("Invalid credentials. Try 'guest' and 'whatever' for limited access.")
