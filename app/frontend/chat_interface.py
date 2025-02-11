import streamlit as st
import json
from app.backend.api.llm_api import llm_api
from app.backend.core.config import DEFAULT_LLM

def chat_interface(session_id):
    """Displays the chat interface."""
    
    with st.sidebar:
        st.title("DarkSeek Settings")
        search_enabled = st.checkbox("Enable Web Search", value=True)
        llm_options = list(llm_api.llms.keys())
        default_llm_index = llm_options.index(DEFAULT_LLM) if DEFAULT_LLM in llm_options else 0
        selected_llm = st.selectbox("LLM", llm_options, index=default_llm_index)
        st.markdown("---")
        st.markdown("DarkSeek is an AI-powered chatbot...")
    
    st.title("DarkSeek")
    
    # Display existing messages
    for message in st.session_state.messages:
        with st.chat_message(message["role"]):
            st.markdown(message["content"])
            if message["role"] == "assistant" and "search_results" in message:
                with st.expander("Search Results"):
                    for result in message["search_results"]:
                        st.markdown(f"[{result['title']}]({result['link']})")
                        st.write(result["snippet"])
    
    # Load socket.io client script
    try:
        with open("app/frontend/static/js/socketio_client.js", "r") as f:  # Corrected path
            js_code = f.read()
        st.components.v1.html(f'<script>{js_code}</script>', height=0)
    except FileNotFoundError:
        st.error("Socket.IO client script not found. Please check the file path.")

    # Add Socket.IO event listener
    st.components.v1.html(
        '''
        <script src="https://cdn.socket.io/4.6.0/socket.io.min.js" integrity="sha384-c79GN5VsunZvi+Q/WObgk2in0CbZsHnjEqvFxC5DxHn9lTfNce2WW6h2pH6u/kF+" crossorigin="anonymous"></script>
        ''',
        height=0,
    )

    if prompt := st.chat_input("What is up?", key="chat_input"):
        st.session_state.messages.append({"role": "user", "content": prompt})
        with st.chat_message("user"):
            st.markdown(prompt)
    
        with st.chat_message("assistant"):
            st.session_state.chat_started = True
            message_placeholder = st.empty()
    
            request_data = {
                "query": prompt,
                "session_id": session_id,
                "search_enabled": search_enabled,
                "llm_name": selected_llm,
            }
    
            st.components.v1.html(
                f'''
                <script>
                    const event = new CustomEvent('streamlit:session_data', {{
                        detail: {json.dumps(request_data)}
                    }});
                    window.dispatchEvent(event);
                </script>
                ''',
                height=0,
            )
    
    if st.session_state.chat_started:
        if "last_assistant_message" not in st.session_state or st.session_state.get("last_assistant_message") == False:
            st.session_state.messages.append({
                "role": "assistant",
                "content": "...",
                "search_results": [],
            })
            st.session_state["last_assistant_message"] = True
    else:
        if "last_assistant_message" in st.session_state:
            st.session_state["last_assistant_message"] = False
