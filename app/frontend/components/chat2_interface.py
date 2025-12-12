# app/frontend/components/chat2_interface.py — FINAL ETERNAL VERSION (GEMINI-APPROVED)
import streamlit as st
import requests

from app.frontend.static.clientconfig import MQTT_URI, LLM_OPTIONS

def send_query(user_input: str, selected_llm: str, search_enabled: bool):
    payload = {
        "query": user_input,
        "session_id": st.session_state.get("session_id", "default"),
        "llm_name": selected_llm,
        "search_enabled": search_enabled,
        "user_id": st.session_state.get("username", "guest")
    }
    try:
        resp = requests.post(f"{MQTT_URI}/process_query", json=payload, timeout=90)
        resp.raise_for_status()
        return resp.json().get("content", "No response from backend.")
    except requests.exceptions.RequestException as e:
        return f"Connection failed: {e}"

def chat2_interface():
    if "messages" not in st.session_state:
        st.session_state.messages = []
    if "session_id" not in st.session_state:
        st.session_state.session_id = st.runtime.scriptrunner.get_session_id()

    with st.sidebar:
        st.title("DarkSeek Settings")
        st.info(f"Session: {st.session_state.session_id}")
        search = st.checkbox("Web Search", True)
        llm = st.selectbox("LLM", LLM_OPTIONS)

    st.title("DarkSeek")

    for msg in st.session_state.messages:
        with st.chat_message(msg["role"]):
            st.markdown(msg["content"])

    if prompt := st.chat_input("Ask me anything..."):
        st.session_state.messages.append({"role": "user", "content": prompt})
        with st.chat_message("user"):
            st.markdown(prompt)

        with st.chat_message("assistant"):
            with st.spinner("Thinking..."):
                response = send_query(prompt, llm, search)
            st.markdown(response)

        st.session_state.messages.append({"role": "assistant", "content": response})
