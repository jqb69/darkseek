
# app/backend/main.py
from fastapi import FastAPI, WebSocket, WebSocketDisconnect, Depends, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from app.backend.core.search_manager import search_manager
from app.backend.core.database import get_db, UserQuery
from sqlalchemy.orm import Session
from app.backend.schemas.request_models import QueryRequest
from app.backend.api.search2_api import search_api 
import json
import logging
import asyncio

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

app = FastAPI()

origins = [
    "http://localhost:8501",
    "http://localhost:8000",
]

app.add_middleware(
    CORSMiddleware,
    allow_origins=origins,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

@app.websocket("/ws/{session_id}")
async def websocket_endpoint(websocket: WebSocket, session_id: str, db: Session = Depends(get_db)):
    await websocket.accept()
    logger.info(f"Client connected: {session_id}")

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
            # Receive and validate incoming data
            try:
                data = await asyncio.wait_for(websocket.receive_text(), timeout=60)
                request_data = json.loads(data)
                query_request = QueryRequest(**request_data)
            except (json.JSONDecodeError, ValueError) as e:
                logger.warning(f"Invalid data received from session {session_id}: {e}")
                await websocket.send_text(json.dumps({"error": "Invalid request data"}))
                continue

            # Stream search and LLM responses
            try:
                async for chunk in search_manager.get_streaming_response(
                    query_request.query,
                    query_request.session_id,
                    query_request.search_enabled,
                    llm_name=query_request.llm_name,
                    db=db,
                ):
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


@app.get("/health")
async def health():
    return {"status": "ok"}            
