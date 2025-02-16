#app/backend/main.py
from fastapi import FastAPI, WebSocket, WebSocketDisconnect, Depends, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from .core.search_manager import search_manager
from .core.database import get_db, UserQuery
from sqlalchemy.orm import Session
from .schemas.request_models import QueryRequest
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
                await websocket.send_text(json.dumps({"type": "heartbeat"}))
        except (WebSocketDisconnect, asyncio.CancelledError):
            logger.info(f"Heartbeat stopped for session: {session_id}")
        except Exception as e:
            logger.error(f"Error in heartbeat for session {session_id}: {e}", exc_info=True)

    heartbeat_task = asyncio.create_task(send_heartbeat())

    try:
        while True:
            data = await asyncio.wait_for(websocket.receive_text(), timeout=60)  # Timeout for inactivity
            try:
                request_data = json.loads(data)
                query_request = QueryRequest(**request_data)
            except json.JSONDecodeError as e:
                logger.warning(f"Invalid JSON received: {e}")
                await websocket.send_text(json.dumps({"error": "Invalid JSON format"}))
                continue
            except ValidationError as e:
                logger.warning(f"Request validation error: {e}")
                await websocket.send_text(json.dumps({"error": f"Invalid request: {e}"}))
                continue

            try:
                async for chunk in search_manager.get_streaming_response(
                    query_request.query,
                    query_request.session_id,
                    query_request.search_enabled,
                    llm_name=query_request.llm_name,
                    db=db,
                ):
                    await websocket.send_text(json.dumps(chunk))
            except HTTPException as e:
                logger.error(f"HTTP error processing request: {e}", exc_info=True)
                await websocket.send_text(json.dumps({"error": str(e)}))
            except Exception as e:
                logger.exception(f"Error processing request: {e}")
                await websocket.send_text(json.dumps({"error": "An internal server error occurred"}))

    except (WebSocketDisconnect, asyncio.TimeoutError):
        logger.info(f"Client disconnected or timed out: {session_id}")
    except Exception as e:
        logger.error(f"Unexpected error in WebSocket connection: {e}", exc_info=True)
        await websocket.send_text(json.dumps({"error": "An unexpected error occurred"}))
    finally:
        heartbeat_task.cancel()
