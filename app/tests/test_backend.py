# --- app/tests/test_backend.py  ---
import pytest
from app.backend.config import Config
from app.backend.core.search_manager import SearchManager
from app.backend.core.llm_manager import LLMManager
from app.backend.core.prompt_optimizer import PromptOptimizer
from app.backend.database.database_manager import DatabaseManager
from app.backend.database.models import User, Chat
from app.backend.caching.cache_manager import CacheManager
from unittest.mock import patch, MagicMock
import json

# --- Mock Configuration for Testing ---
class MockConfig(Config):
    GOOGLE_API_KEY = "test_google_api_key"
    GOOGLE_CSE_ID = "test_google_cse_id"
    DUCKDUCKGO_API_KEY = "test_duckduckgo_api_key"
    DATABASE_URL = "sqlite:///:memory:"  # Use in-memory SQLite for testing
    REDIS_HOST = "localhost"
    REDIS_PORT = 6379
    REDIS_DB = 15  # Use a separate Redis DB for testing
    LLM_MODEL_MAPPING = {
        "test_llm": {"model_id": "test_model", "type": "huggingface"}
    }

# --- Fixtures ---

@pytest.fixture(scope="session")
def test_config():
    return MockConfig()

@pytest.fixture(scope="function")
def search_manager(test_config):
     return SearchManager(test_config)
    
@pytest.fixture(scope="function")
def llm_manager(test_config):
    return LLMManager(test_config)

@pytest.fixture
def prompt_optimizer():
    return PromptOptimizer()

@pytest.fixture(scope="function")
def database_manager(test_config):
     return DatabaseManager()

@pytest.fixture(scope="function")
def cache_manager(test_config):
    return CacheManager(host=test_config.REDIS_HOST, port=test_config.REDIS_PORT, db=test_config.REDIS_DB)


# --- Search Manager Tests ---

@patch('app.backend.core.search_manager.build')
def test_search_google_api_success(mock_build, search_manager):
    # Mock the Google API response
    mock_execute = MagicMock()
    mock_execute.execute.return_value = {'items': [{'title': 'Test Result', 'link': 'http://test.com', 'snippet': 'Test snippet'}]}
    mock_service = MagicMock()
    mock_service.cse.return_value.list.return_value = mock_execute
    mock_build.return_value = mock_service

    results = search_manager.search_google_api("test query")
    assert len(results) == 1
    assert results[0]['title'] == 'Test Result'
    mock_build.assert_called_once_with("customsearch", "v1", developerKey=search_manager.config.GOOGLE_API_KEY)

@patch('app.backend.core.search_manager.build')
def test_search_google_api_failure(mock_build, search_manager):
     mock_build.side_effect = Exception("API Error")
     results = search_manager.search_google_api("test query")
     assert results == []

@patch('app.backend.core.search_manager.requests.get')
def test_search_duckduckgo_success(mock_get, search_manager):
    mock_response = MagicMock()
    mock_response.json.return_value = {
        'RelatedTopics': [
            {'FirstURL': 'http://test.com', 'Result': 'Test<a href="#">Title</a>', 'Text': 'Test Snippet'}
        ]
    }
    mock_response.raise_for_status.return_value = None
    mock_get.return_value = mock_response
    results = search_manager.search_duckduckgo("test query")
    assert len(results) == 1
    assert results[0]['title'] == 'TestTitle'
    assert results[0]['snippet'] == 'Test Snippet'
    mock_get.assert_called_once()

@patch('app.backend.core.search_manager.requests.get')
def test_search_duckduckgo_failure(mock_get, search_manager):
     mock_get.side_effect = Exception("API Error")
     results = search_manager.search_duckduckgo("test query")
     assert results == []

# --- LLM Manager Tests ---

