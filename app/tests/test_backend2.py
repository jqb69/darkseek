# app/tests/test_backend.py
import pytest
from ..backend.core.utils import sanitize_query, generate_query_hash
from ..backend.core.config import MAX_QUERY, GOOGLE_API_KEY, GOOGLE_CSE_ID
from ..backend.api.search_api import SearchAPI
from ..backend.api.llm_api import LLMAPI
from ..backend.core.search_manager import SearchManager
from ..backend.core.caching import CacheManager
from ..backend.core.database import get_db, UserQuery, Base
import requests
import json
from unittest.mock import AsyncMock, patch  # Import unittest.mock
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

# Use an in-memory SQLite database for testing
TEST_DATABASE_URL = "sqlite://"  # In-memory SQLite

engine = create_engine(
    TEST_DATABASE_URL,
    connect_args={"check_same_thread": False},  # Required for SQLite with threading
    poolclass=StaticPool,  # Use a single connection for simplicity
)
TestingSessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)

Base.metadata.create_all(bind=engine)


def override_get_db():
    db = TestingSessionLocal()
    try:
        yield db
    finally:
        db.close()

# Fixture for a clean database session
@pytest.fixture()
def db():
    """
    Provides a clean database session for each test, and handles rollback
    to ensure each test is independent.
    """
    connection = engine.connect()
    transaction = connection.begin()
    session = TestingSessionLocal(bind=connection)
    yield session
    session.close()
    transaction.rollback()
    connection.close()


@pytest.mark.parametrize("input_query, expected_output", [
    ("  hello world  ", "hello world"),
    ("Multiple   Spaces", "multiple spaces"),
    ("", ""),
])
def test_sanitize_query(input_query, expected_output):
    assert sanitize_query(input_query) == expected_output


@pytest.mark.asyncio
async def test_search_api_google_success():
    search_api = SearchAPI(google_api_key="dummy_key", google_cse_id="dummy_cse_id")
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

        mock_results = {
            "items": [
                {"title": "Result 1", "link": "http://example.com/1", "snippet": "Snippet 1"},
                {"title": "Result 2", "link": "http://example.com/2", "snippet": "Snippet 2"},
            ]
        }

        m.setattr(requests, "get", lambda *args, **kwargs: MockResponse(mock_results, 200))
        results = await search_api.google_search("test query")
        assert isinstance(results, list)
        assert len(results) == 2
        assert results[0]["title"] == "Result 1"


@pytest.mark.asyncio
async def test_search_api_google_failure():
    search_api = SearchAPI(google_api_key="dummy_key", google_cse_id="dummy_cse_id")
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
        results = await search_api.google_search("test query")
        assert results == []


@pytest.mark.asyncio
async def test_search_api_duckduckgo_success():
    search_api = SearchAPI()
    with pytest.MonkeyPatch().context() as m:
        class MockResponse:
            def __init__(self, json_data, status_code):
                self.json_data = json_data
                self.status_code = status_code

            def json(self):
                return self.json_data

            def raise_for_status(self):
                if self.status_code != 200:
                    raise requests.exceptions.HTTPError()

        mock_results = {
            'RelatedTopics': [
                {'Text': 'Result 1', 'FirstURL': 'http://example.com/1'},
                {'Text': 'Result 2', 'FirstURL': 'http://example.com/2'}
            ]
        }
        m.setattr(requests, 'get', lambda *args, **kwargs: MockResponse(mock_results, 200))
        results = await search_api.duckduckgo_search("test query")
        assert len(results) == 2
        assert results[0]['title'] == 'Result 1'


@pytest.mark.asyncio
async def test_search_api_duckduckgo_failure():
    search_api = SearchAPI()
    with pytest.MonkeyPatch().context() as m:
        class MockResponse:
            def __init__(self, json_data, status_code):
                self.json_data = json_data
                self.status_code = status_code

            def json(self):
                return self.json_data

            def raise_for_status(self):
                if self.status_code != 200:
                    raise requests.exceptions.HTTPError()

        m.setattr(requests, 'get', lambda *args, **kwargs: MockResponse({}, 404))  # Mock a 404
        results = await search_api.duckduckgo_search("test")
        assert results == []



