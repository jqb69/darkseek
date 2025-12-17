# app/frontend/components/chat2_interface.py — FINAL ETERNAL VERSION (GEMINI-APPROVED)
import streamlit as st
import requests
import uuid 
from app.frontend.static.clientconfig import HTTP_BASE_API, LLM_OPTIONS

# The following two functions (get_mqtt_client and publish) are REMOVED 
# as they are replaced by the synchronous HTTP function send_query.

def ping_backend_test(user_id: str):
    """
    Executes a simple HTTP POST request to the backend's /api/chat endpoint to verify 
    connectivity and service health before the user attempts a full query.
    
    Returns: (bool: success_status, str: error_message_or_None)
    """
    ping_url = f"{HTTP_BASE_API}"
    st.info(f"HTTP_BASE_API= {ping_url}")
    
    st.markdown("---")
    st.markdown("### System Diagnostics")
    
    # CRITICAL URI VALIDATION CHECKS (Retained for diagnostic help)
    if ping_url.startswith("https://"):
        st.warning(
            f"**URI PROTOCOL WARNING:** The backend URI ({ping_url}) is using HTTPS. "
            "For internal Kubernetes pod communication, you should usually use HTTP unless "
            "explicit TLS is configured. This may still cause issues."
        )

    if ping_url.startswith("http://") and ping_url.count(':') < 2:
        st.error(
            f"**URI PORT ERROR:** The backend URI ({ping_url}) is missing an explicit port number."
            " Internal APIs (like FastAPI/Uvicorn) rarely run on default HTTP port 80. "
            "The correct URI should likely be `http://darkseek-backend-mqtt:8001` (or 8080/8888)."
        )
        st.error("Cannot proceed with ping test due to incorrect URI format.")
        return False, "URI format error: Missing port number."

    # --- Proceed with Connection Test ---
    try:
        with st.spinner(f"Pinging backend at {ping_url}/api/chat..."):
            test_query = f"Greetings, I am {user_id}. Respond briefly with any random name you choose"
            payload = {
                "query": test_query,
                "session_id": f"ping-{user_id}-{uuid.uuid4()}", # Uses unique UUID for ping test
                "search_enabled": False,
                "llm_name": LLM_OPTIONS[0],
            }
            # Send the test payload directly to /api/chat
            test_resp = requests.post(f"{ping_url}/api/chat", json=payload, timeout=30)
            
            if test_resp.status_code == 200:
                response = test_resp.json().get("content", "No response")
                with st.chat_message("assistant"):
                    st.markdown(response)
                st.success("Backend connected and responding!")
                
                # Ensure success message and True return are only here
                st.success("Backend ping test completed successfully!") 
                return True, None
            else:
                # Return False and detailed error immediately on failure status code
                error_msg = f"Backend error {test_resp.status_code}: {test_resp.text}"
                st.error(error_msg)
                return False, error_msg

    except requests.exceptions.Timeout:
        error_msg = f"Ping TIMEOUT (30s): Backend at {ping_url} did not respond. Check Network Policy or Backend Service Port."
        st.error(error_msg)
        return False, error_msg
    except requests.exceptions.ConnectionError as e:
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
        # FIX: Removed 'user_id' from the payload for guaranteed compatibility with QueryRequest
    }
    try:
        resp = requests.post(f"{HTTP_BASE_API}/api/chat", json=payload, timeout=90)
        # Raise for status handles 4xx/5xx responses as exceptions
        resp.raise_for_status() 
        return resp.json().get("content", "Error: Backend returned an empty response.")
    except requests.exceptions.HTTPError as e:
        # Return the error details to the user
        return f"HTTP Error: {e.response.status_code} - {e.response.text}"
    except Exception as e:
        return f"Connection Error: Failed to reach backend service. Check HTTP_BASE_API. {e}"

def chat2_interface():
    """Renders the main chat interface using Streamlit components."""
    
    # Initialize session state for messages and session_id if they don't exist
    if "messages" not in st.session_state:
        st.session_state.messages = []
    
    # FIX: Use a safe, unique UUID for session initialization
    if "session_id" not in st.session_state:
        st.session_state.session_id = f"ui-{uuid.uuid4()}"
        
    if "username" not in st.session_state:
        st.session_state.username = "guest"
        
    with st.sidebar:
        st.title("DarkSeek Settings")
        st.info(f"Session ID: {st.session_state.session_id}")
        
        # --- UI controls ---
        search = st.checkbox("Enable Web Search", value=True)
        llm = st.selectbox("Select LLM", LLM_OPTIONS)
        
        # --- Run Backend Connectivity Test ---
        # FIX: Cache the result of ping_backend_test so it only runs once per session
        if "backend_ready" not in st.session_state:
             st.session_state.backend_ready, _ = ping_backend_test(st.session_state.username) 
        
        # Use the cached state for the rest of the script execution
        backend_ready = st.session_state.backend_ready 

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
