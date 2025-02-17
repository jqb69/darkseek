# darkseek
#AI Powered Chatbot
# --- README.md ---
# See below

# --- setup.sh ---
"""
#!/bin/bash

# Create a virtual environment (optional but recommended)
python3 -m venv venv
source venv/bin/activate

# Install dependencies
pip install -r requirements.txt

# Database setup (if using PostgreSQL)
# 1. Make sure PostgreSQL is installed and running
# 2. Create the database and user (if needed):
#    sudo -u postgres psql
#    CREATE DATABASE darkseekdb;
#    CREATE USER user WITH PASSWORD 'password';
#    GRANT ALL PRIVILEGES ON DATABASE darkseekdb TO user;
#    \q

echo "Setup complete.  You can now run the application using 'python run.py'"

# To run with Docker:
# 1. Make sure Docker and Docker Compose are installed
# 2. Create a .env file based on .env.example and fill in your API keys.
# 3. Run: docker-compose up --build
"""
# --- app/tests/test_backend.py ---
# Basic example of unit tests. Expand significantly!
import pytest
from ..backend.core.utils import sanitize_query
from ..backend.core.config import MAX_QUERY, GOOGLE_API_KEY, GOOGLE_CSE_ID
from ..backend.api.search_api import SearchAPI  # Import your class
from ..backend.api.llm_api import LLMAPI
# Add more imports as needed.


@pytest.mark.parametrize("input_query, expected_output", [
    ("  hello world  ", "hello world"),
    ("Multiple   Spaces", "multiple spaces"),
    ("", ""),
])
def test_sanitize_query(input_query, expected_output):
    assert sanitize_query(input_query) == expected_output


@pytest.mark.asyncio  # Mark the test as asynchronous
async def test_search_api_google_success():
    # IMPORTANT: Use a *mock* API key and CSE ID for testing, *NOT* your real ones
    search_api = SearchAPI(google_api_key="dummy_key", google_cse_id="dummy_cse_id")  # Use dummy keys
    # Mock the requests.get method to return a predefined response
    with pytest.MonkeyPatch().context() as m:  # Use pytest's MonkeyPatch
        class MockResponse: # Create a mock response.
            def __init__(self, json_data, status_code):
                self.json_data = json_data
                self.status_code = status_code
            def json(self):
                return self.json_data
            def raise_for_status(self):
                if self.status_code != 200:
                    raise requests.exceptions.HTTPError(f"Status code: {self.status_code}")
        mock_results = {
              "items": [
                  {"title": "Result 1", "link": "http://example.com/1", "snippet": "Snippet 1"},
                  {"title": "Result 2", "link": "http://example.com/2", "snippet": "Snippet 2"},
              ]
          }

        m.setattr(requests, "get", lambda *args, **kwargs: MockResponse(mock_results, 200))
        results = await search_api.google_search("test query")
        assert isinstance(results, list)
        assert len(results) == 2  # Check length.
        assert results[0]["title"] == "Result 1"


@pytest.mark.asyncio  # Mark the test as asynchronous
async def test_search_api_google_failure():
    search_api = SearchAPI(google_api_key="dummy_key", google_cse_id="dummy_cse_id")  # Use dummy keys
    with pytest.MonkeyPatch().context() as m:
        class MockResponse:
            def __init__(self, json_data, status_code):
                self.json_data = json_data
                self.status_code = status_code
            def json(self):
                return self.json_data

            def raise_for_status(self):
                if self.status_code != 200:
                    raise requests.exceptions.HTTPError(f"Status code: {self.status_code}")
        m.setattr(requests, "get", lambda *args, **kwargs: MockResponse({}, 500))
        results = await search_api.google_search("test query"
        )
        assert results == []


@pytest.mark.asyncio

mport asyncio
import websockets
import json

