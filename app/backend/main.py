# app/backend/main.py
from fastapi import FastAPI, WebSocket, WebSocketDisconnect, Depends, HTTPException, status
from fastapi.middleware.cors import CORSMiddleware
from app.backend.core.search_manager import search_manager
#from app.backend.core.database import get_db
from app.backend.schemas.request_models import QueryRequest
# Removed all MQTT imports (aiomqtt, ssl, config)
from sqlalchemy.orm import Session
from typing import Dict, Any
import json
import logging
import asyncio
import uuid # Only kept for potential session/request logging

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

# --- FastAPI Setup ---
app = FastAPI(title="DarkSeek WS/HTTP Facade (Local Processing)")

# Replace your current origins list in main.py
origins = [
    # Your actual Streamlit frontend (K8s service/ingress)
    "http://darkseek-frontend.default.svc.cluster.local:8501",
    "http://darkseek-frontend:8501",
    
    # External IP (from `kubectl get svc darkseek-frontend`)
    "http://35.188.178.123:8501",  # Replace with your actual IP
    
    # Ingress domain (if using)
    "https://darkseek.yourdomain.com",
    
    # Local dev only
    "http://localhost:8501",
    "http://localhost:3000"
]

app.add_middleware(
    CORSMiddleware,
    allow_origins=origins,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# NOTE: All MQTT related startup/shutdown events, global state, and receiver loops are removed.

# --- REST API Endpoint (Synchronous - Local Processing) ---

@app.post("/api/chat", response_model=Dict[str, Any])
async def synchronous_chat_endpoint(query_request: QueryRequest):
    """
    Handles standard HTTP POST requests. 
    Processes the query locally using search_manager and returns the full response.
    """
    session_id = query_request.session_id
    logger.info(f"REST /api/chat: Starting local query for session {session_id}")

    try:
        full_content = ""
        
        # Define an inner async function to collect the full response (Non-blocking local execution)
        async def collect_response():
            nonlocal full_content
            # 1. Execute the query manager locally
            response_generator = search_manager.get_streaming_response(
                query=query_request.query,
                session_id=session_id,
                search_enabled=query_request.search_enabled,
                llm_name=query_request.llm_name
            )

            # 2. Accumulate all chunks into a single response string
            async for chunk in response_generator:
                full_content += chunk.get("content", "")
                # We can also handle potential errors or end markers here if needed

        await collect_response()
        
        # 3. Return the full, accumulated response over HTTP
        return {"content": full_content, "session_id": session_id}

    except Exception as e:
        logger.error(f"Error processing synchronous chat query for {session_id}: {e}", exc_info=True)
        # Use a 500 status code for internal errors
        raise HTTPException(status_code=500, detail=f"Internal server error: {str(e)}")

# --- WebSocket Endpoint (Streaming Chat - Local Processing) ---

@app.websocket("/ws/{session_id}")
async def websocket_endpoint(websocket: WebSocket, session_id: str):
    """
    Handles streaming chat requests. 
    Processes the query locally and streams chunks directly back over the WebSocket.
    """
    await websocket.accept()
    logger.info(f"Client connected: {session_id}")

    # Heartbeat logic (retained for connection maintenance)
    async def send_heartbeat():
        try:
            while True:
                await asyncio.sleep(30)
                await websocket.send_text(json.dumps({"type": "heartbeat", "session_id": session_id}))
        except (WebSocketDisconnect, asyncio.CancelledError):
            logger.info(f"Heartbeat stopped for session: {session_id}")
        except Exception as e:
            logger.error(f"Error in heartbeat for session {session_id}: {e}", exc_info=True)

    heartbeat_task = asyncio.create_task(send_heartbeat())

    try:
        while True:
            # 1. Receive and validate incoming data
            try:
                # Use a timeout on receive to detect dropped connections faster than the heartbeat
                data = await asyncio.wait_for(websocket.receive_text(), timeout=60) 
                request_data = json.loads(data)
                query_request = QueryRequest(**request_data)
            except (json.JSONDecodeError, ValueError) as e:
                logger.warning(f"Invalid data received from session {session_id}: {e}")
                await websocket.send_text(json.dumps({"error": "Invalid request data"}))
                continue
            
            # 2. Stream search and LLM responses (Local execution)
            try:
                async for chunk in search_manager.get_streaming_response(
                    query_request.query,
                    query_request.session_id,
                    query_request.search_enabled,
                    llm_name=query_request.llm_name
                ):
                    # 3. Stream chunk directly back to the client
                    await websocket.send_text(json.dumps(chunk))
            except Exception as e:
                logger.error(f"Error streaming response for session {session_id}: {e}", exc_info=True)
                await websocket.send_text(json.dumps({"error": "An error occurred while processing your request"}))

    except (WebSocketDisconnect, asyncio.TimeoutError):
        logger.info(f"Client disconnected or timed out: {session_id}")
    except Exception as e:
        logger.error(f"Unexpected error in WebSocket connection for session {session_id}: {e}", exc_info=True)
        await websocket.send_text(json.dumps({"error": "An unexpected error occurred"}))
    finally:
        # Clean up heartbeat task
        heartbeat_task.cancel()
        try:
            await heartbeat_task
        except asyncio.CancelledError:
            logger.info(f"Heartbeat task cancelled for session: {session_id}")

# --- Health Check Endpoint ---
@app.get("/health")
async def health():
    return {"status": "ok"}
