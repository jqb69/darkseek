

# app/backend/core/search_manager.py (Modified to handle the search API changes)
from .caching import cache_manager
from ..api.search_api import search_api
from ..api.llm_api import llm_api
from .database import get_db, UserQuery
from sqlalchemy.orm import Session
from typing import List, Dict, Optional, Tuple, AsyncGenerator
import json
from .config import MAX_CHATS
import asyncio
import logging

logger = logging.getLogger(__name__)

class SearchManager:
    def __init__(self, cache_manager=cache_manager, search_api=search_api, llm_api=llm_api):
        self.cache_manager = cache_manager
        self.search_api = search_api
        self.llm_api = llm_api

    async def get_streaming_response(self, query: str, session_id: str, search_enabled: bool = True,
                                     llm_name: str = None,
                                     db: Session = next(get_db())) -> AsyncGenerator[Dict, None]:

        chat_count_key = f"chat_count:{session_id}"
        chat_count = self.cache_manager.redis_client.incr(chat_count_key)
        self.cache_manager.redis_client.expire(chat_count_key, 3600)

        if chat_count > MAX_CHATS:
            yield {"error": "Chat limit reached for this session."}
            return

        cached_response = self.cache_manager.get_cached_response(query)
        if cached_response:
            yield {"type": "full_response", "content": cached_response['response'], "search_results": cached_response['search_results'], "llm_used": cached_response['llm_used']}
            return

        if search_enabled:
            async for result_chunk in self.search_api.search(query):  # Iterate over the generator
                yield result_chunk  # Yield search results *and* errors

        try:
             # Pass empty initially, and later retrieve them for caching
            async for chunk in self.llm_api.stream_query_llm(query, [], llm_name):
                yield {"type": "llm_response", "content": chunk}

            search_results = [] # Retrieve for caching
            async for item in self.search_api.search(query):
                if item.get('type') == 'search_results':
                    search_results.extend(item.get('results',[]))

            full_response = await self.llm_api.query_llm(query, search_results, llm_name) # Cache the response
            self.cache_manager.cache_response(query, full_response, llm_name, search_results)
            asyncio.create_task(self.save_query_to_db(query, full_response, search_results, llm_name, db))

        except Exception as e:
            logger.error(f"Error querying LLM: {e}", exc_info=True)
            yield {"error": f"Error querying LLM: {e}"}
            return


    async def get_response(self, *args, **kwargs):
        """Compatibility method for non-streaming requests (initial load)."""
        full_response = ""
        search_results = []
        llm_used = ""

        async for chunk in self.get_streaming_response(*args, **kwargs):
            if chunk.get("type") == "llm_response":
                full_response += chunk["content"]
            elif chunk.get("type") == "search_results":
                search_results.extend(chunk.get('results',[]))
            elif chunk.get("type") == "full_response":
                full_response = chunk["content"]
                search_results = chunk["search_results"]
                llm_used = chunk["llm_used"]
            elif chunk.get("type") == "error":  # Check for "error" type
                full_response += chunk.get("content", "") # Accumulate errors
            elif "error" in chunk:  # Check for direct "error" key (older format)
                full_response = chunk["error"]

        return full_response, search_results, llm_used


    async def save_query_to_db(self, query, llm_response, search_results, llm_name, db: Session):
        existing_query = db.query(UserQuery).filter(UserQuery.query_text == query).first()
        if existing_query:
            logger.info(f"Query already exists in DB: {query}")
            return

        try:
            db_query = UserQuery(query_text=query, response_text=llm_response,
                                    search_results=json.dumps(search_results),
                                    llm_used=llm_name)
            db.add(db_query)
            db.commit()
            db.refresh(db_query)
        except Exception as e:
            logger.error(f"Error saving to DB: {e}", exc_info=True)
            db.rollback()

search_manager = SearchManager()