@patch('app.backend.core.llm_manager.HuggingFaceHub')
def test_get_llm_success(mock_huggingfacehub, llm_manager):
    mock_llm = MagicMock()  # Create a mock LLM instance
    mock_huggingfacehub.return_value = mock_llm #Return mock instance
    
    llm = llm_manager.get_llm("test_llm")
    assert llm == mock_llm # Check if get_llm returns our mock
    mock_huggingfacehub.assert_called_once_with(
        repo_id="test_model", model_kwargs={"temperature": 0.2, "max_new_tokens": 512}
    )


def test_get_llm_unsupported(llm_manager):
    with pytest.raises(ValueError):
        llm_manager.get_llm("unsupported_model")
        
@patch('app.backend.core.llm_manager.HuggingFaceHub')
def test_generate_response(mock_huggingface_hub, llm_manager):
    mock_llm = MagicMock()
    mock_llm.return_value = "Mocked LLM response"  # Mock the LLM's response
    mock_huggingface_hub.return_value = mock_llm
    
    search_results = [
      {'link': 'url1', 'title': 'Title 1', 'snippet': 'Snippet 1'},
      {'link': 'url2', 'title': 'Title 2', 'snippet': 'Snippet 2'}
    ]
    
    response = llm_manager.generate_response("test_llm", "test query", search_results)
    assert response == "Mocked LLM response"


# --- Prompt Optimizer Tests ---
def test_optimize_prompt_basic(prompt_optimizer):
    assert prompt_optimizer.optimize_prompt("  What is the capital of France?  ") == "capital France?"

def test_optimize_prompt_keyword_extraction(prompt_optimizer):
    long_query = "Explain the main differences between Python and JavaScript programming languages in detail"
    optimized = prompt_optimizer.optimize_prompt(long_query)
    assert len(optimized.split()) <= 5 # Check if it limits to max keywords
    assert "differences" in optimized
    assert "programming" in optimized

# --- Database Manager Tests ---

def test_create_user(database_manager):
    user = database_manager.create_user()
    assert isinstance(user, User)
    assert user.id is not None

def test_create_chat(database_manager):
    user = database_manager.create_user()
    chat = database_manager.create_chat(user.id, "Test Query", "Test Response")
    assert isinstance(chat, Chat)
    assert chat.user_id == user.id
    assert chat.query == "Test Query"

def test_get_chat_history(database_manager):
   user = database_manager.create_user()
   database_manager.create_chat(user.id, "Query 1", "Response 1")
   database_manager.create_chat(user.id, "Query 2", "Response 2")
   history = database_manager.get_chat_history(user.id)
   assert len(history) == 2
   assert history[0].query == "Query 2"  # Check ordering (descending)

def test_create_search_results(database_manager):
     user = database_manager.create_user()
     chat = database_manager.create_chat(user.id, "Test Query", "Test Response")
     search_results = [
        {"link": "http://example.com/1", "title": "Result 1", "snippet": "Snippet 1"},
        {"link": "http://example.com/2", "title": "Result 2", "snippet": "Snippet 2"},
     ]
     database_manager.create_search_results(chat.id, search_results)
     retrieved_results = database_manager.db.query(SearchResult).filter(SearchResult.chat_id == chat.id).all()
     assert len(retrieved_results) == 2
     assert retrieved_results[0].title == "Result 1"

# --- Cache Manager Tests ---

def test_cache_and_get(cache_manager):
     cache_manager.cache_response("test_query", "test_response", [{"test": "data"}])
     retrieved_response = cache_manager.get_cached_response("test_query")
     
     assert retrieved_response is not None
     data = json.loads(retrieved_response)
     assert data["response"] == "test_response"
     assert data["search_results"] == [{"test": "data"}]

def test_get_nonexistent_cache(cache_manager):
    assert cache_manager.get_cached_response("nonexistent_query") is None

def test_enqueue_and_dequeue(cache_manager):
    cache_manager.enqueue_query("test_query_1")
    cache_manager.enqueue_query("test_query_2")
    assert cache_manager.dequeue_query() == "test_query_1"
    assert cache_manager.dequeue_query() == "test_query_2"
    assert cache_manager.dequeue_query() is None