@pytest.mark.asyncio
async def test_llm_api_query():
    llm_api_instance = LLMAPI()
    mock_llm = AsyncMock()
    mock_llm.ainvoke.return_value = {'text': 'Mocked LLM response'}
    with patch.object(llm_api_instance, '_get_llm', return_value=mock_llm):
        response = await llm_api_instance.query_llm("test query", [])
    assert response == "Mocked LLM response"
    mock_llm.ainvoke.assert_called_once()

@pytest.mark.asyncio
async def test_search_manager_get_response_no_cache():
    mock_search_api = AsyncMock()
    mock_llm_api = AsyncMock()

    mock_search_results = [
        {"title": "Result 1", "link": "http://example.com/1", "snippet": "Snippet 1"},
        {"title": "Result 2", "link": "http://example.com/2", "snippet": "Snippet 2"},
    ]
    mock_search_api.search.return_value = mock_search_results
    mock_llm_response = "Mocked LLM response"
    mock_llm_api.query_llm.return_value = mock_llm_response
    mock_llm_api.stream_query_llm = AsyncMock()  # Mock the async generator
    mock_llm_api.stream_query_llm.return_value.__aiter__.return_value = iter([mock_llm_response])

    mock_cache_manager = AsyncMock()
    mock_cache_manager.get_cached_response.return_value = None # No cache hit

    search_manager = SearchManager(
        cache_manager=mock_cache_manager, search_api=mock_search_api, llm_api=mock_llm_api
    )

    # Mock the database session and commit
    mock_db_session = AsyncMock()
    with patch('app.backend.core.search_manager.next', return_value=mock_db_session):
      response, search_results, llm_used = await search_manager.get_response("test query", "session_id")

    assert response == mock_llm_response
    assert search_results == mock_search_results
    assert llm_used is None # Using default.
    mock_search_api.search.assert_called_once_with("test query", engine="google")
    mock_llm_api.query_llm.assert_called_once_with("test query", mock_search_results, None)


@pytest.mark.asyncio
async def test_search_manager_get_response_with_cache():

    mock_cache_manager = AsyncMock()
    mock_cached_response = {
        'response': "Cached response",
        'search_results': [],
        'llm_used': 'gemma'
    }
    mock_cache_manager.get_cached_response.return_value = mock_cached_response

    # Mock other components to prevent actual calls
    mock_search_api = AsyncMock()
    mock_llm_api = AsyncMock()

    search_manager = SearchManager(
        cache_manager=mock_cache_manager, search_api=mock_search_api, llm_api=mock_llm_api
    )

     # Mock the database session and commit
    mock_db_session = AsyncMock()
    with patch('app.backend.core.search_manager.next', return_value=mock_db_session):
        response, search_results, llm_used = await search_manager.get_response("test query", "session_id")

    assert response == "Cached response"
    assert search_results == []
    assert llm_used == 'gemma'
    mock_search_api.search.assert_not_called()  # Ensure search was not called
    mock_llm_api.query_llm.assert_not_called()  # Ensure LLM was not called

@pytest.mark.asyncio
async def test_search_manager_get_streaming_response_no_cache(db):
    mock_search_api = AsyncMock()
    mock_llm_api = AsyncMock()

    mock_search_results = [
        {"title": "Result 1", "link": "http://example.com/1", "snippet": "Snippet 1"},
    ]
    mock_search_api.search.return_value = mock_search_results
    mock_llm_response = "Mocked LLM response"
    mock_llm_api.query_llm.return_value = "Mocked LLM response" # For final caching.

    # Mock the async generator for streaming
    async def mock_stream_query_llm(*args, **kwargs):
      yield "Mocked "
      yield "LLM "
      yield "response"

    mock_llm_api.stream_query_llm = mock_stream_query_llm
    mock_cache_manager = AsyncMock()
    mock_cache_manager.get_cached_response.return_value = None

    search_manager_instance = SearchManager(
        cache_manager=mock_cache_manager, search_api=mock_search_api, llm_api=mock_llm_api
    )

    chunks = []
    async for chunk in search_manager_instance.get_streaming_response("test query", "session_id", db=db):
        chunks.append(chunk)

    assert len(chunks) == 4 # search results + 3 llm response chunks
    assert chunks[0] == {"type": "search_results", "results": mock_search_results}
    assert chunks[1] == {"type": "llm_response", "content": "Mocked "}
    assert chunks[2] == {"type": "llm_response", "content": "LLM "}
    