async def websocket_client():
    uri = "ws://localhost:8000/ws/12345"  # Replace with your server URL and session ID
    async with websockets.connect(uri) as websocket:
        print("Connected to WebSocket server")

        # Send a query request
        query_request = {
            "query": "What is the capital of France?",
            "session_id": "12345",
            "search_enabled": True,
            "llm_name": "gemma_flash_2.0"
        }
        await websocket.send(json.dumps(query_request))
        print("Sent query request:", query_request)

        # Receive and process responses
        try:
            while True:
                response = await websocket.recv()
                response_data = json.loads(response)
                print("Received response:", response_data)

                # Handle different types of responses
                if response_data.get("type") == "heartbeat":
                    print("Heartbeat received")
                elif response_data.get("type") == "llm_response":
                    print("LLM Response Chunk:", response_data["content"])
                elif response_data.get("error"):
                    print("Error:", response_data["error"])
                    break
        except websockets.exceptions.ConnectionClosed:
            print("WebSocket connection closed")



    app/backend/Dockerfile: This Dockerfile builds the backend image. It installs only the backend dependencies and runs the FastAPI application using Uvicorn.

    app/backend/requirements.txt: Contains only the backend dependencies (FastAPI, Uvicorn, SQLAlchemy, etc.).

    app/frontend/Dockerfile: This Dockerfile builds the frontend image. It installs only the frontend dependency (Streamlit) and runs the Streamlit application.

    app/frontend/requirements.txt: Contains only streamlit.

    app/frontend/streamlit_app.py:

        socketio_client.js Path: Now correctly reads from static folder.

        Import paths: Updated to reflect new project structure

    app/frontend/static/js/socketio_client.js: The WebSocket URL now correctly points to ws://localhost:8000, which is the backend's address. This is crucial for the frontend to connect to the backend.

    docker-compose.yaml:

        backend Service: Renamed the web service to backend to be more descriptive. The build context and dockerfile are updated to point to the backend's Dockerfile.

        frontend Service: Added a new service for the frontend. The build context and dockerfile point to the frontend's Dockerfile.

        Dependencies: The frontend service now depends on the backend service. This ensures that the backend is started before the frontend.

        Removed run.py.

How to Run (with Docker Compose):

    cd to the darkseek directory (the project root).

    Make sure you have a .env file in the project root (based on .env.example) with your API keys and other settings.

    Run docker-compose up --build. This will:

        Build the backend and frontend Docker images.
        **Key Structural Points (Verbal Explanation - to ensure clarity):**

1.  **Top-Level (`darkseek/`):**  The root directory of the project.  Contains project-level files like `docker-compose.yaml`, `.env.example`, `README.md` and `setup.sh`.

2.  **`app/` Directory:**  This is the main application directory, containing all the source code. It's further subdivided into `backend` and `frontend`.

3.  **`app/backend/`:**  All server-side code (FastAPI application).
    *   **`api/`:** Modules for interacting with external APIs (Google, DuckDuckGo, Hugging Face).
    *   **`core/`:**  The core application logic.
        *   `config.py`: Configuration settings (environment variables, constants).
        *   `database.py`: Database connection setup (SQLAlchemy).
        *   `models.py`: Database models (SQLAlchemy).
        *   `search_manager.py`:  The central orchestrator for search, LLM interaction, and caching.
        *   `utils.py`: Utility functions.
        *   `caching.py`: Redis caching logic.
    *   **`schemas/`:** Pydantic models for request validation.
    *   **`main.py`:** The FastAPI application's entry point (where the WebSocket endpoint is defined).
    *   **`Dockerfile`:**  Instructions for building the *backend* Docker image.
    *   **`requirements.txt`:** Python dependencies for the *backend*.

4.  **`app/frontend/`:** All client-side code (Streamlit application).
    *   **`static/`:** Static assets.
        *   **`css/`:** CSS stylesheets.
        *   **`js/`:** JavaScript files (including `socketio_client.js`).
    *   **`streamlit_app.py`:** The Streamlit application's entry point.
    *   **`Dockerfile`:** Instructions for building the *frontend* Docker image.
    *   **`requirements.txt`:** Python dependencies for the *frontend* (mainly just `streamlit`).

5. **Separation of Concerns**:
   * The project structure uses a clear separation of concerns to ensure each file and folder has a clear and defined purpose.


        Start containers for the backend, frontend, database (PostgreSQL), and Redis.

        The frontend (Streamlit) will be accessible at http://localhost:8501.

        The backend (FastAPI) will be running internally on port 8000 (and the frontend will connect to it via WebSockets).

This setup provides a clean, well-structured, and deployable application with separate frontend and backend components. It addresses all the previous issues and incorporates best practices for Docker, dependency management, and deployment. The next major step would be to add comprehensive testing.
