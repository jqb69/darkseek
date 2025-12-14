# app/frontend/components/chat2_interface.py — FINAL ETERNAL VERSION (GEMINI-APPROVED)
import streamlit as st
import requests
import json
import time # Import time for simple timestamp or delay if needed
from app.frontend.static.clientconfig import MQTT_URI, LLM_OPTIONS

# The following two functions (get_mqtt_client and publish) are REMOVED 
# as they are replaced by the synchronous HTTP function send_query.

def ping_backend_test(user_id: str):
    """
    Executes a simple HTTP POST request to the backend's /ping endpoint to verify connectivity
    and service health before the user attempts a full query.
    """
    ping_url = f"{MQTT_URI}"
    initial_message = f"Hello backend, I am {user_id}"
    payload = {
        "message": initial_message,
        "user_id": user_id
    }
    
    st.markdown("---")
    st.markdown("### System Diagnostics")
    
    # CRITICAL URI VALIDATION CHECKS
    # 1. Warn if HTTPS is used for internal communication.
    if ping_url.startswith("https://"):
        st.warning(
            f"**URI PROTOCOL WARNING:** The backend URI ({ping_url}) is using HTTPS. "
            "For internal Kubernetes pod communication, you should usually use HTTP unless "
            "explicit TLS is configured. This may still cause issues."
        )

    # 2. Warn if HTTP is used but a custom port is missing (common for 8000/8080 services).
    # We check if the URI contains a colon after the initial "http://" prefix (meaning a port is specified).
    # If the URI contains less than two colons (one for the protocol, one for the port), the port is missing.
    if ping_url.startswith("http://") and ping_url.count(':') < 2:
        st.error(
            f"**URI PORT ERROR:** The backend URI ({ping_url}) is missing an explicit port number. "
            "Internal APIs (like FastAPI/Uvicorn) rarely run on default HTTP port 80. "
            "The correct URI should likely be `http://darkseek-backend-mqtt:8000` (or 8080/8888)."
        )
        # We can't proceed reliably if the URI is likely wrong, so we return False early.
        st.error("Cannot proceed with ping test due to incorrect URI format.")
        return False, "URI format error: Missing port number."

    # --- Proceed with Connection Test ---
    try:
        # Note: Using a shorter timeout for the ping test is often better than the query timeout
        with st.spinner(f"Pinging backend at {ping_url}..."):
            start_time = time.time()
            # Send initial greeting via HTTP POST
            resp = requests.post(ping_url, json=payload, timeout=5) 
            end_time = time.time()
            resp.raise_for_status() # Raise an HTTPError for bad responses (4xx or 5xx)
            
            response_json = resp.json()
            
            # The backend should reply with a specific message/status
            backend_reply = response_json.get("reply", "No reply key in response.")
            
            st.success(f"Backend Ping SUCCESS! ({int((end_time - start_time) * 1000)}ms)")
            st.code(f"Backend Reply: {backend_reply}", language="json")
            
            # Add the backend's successful reply to the chat board as the first message
            if "messages" not in st.session_state:
                st.session_state.messages = []
            
            # Ensure the ping result is a visible first message
            if not st.session_state.messages or st.session_state.messages[0].get("role") != "system":
                 st.session_state.messages.insert(0, {
                    "role": "system",
                    "content": f"**System Status: Online**\nBackend successfully initialized and replied:\n> {backend_reply}"
                })
            
            return True, None
            
    except requests.exceptions.Timeout:
        error_msg = f"Ping TIMEOUT (5s): Backend at {ping_url} did not respond. Check Network Policy or Backend Service Port."
        st.error(error_msg)
        return False, error_msg
    except requests.exceptions.ConnectionError as e:
        # This catches errors like 'Failed to establish a new connection' (DNS or unreachable service)
        error_msg = f"Ping CONNECTION ERROR: Failed to reach {ping_url}. Is the backend service running and accessible? Error: {e}"
        st.error(error_msg)
        return False, error_msg
    except requests.exceptions.HTTPError as e:
        error_msg = f"Ping HTTP ERROR: Backend at {ping_url} replied with status {e.response.status_code}. Response: {e.response.text}"
        st.error(error_msg)
        return False, error_msg
    except Exception as e:
        error_msg = f"Ping UNEXPECTED ERROR: {e}"
        st.error(error_msg)
        return False, error_msg
    finally:
        st.markdown("---")


def send_query(user_input: str, selected_llm: str, search_enabled: bool):
    """
    Sends the user query and settings to the backend processing service via HTTP POST.
    """
    payload = {
        "query": user_input,
        "session_id": st.session_state.get("session_id", "default_session"),
        "llm_name": selected_llm,
        "search_enabled": search_enabled,
        "user_id": st.session_state.get("username", "guest")
    }
    try:
        resp = requests.post(f"{MQTT_URI}/process_query", json=payload, timeout=90)
        resp.raise_for_status() 
        return resp.json().get("content", "Error: Backend returned an empty response.")
    except requests.exceptions.HTTPError as e:
        return f"HTTP Error: {e.response.status_code} - {e.response.text}"
    except Exception as e:
        return f"Connection Error: Failed to reach backend service. Check MQTT_URI. {e}"

def chat2_interface():
    """Renders the main chat interface using Streamlit components."""
    
    # Initialize session state for messages and session_id if they don't exist
    if "messages" not in st.session_state:
        st.session_state.messages = []
    if "session_id" not in st.session_state:
        st.session_state.session_id = st.runtime.script_requests.get_session_id()
    if "username" not in st.session_state:
        st.session_state.username = "guest"
        
    with st.sidebar:
        st.title("DarkSeek Settings")
        st.info(f"Session ID: {st.session_state.session_id}")
        
        # --- UI controls ---
        search = st.checkbox("Enable Web Search", value=True)
        llm = st.selectbox("Select LLM", LLM_OPTIONS if 'LLM_OPTIONS' in locals() else ["gemma_flash_2.0", "llama3.2"])
        
        # --- Run Backend Connectivity Test ---
        # The app should refresh if the test changes status.
        backend_ready, _ = ping_backend_test(st.session_state.username) 

    st.title("DarkSeek Chatbot")

    # Display chat history
    for msg in st.session_state.messages:
        with st.chat_message(msg["role"]):
            st.markdown(msg["content"])

    # Handle user input (Only enabled if backend is ready)
    if backend_ready:
        if prompt := st.chat_input("Ask me anything..."):
            # 1. Append user message
            st.session_state.messages.append({"role": "user", "content": prompt})
            
            # 2. Display user message immediately
            with st.chat_message("user"):
                st.markdown(prompt)

            # 3. Get assistant response
            with st.chat_message("assistant"):
                with st.spinner("Thinking..."):
                    response = send_query(prompt, llm, search)
                    
                # 4. Display assistant response
                st.markdown(response)
                
            # 5. Append assistant message to history
            st.session_state.messages.append({"role": "assistant", "content": response})
    else:
        st.warning("Chat is disabled until the backend connectivity test succeeds. Please check the System Diagnostics in the sidebar.")
